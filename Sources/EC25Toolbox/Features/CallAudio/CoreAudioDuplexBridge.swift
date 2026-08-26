import Foundation
import CoreAudio

/// Native duplex voice bridge over per-device CoreAudio IOProcs (R14).
///
/// Each involved device — the Mac microphone, the module's USB sound card,
/// and the Mac output — gets its own `AudioDeviceIOProcID`, so the two legs
/// are provably separated devices rather than one engine's nodes:
///
/// * uplink: Mac mic IOProc captures → uplink ring → module playback IOProc;
/// * downlink: module capture IOProc → downlink ring → Mac speaker IOProc.
///
/// The rings carry mono float32 at each capture device's native clock. The
/// playback IOProc performs bounded linear conversion while reading, so a
/// fixed-rate USB modem and a 44.1/48 kHz Mac endpoint can coexist without
/// changing either device's nominal rate. IOProc discipline: no
/// MainActor hops, no logging, no disk, no allocation — only short-lock
/// counting, bounded ring copies, and zero-fill on mute/speaker-off/starve,
/// each counted. Every segment (mic capture, module playback, module capture,
/// Mac speaker) has its own frame counter; "running" is derived from those
/// counters advancing, never from IO merely having started.
///
/// Single-use lifecycle: create → `start()` → `stop()` → discard. A stopped
/// bridge is never restarted; the service builds a fresh one per rebuild so
/// stale devices and IOProcs cannot leak into a new call.
final class CoreAudioDuplexBridge: @unchecked Sendable {
    struct Configuration {
        /// nil captures from the system default input device.
        var macInputUID: String?
        /// nil plays to the system default output device.
        var macOutputUID: String?
        var moduleCaptureUID: String
        var modulePlaybackUID: String
        var uplinkSourceRate: Double
        var uplinkTargetRate: Double
        var downlinkSourceRate: Double
        var downlinkTargetRate: Double
        var volume: Double = 1
        /// Gates the uplink only: captured mic frames zero-fill the ring.
        var muted = false
        /// Gates the Mac speaker only: downlink frames are consumed but the
        /// device renders silence.
        var speakerEnabled = true
        /// Seconds of ring capacity per direction (bounded by construction).
        var ringSeconds = 2

        /// Device IOProc virtual stream formats can lag a headset/USB-device
        /// clock change. Conversion follows the freshly planned nominal clock
        /// and uses the ASBD rate only as a defensive fallback.
        func uplinkPlaybackClockRate(virtualFormatRate: Double) -> Double {
            uplinkTargetRate > 0 ? uplinkTargetRate : virtualFormatRate
        }

        func downlinkPlaybackClockRate(virtualFormatRate: Double) -> Double {
            downlinkTargetRate > 0 ? downlinkTargetRate : virtualFormatRate
        }
    }

    // MARK: - Shared realtime state (short lock only)

    private let stateLock = NSLock()
    private var counters = DuplexSegmentCounters()
    private var mutedValue = false
    private var speakerEnabledValue = true
    private var volumeGain: Float = 1
    private var unsupportedFormatEvents: UInt64 = 0
    private var lastOSStatusValue: OSStatus = 0
    private var uplinkPeakValue: Float = 0
    private var downlinkPeakValue: Float = 0
    private(set) var running = false

    private let uplinkRing: AudioRateConverterRing
    private let downlinkRing: AudioRateConverterRing
    /// Independent network peer legs. They keep the local host path active
    /// while allowing a paired remote client to talk and listen to the same
    /// call without becoming a second consumer/producer on an SPSC ring.
    private let remoteUplinkRing: AudioRateConverterRing
    private let remoteDownlinkRing: AudioRateConverterRing
    /// Recorder taps drain on the service side; the IOProcs only copy.
    let uplinkTapRing: AudioSPSCRing
    let downlinkTapRing: AudioSPSCRing

    /// Immutable after a successful `start`; IOProcs read it lock-free.
    private var devices: [DeviceIO] = []
    private let configuration: Configuration

    /// Largest IO block the per-device scratch buffers hold (frames).
    private static let maxIOFrames = 4_096

    struct Snapshot: Sendable {
        var counters: DuplexSegmentCounters
        var unsupportedFormatEvents: UInt64
        var lastOSStatus: OSStatus
        var uplinkPeak: Float
        var downlinkPeak: Float
    }

