import AVFAudio
import Foundation

/// Client-side audio endpoint for a remotely managed modem. Local mic frames
/// are converted off the realtime tap to 8 kHz mono, exchanged over the
/// authenticated remote channel, and scheduled on the local output node.
@MainActor
final class RemoteCallAudioBridge {
    struct Snapshot: Sendable {
        var counters: DuplexSegmentCounters
        var lastError: String?
    }

    private static let networkRate: Double = 8_000
    private static let exchangeFrames = 800 // 100 ms

    private let transport: RemoteModemTransport
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var micRing: AudioSPSCRing?
    private var micFormat: AVAudioFormat?
    private var micConverter: AVAudioConverter?
    private var exchangeTask: Task<Void, Never>?
    private var sentFrames: UInt64 = 0
    private var receivedFrames: UInt64 = 0
    private var scheduledFrames: UInt64 = 0
    private var lastError: String?
    private(set) var running = false
    let uplinkTapRing = AudioSPSCRing(capacityFrames: 8_000 * 6)
    let downlinkTapRing = AudioSPSCRing(capacityFrames: 8_000 * 6)
    private let controlLock = NSLock()
    private var muted = false
    private var speakerEnabled = true

    init(transport: RemoteModemTransport) {
        self.transport = transport
    }

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let deviceFormat = input.outputFormat(forBus: 0)
        guard deviceFormat.sampleRate > 0,
              let monoFormat = AVAudioFormat(
                standardFormatWithSampleRate: deviceFormat.sampleRate,
                channels: 1
              ),
              let networkFormat = AVAudioFormat(
                standardFormatWithSampleRate: Self.networkRate,
                channels: 1
              ) else {
            throw CallAudioError.formatMismatch("remote client format")
        }

        let ring = AudioSPSCRing(capacityFrames: max(4_096, Int(deviceFormat.sampleRate) * 2))
        micRing = ring
        micFormat = monoFormat
        micConverter = AVAudioConverter(from: monoFormat, to: networkFormat)

        input.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(max(256, Int(deviceFormat.sampleRate / 10))),
            format: deviceFormat
        ) { buffer, _ in
            guard let channels = buffer.floatChannelData,
                  buffer.frameLength > 0 else { return }
            // The host input is normally non-interleaved float. The first
            // channel is a valid mono capture and avoids allocation/mixing in
            // this realtime callback.
            ring.write(channels[0], count: Int(buffer.frameLength))
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: networkFormat)
        engine.prepare()
        try engine.start()
        player.play()
        running = true
        startExchangeLoop(networkFormat: networkFormat)
    }

    func stop() {
        guard running || exchangeTask != nil else { return }
        exchangeTask?.cancel()
        exchangeTask = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        micRing?.flush()
        micRing = nil
        micFormat = nil
        micConverter = nil
        running = false
    }

    func setMuted(_ muted: Bool) {
        controlLock.lock()
        self.muted = muted
        controlLock.unlock()
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        controlLock.lock()
        speakerEnabled = enabled
        controlLock.unlock()
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(min(1, max(0, volume)))
    }

    func snapshot() -> Snapshot {
        let mic = micRing?.snapshot()
        var counters = DuplexSegmentCounters()
        counters.macMicCaptureFrames = mic?.writtenFrames ?? 0
        counters.modulePlaybackFrames = sentFrames
        counters.moduleCaptureFrames = receivedFrames
        counters.macSpeakerFrames = scheduledFrames
        counters.droppedFrames = mic?.droppedFrames ?? 0
        counters.starvedFrames = mic?.starvedFrames ?? 0
        return Snapshot(counters: counters, lastError: lastError)
    }

    private func startExchangeLoop(networkFormat: AVAudioFormat) {
        exchangeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.running, !Task.isCancelled else { break }
                let uplink = self.makeUplinkChunk(networkFormat: networkFormat)
                do {
                    let downlink = try await self.transport.exchangeAudio(
                        uplink: uplink,
                        requestedDownlinkFrames: Self.exchangeFrames
                    )
                    self.sentFrames &+= UInt64(uplink.count)
                    self.receivedFrames &+= UInt64(downlink.count)
                    self.scheduleDownlink(downlink, format: networkFormat)
                    self.lastError = nil
                } catch {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func makeUplinkChunk(networkFormat: AVAudioFormat) -> [Float] {
        guard let micRing, let micFormat, let converter = micConverter else { return [] }
        let available = micRing.availableFrames
        guard available > 0 else { return [] }
        let nativeCount = min(available, max(1, Int(micFormat.sampleRate / 10)))
        var source = [Float](repeating: 0, count: nativeCount)
        source.withUnsafeMutableBufferPointer {
            micRing.read(into: $0.baseAddress!, count: nativeCount)
        }
        controlLock.lock()
        let muted = muted
        controlLock.unlock()
        if muted {
            _ = source.withUnsafeMutableBytes { raw in
                memset(raw.baseAddress!, 0, raw.count)
            }
        }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: micFormat,
            frameCapacity: AVAudioFrameCount(nativeCount)
        ) else { return [] }
        input.frameLength = AVAudioFrameCount(nativeCount)
        source.withUnsafeBufferPointer {
            input.floatChannelData![0].update(from: $0.baseAddress!, count: nativeCount)
        }

        guard let output = AVAudioPCMBuffer(
            pcmFormat: networkFormat,
            frameCapacity: AVAudioFrameCount(Self.exchangeFrames + 64)
        ) else { return [] }
        var supplied = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard result != .error, output.frameLength > 0,
              let samples = output.floatChannelData?[0] else { return [] }
        let resultSamples = Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        resultSamples.withUnsafeBufferPointer {
            uplinkTapRing.write($0.baseAddress!, count: $0.count)
        }
        return resultSamples
    }

    private func scheduleDownlink(_ samples: [Float], format: AVAudioFormat) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        controlLock.lock()
        let speakerEnabled = speakerEnabled
        controlLock.unlock()
        samples.withUnsafeBufferPointer { source in
            downlinkTapRing.write(source.baseAddress!, count: source.count)
            if speakerEnabled {
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            } else {
                memset(
                    buffer.floatChannelData![0],
                    0,
                    samples.count * MemoryLayout<Float>.size
                )
            }
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
        scheduledFrames &+= UInt64(samples.count)
    }
}