    init(configuration: Configuration) {
        self.configuration = configuration
        let seconds = max(1, configuration.ringSeconds)
        let uplinkFrames = max(1, Int(configuration.uplinkSourceRate)) * seconds
        let downlinkFrames = max(1, Int(configuration.downlinkSourceRate)) * seconds
        uplinkRing = AudioRateConverterRing(capacityFrames: uplinkFrames)
        downlinkRing = AudioRateConverterRing(capacityFrames: downlinkFrames)
        remoteUplinkRing = AudioRateConverterRing(capacityFrames: 8_000 * seconds)
        remoteDownlinkRing = AudioRateConverterRing(capacityFrames: downlinkFrames)
        // Taps hold a few extra seconds so the service's periodic drain never
        // stalls the live path; overflow drops, bounded.
        uplinkTapRing = AudioSPSCRing(
            capacityFrames: max(1, Int(configuration.uplinkTargetRate)) * 6
        )
        downlinkTapRing = AudioSPSCRing(
            capacityFrames: max(1, Int(configuration.downlinkTargetRate)) * 6
        )
        mutedValue = configuration.muted
        speakerEnabledValue = configuration.speakerEnabled
        volumeGain = Float(min(1, max(0, configuration.volume)))
    }

    deinit {
        // Best-effort: IOProcs must never outlive the bridge.
        for device in devices {
            if let ioProcID = device.ioProcID {
                AudioDeviceStop(device.objectID, ioProcID)
                AudioDeviceDestroyIOProcID(device.objectID, ioProcID)
            }
            device.scratch.deallocate()
            device.remoteScratch.deallocate()
        }
    }

    // MARK: - Device records

    private struct DeviceIO {
        struct Role: OptionSet {
            let rawValue: UInt8
            // Mac mic → uplink ring
            static let macCapture = Role(rawValue: 1 << 0)
            // uplink ring → module output
            static let modulePlayback = Role(rawValue: 1 << 1)
            // module input → downlink ring
            static let moduleCapture = Role(rawValue: 1 << 2)
            // downlink ring → Mac speaker
            static let macOutput = Role(rawValue: 1 << 3)
        }

        let objectID: AudioObjectID
        let uid: String
        let role: Role
        var inputASBD: AudioStreamBasicDescription?
        var outputASBD: AudioStreamBasicDescription?
        var ioProcID: AudioDeviceIOProcID?
        /// Per-device mono staging — never shared between IOProc threads.
        let scratch: UnsafeMutablePointer<Float>
        let remoteScratch: UnsafeMutablePointer<Float>

        init(objectID: AudioObjectID, uid: String, role: Role) {
            self.objectID = objectID
            self.uid = uid
            self.role = role
            self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: CoreAudioDuplexBridge.maxIOFrames)
            self.remoteScratch = UnsafeMutablePointer<Float>.allocate(capacity: CoreAudioDuplexBridge.maxIOFrames)
            scratch.initialize(repeating: 0, count: CoreAudioDuplexBridge.maxIOFrames)
            remoteScratch.initialize(repeating: 0, count: CoreAudioDuplexBridge.maxIOFrames)
        }

        mutating func deallocateScratch() {
            scratch.deallocate()
            remoteScratch.deallocate()
        }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !running else { return }

        let macInput = try Self.resolveDevice(
            uid: configuration.macInputUID,
            defaultSelector: kAudioHardwarePropertyDefaultInputDevice,
            error: .deviceMissing
        )
        let macOutput = try Self.resolveDevice(
            uid: configuration.macOutputUID,
            defaultSelector: kAudioHardwarePropertyDefaultOutputDevice,
            error: .deviceMissing
        )
        guard let moduleCapture = AudioDeviceCatalog.objectID(forUID: configuration.moduleCaptureUID) else {
            throw CallAudioError.deviceMissing
        }
        guard let modulePlayback = AudioDeviceCatalog.objectID(forUID: configuration.modulePlaybackUID) else {
            throw CallAudioError.deviceMissing
        }

        // Group roles by physical device: the module's two sides usually
        // share one UAC device, and each device carries exactly one IOProc.
        var rolesByObject: [AudioObjectID: DeviceIO.Role] = [:]
        rolesByObject[macInput, default: []].insert(.macCapture)
        rolesByObject[macOutput, default: []].insert(.macOutput)
        rolesByObject[moduleCapture, default: []].insert(.moduleCapture)
        rolesByObject[modulePlayback, default: []].insert(.modulePlayback)

        var prepared: [DeviceIO] = []
        do {
            for (objectID, role) in rolesByObject.sorted(by: { $0.key < $1.key }) {
                guard objectID != kAudioObjectUnknown else { continue }
                var device = DeviceIO(
                    objectID: objectID,
                    uid: Self.deviceUID(objectID),
                    role: role
                )
                if !role.isDisjoint(with: [.macCapture, .moduleCapture]) {
                    device.inputASBD = Self.streamFormat(objectID, scope: kAudioObjectPropertyScopeInput)
                    if role.contains(.macCapture) && Self.inputChannels(objectID) == 0 {
                        throw CallAudioError.noCaptureChannels
                    }
                }
                if !role.isDisjoint(with: [.macOutput, .modulePlayback]) {
                    device.outputASBD = Self.streamFormat(objectID, scope: kAudioObjectPropertyScopeOutput)
                    if role.contains(.macOutput) && Self.outputChannels(objectID) == 0 {
                        throw CallAudioError.noPlaybackChannels
                    }
                }
                try installIOProc(&device)
                try Self.startDevice(device)
                prepared.append(device)
            }
        } catch {
            for var device in prepared {
                if let ioProcID = device.ioProcID {
                    AudioDeviceStop(device.objectID, ioProcID)
                    AudioDeviceDestroyIOProcID(device.objectID, ioProcID)
                }
                device.deallocateScratch()
            }
            throw error
        }
        devices = prepared
        running = true
    }

    func stop() {
        running = false
        for index in devices.indices {
            if let ioProcID = devices[index].ioProcID {
                AudioDeviceStop(devices[index].objectID, ioProcID)
                // Destroy blocks until in-flight callbacks drain, so clearing
                // the ID afterwards is safe and keeps deinit from destroying twice.
                AudioDeviceDestroyIOProcID(devices[index].objectID, ioProcID)
            }
            devices[index].ioProcID = nil
        }
        uplinkRing.flush()
        downlinkRing.flush()
        remoteUplinkRing.flush()
        remoteDownlinkRing.flush()
    }

    // MARK: - Remote peer exchange (never called from an IOProc)

    func enqueueRemoteUplink(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            remoteUplinkRing.write(base, count: buffer.count)
        }
    }

    func pullRemoteDownlink(frameCount: Int, sampleRate: Double) -> [Float] {
        let count = min(max(0, frameCount), 8_000)
        guard count > 0, sampleRate > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { buffer in
            remoteDownlinkRing.readResampled(
                into: buffer.baseAddress!,
                count: count,
                sourceRate: configuration.downlinkSourceRate,
                targetRate: sampleRate
            )
        }
        return result
    }

    // MARK: - Live control (short lock, IOProc-safe)

    func setMuted(_ muted: Bool) {
        stateLock.lock()
        mutedValue = muted
        stateLock.unlock()
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        stateLock.lock()
        speakerEnabledValue = enabled
        stateLock.unlock()
    }

    func setVolume(_ volume: Double) {
        stateLock.lock()
        volumeGain = Float(min(1, max(0, volume)))
        stateLock.unlock()
    }

    func snapshot() -> Snapshot {
        let uplink = uplinkRing.snapshot()
        let downlink = downlinkRing.snapshot()
        stateLock.lock()
        defer { stateLock.unlock() }
        var snapshotCounters = counters
        snapshotCounters.droppedFrames = uplink.droppedFrames + downlink.droppedFrames
        snapshotCounters.starvedFrames = uplink.starvedFrames + downlink.starvedFrames
        let uplinkPeak = uplinkPeakValue
        let downlinkPeak = downlinkPeakValue
        uplinkPeakValue = 0
        downlinkPeakValue = 0
        return Snapshot(
            counters: snapshotCounters,
            unsupportedFormatEvents: unsupportedFormatEvents,
            lastOSStatus: lastOSStatusValue,
            uplinkPeak: uplinkPeak,
            downlinkPeak: downlinkPeak
        )
    }

    // MARK: - CoreAudio setup helpers

    private static func resolveDevice(
        uid: String?,
        defaultSelector: AudioObjectPropertySelector,
        error: CallAudioError
    ) throws -> AudioObjectID {
        if let uid {
            guard let objectID = AudioDeviceCatalog.objectID(forUID: uid) else {
                throw error
            }
            return objectID
        }
        var address = AudioObjectPropertyAddress(
            mSelector: defaultSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != kAudioObjectUnknown, id != 0 else {
            throw error
        }
        return id
    }

    private static func deviceUID(_ objectID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return "audio-object-\(objectID)" }
        return uid as String
    }

    private static func streamFormat(
        _ objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &format) == noErr,
              format.mSampleRate > 0, format.mChannelsPerFrame > 0
        else { return nil }
        return format
    }

    private static func inputChannels(_ objectID: AudioObjectID) -> UInt32 {
        streamFormat(objectID, scope: kAudioObjectPropertyScopeInput)?.mChannelsPerFrame ?? 0
    }

    private static func outputChannels(_ objectID: AudioObjectID) -> UInt32 {
        streamFormat(objectID, scope: kAudioObjectPropertyScopeOutput)?.mChannelsPerFrame ?? 0
    }

    private func installIOProc(_ device: inout DeviceIO) throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            device.objectID,
            { deviceID, _, inputData, _, outputData, _, clientData in
                guard let clientData else { return noErr }
                let bridge = Unmanaged<CoreAudioDuplexBridge>
                    .fromOpaque(clientData)
                    .takeUnretainedValue()
                return bridge.handleIO(
                    deviceID: deviceID,
                    inputData: inputData,
                    outputData: outputData
                )
            },
            context,
            &ioProcID
        )
        guard status == noErr, let ioProcID else {
            recordOSStatus(status)
            throw CallAudioError.ioProcFailed(status)
        }
        device.ioProcID = ioProcID
    }

    private static func startDevice(_ device: DeviceIO) throws {
        guard let ioProcID = device.ioProcID else { return }
        let status = AudioDeviceStart(device.objectID, ioProcID)
        guard status == noErr else {
            throw CallAudioError.ioProcFailed(status)
        }
    }

    private func recordOSStatus(_ status: OSStatus) {
        guard status != noErr else { return }
        stateLock.lock()
        lastOSStatusValue = status
        stateLock.unlock()
    }

    // MARK: - IOProc body (realtime context)

    /// Per-device IO callback. Roles are precomputed; the body only mixes
    /// down to mono, copies ring frames, zero-fills gated legs, and bumps
    /// segment counters under the short lock.
    private func handleIO(
        deviceID: AudioObjectID,
        inputData: UnsafePointer<AudioBufferList>?,
        outputData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let device = devices.first(where: { $0.objectID == deviceID }) else {
            return noErr
        }

        if let inputData, device.role.contains(.macCapture) {
            processMacCapture(inputData, device: device)
        }
        if let inputData, device.role.contains(.moduleCapture) {
            processModuleCapture(inputData, device: device)
        }
        if let outputData, device.role.contains(.modulePlayback) {
            processModulePlayback(outputData, device: device)
        }
        if let outputData, device.role.contains(.macOutput) {
            processMacOutput(outputData, device: device)
        }
        return noErr
    }

    private func processMacCapture(
        _ inputData: UnsafePointer<AudioBufferList>,
        device: DeviceIO
    ) {
        guard let asbd = device.inputASBD else {
            noteUnsupportedFormat()
            return
        }
        let frames = Self.frames(in: inputData, asbd: asbd)
        guard frames > 0, frames <= Self.maxIOFrames,
              Self.sumToMono(inputData, asbd: asbd, frames: frames, into: device.scratch) else {
            noteUnsupportedFormat()
            return
        }
        stateLock.lock()
        let muted = mutedValue
        stateLock.unlock()
        if muted {
            memset(device.scratch, 0, frames * MemoryLayout<Float>.size)
        }
        let peak = Self.peakMagnitude(device.scratch, count: frames)
        stateLock.lock()
        counters.macMicCaptureFrames &+= UInt64(frames)
        uplinkPeakValue = max(uplinkPeakValue, peak)
        stateLock.unlock()
        uplinkRing.write(device.scratch, count: frames)
    }

    private func processModuleCapture(
        _ inputData: UnsafePointer<AudioBufferList>,
        device: DeviceIO
    ) {
        guard let asbd = device.inputASBD else {
            noteUnsupportedFormat()
            return
        }
        let frames = Self.frames(in: inputData, asbd: asbd)
        guard frames > 0, frames <= Self.maxIOFrames,
              Self.sumToMono(inputData, asbd: asbd, frames: frames, into: device.scratch) else {
            noteUnsupportedFormat()
            return
        }
        let peak = Self.peakMagnitude(device.scratch, count: frames)
        stateLock.lock()
        counters.moduleCaptureFrames &+= UInt64(frames)
        downlinkPeakValue = max(downlinkPeakValue, peak)
        stateLock.unlock()
        downlinkRing.write(device.scratch, count: frames)
        remoteDownlinkRing.write(device.scratch, count: frames)
    }

    private func processModulePlayback(
        _ outputData: UnsafeMutablePointer<AudioBufferList>,
        device: DeviceIO
    ) {
        guard let asbd = device.outputASBD else {
            noteUnsupportedFormat()
            return
        }
        let frames = Self.frames(in: UnsafeRawPointer(outputData), asbd: asbd)
        guard frames > 0, frames <= Self.maxIOFrames else { return }
        stateLock.lock()
        counters.modulePlaybackFrames &+= UInt64(frames)
        let gain = volumeGain
        stateLock.unlock()
        uplinkRing.readResampled(
            into: device.scratch,
            count: frames,
            sourceRate: configuration.uplinkSourceRate,
            targetRate: configuration.uplinkPlaybackClockRate(
                virtualFormatRate: asbd.mSampleRate
            )
        )
        remoteUplinkRing.readResampled(
            into: device.remoteScratch,
            count: frames,
            sourceRate: 8_000,
            targetRate: configuration.uplinkPlaybackClockRate(
                virtualFormatRate: asbd.mSampleRate
            )
        )
        for index in 0..<frames {
            device.scratch[index] = min(1, max(-1, device.scratch[index] + device.remoteScratch[index]))
        }
        uplinkTapRing.write(device.scratch, count: frames)
        Self.fill(
            fromMono: UnsafePointer(device.scratch),
            frames: frames,
            gain: gain,
            into: outputData,
            asbd: asbd
        )
    }

    private func processMacOutput(
        _ outputData: UnsafeMutablePointer<AudioBufferList>,
        device: DeviceIO
    ) {
        guard let asbd = device.outputASBD else {
            noteUnsupportedFormat()
            return
        }
        let frames = Self.frames(in: UnsafeRawPointer(outputData), asbd: asbd)
        guard frames > 0, frames <= Self.maxIOFrames else { return }
        stateLock.lock()
        counters.macSpeakerFrames &+= UInt64(frames)
        let speakerOn = speakerEnabledValue
        let gain = volumeGain
        stateLock.unlock()
        // Consume the downlink ring even when muted to the speaker so the
        // ring never backs up; the device then renders silence.
        downlinkRing.readResampled(
            into: device.scratch,
            count: frames,
            sourceRate: configuration.downlinkSourceRate,
            targetRate: configuration.downlinkPlaybackClockRate(
                virtualFormatRate: asbd.mSampleRate
            )
        )
        downlinkTapRing.write(device.scratch, count: frames)
        if !speakerOn {
            memset(device.scratch, 0, frames * MemoryLayout<Float>.size)
        }
        Self.fill(
            fromMono: UnsafePointer(device.scratch),
            frames: frames,
            gain: gain,
            into: outputData,
            asbd: asbd
        )
    }

    private func noteUnsupportedFormat() {
        stateLock.lock()
        unsupportedFormatEvents &+= 1
        stateLock.unlock()
    }

    private static func peakMagnitude(
        _ samples: UnsafePointer<Float>,
        count: Int
    ) -> Float {
        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, abs(samples[index]))
        }
        return peak
    }

    // MARK: - Buffer shape helpers (float32 only; other formats counted)

    private static func frames(
        in pointer: UnsafeRawPointer,
        asbd: AudioStreamBasicDescription
    ) -> Int {
        guard asbd.mBytesPerFrame > 0 else { return 0 }
        let list = UnsafeMutablePointer(mutating: pointer.assumingMemoryBound(to: AudioBufferList.self))
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first else { return 0 }
        return Int(first.mDataByteSize) / Int(asbd.mBytesPerFrame)
    }

    /// Averages all channels of one input block into mono. float32 only.
    /// No allocation: channels are read through the buffer-list wrapper.
    private static func sumToMono(
        _ list: UnsafePointer<AudioBufferList>,
        asbd: AudioStreamBasicDescription,
        frames: Int,
        into mono: UnsafeMutablePointer<Float>
    ) -> Bool {
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return false }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 {
            // Interleaved: one buffer holding frames × channels.
            guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return false }
            let inverse = 1 / Float(channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += data[frame * channels + channel]
                }
                mono[frame] = sum * inverse
            }
            return true
        }
        // Non-interleaved: one AudioBuffer per channel.
        let usableChannels = min(buffers.count, channels)
        guard usableChannels > 0 else { return false }
        let inverse = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for index in 0..<usableChannels {
                if let data = buffers[index].mData?.assumingMemoryBound(to: Float.self) {
                    sum += data[frame]
                }
            }
            mono[frame] = sum * inverse
        }
        return true
    }

    /// Duplicates mono samples into every output channel at `gain`.
    private static func fill(
        fromMono mono: UnsafePointer<Float>,
        frames: Int,
        gain: Float,
        into list: UnsafeMutablePointer<AudioBufferList>,
        asbd: AudioStreamBasicDescription
    ) {
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 {
            guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
            for frame in 0..<frames {
                let sample = mono[frame] * gain
                for channel in 0..<channels {
                    data[frame * channels + channel] = sample
                }
            }
            return
        }
        for index in 0..<min(buffers.count, channels) {
            guard let data = buffers[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frames {
                data[frame] = mono[frame] * gain
            }
        }
    }
}
