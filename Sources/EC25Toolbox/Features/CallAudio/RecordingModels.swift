import Foundation
import AVFAudio

/// Pure frame math for mixing the two call directions into one mono track.
/// Both directions are mono Float32 at the module's rate, so mixing is a
/// sample-wise sum clamped to [-1, 1]; unequal buffer cadences just mean one
/// side carries a remainder into the next drain.
enum RecordingMixer {
    static func mix(_ uplink: [Float], _ downlink: [Float]) -> [Float] {
        let count = min(uplink.count, downlink.count)
        guard count > 0 else { return [] }
        var mixed = [Float](repeating: 0, count: count)
        for index in 0..<count {
            mixed[index] = clamp(uplink[index] + downlink[index])
        }
        return mixed
    }

    static func clamp(_ value: Float) -> Float {
        min(1, max(-1, value))
    }
}

/// Fixed-capacity circular mono sample buffer written from audio taps and
/// drained by the recorder's writer. The critical sections only memcpy into a
/// preallocated array, keeping tap work small and non-blocking in practice;
/// overflow drops the oldest samples instead of growing.
final class AudioSampleRing {
    private let lock = NSLock()
    private var samples: [Float]
    private var writeIndex = 0
    private var storedCount = 0

    init(capacity: Int) {
        samples = [Float](repeating: 0, count: max(1, capacity))
    }

    var capacity: Int { samples.count }

    var available: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    /// Copies `count` mono floats into the ring, dropping the oldest on
    /// overflow. RT-safe: no allocation, bounded work.
    func append(_ pointer: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        let capacity = samples.count
        if count >= capacity {
            // Keep only the newest `capacity` samples.
            samples.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.update(
                    from: pointer.advanced(by: count - capacity),
                    count: capacity
                )
            }
            writeIndex = 0
            storedCount = capacity
        } else {
            var remaining = count
            var offset = 0
            while remaining > 0 {
                let chunk = min(remaining, capacity - writeIndex)
                samples.withUnsafeMutableBufferPointer { destination in
                    destination.baseAddress!.advanced(by: writeIndex)
                        .update(from: pointer.advanced(by: offset), count: chunk)
                }
                writeIndex = (writeIndex + chunk) % capacity
                offset += chunk
                remaining -= chunk
            }
            storedCount = min(capacity, storedCount + count)
        }
        lock.unlock()
    }

    /// Removes up to `limit` samples in FIFO order.
    func drain(upTo limit: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let count = min(limit, storedCount)
        guard count > 0 else { return [] }
        let capacity = samples.count
        var result = [Float](repeating: 0, count: count)
        var readIndex = (writeIndex - storedCount + capacity) % capacity
        for index in 0..<count {
            result[index] = samples[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        storedCount -= count
        return result
    }
}

/// Records one call as a mix of both directions into a CAF file. Taps append
/// into preallocated rings; a background writer drains them into an
/// `AVAudioFile`, so no file I/O ever runs on an audio render thread.
/// Cross-thread state is guarded by `lock` and each ring's own lock.
final class CallRecorder: @unchecked Sendable {
    enum Direction {
        case uplink
        case downlink
    }

    struct FinishedRecording: Equatable {
        var fileURL: URL
        var format: AVAudioFormat
        var frames: AVAudioFramePosition
        var duration: TimeInterval
    }

    /// Seconds of headroom per direction before the oldest samples drop.
    private static let ringSeconds = 4

    private let lock = NSLock()
    private let uplinkRing: AudioSampleRing
    private let downlinkRing: AudioSampleRing
    private var file: AVAudioFile?
    private(set) var format: AVAudioFormat
    private var framesWritten: AVAudioFramePosition = 0
    private var writerTask: Task<Void, Never>?
    private var stopping = false

    init(format: AVAudioFormat) {
        self.format = format
        let capacity = max(1, Int(format.sampleRate) * Self.ringSeconds)
        uplinkRing = AudioSampleRing(capacity: capacity)
        downlinkRing = AudioSampleRing(capacity: capacity)
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return file != nil
    }

    /// Opens the output file and starts the background writer.
    func start(fileURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard file == nil else { return }
        let newFile = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        file = newFile
        framesWritten = 0
        stopping = false
        writerTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runWriter()
        }
    }

    /// RT-safe tap entry point: copies channel 0 of a mono-capable buffer
    /// into the direction's ring.
    func append(_ direction: Direction, buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let ring = direction == .uplink ? uplinkRing : downlinkRing
        ring.append(channel, count: Int(buffer.frameLength))
    }

    /// Drains one paired block from both rings, mixes, and writes to the
    /// file. Only complete frame pairs are consumed, so samples arriving
    /// between the two taps' cadences survive for the next drain. Used by
    /// the writer loop and directly by tests for deterministic flushes.
    func drainOnce() {
        let pairCount = min(uplinkRing.available, downlinkRing.available, 1_024)
        guard pairCount > 0 else { return }
        let uplinkSamples = uplinkRing.drain(upTo: pairCount)
        let downlinkSamples = downlinkRing.drain(upTo: pairCount)
        let mixed = RecordingMixer.mix(uplinkSamples, downlinkSamples)
        guard !mixed.isEmpty else { return }

        let frameCount = AVAudioFrameCount(mixed.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        mixed.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: mixed.count)
        }

        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(frameCount)
        } catch {
            // A failed write is unrecoverable mid-call; stop recording so the
            // file closes with whatever was captured.
            self.file = nil
        }
    }

    /// Flushes remaining sample pairs and closes the file. The unmixed tail
    /// of the longer side cannot be paired; it is discarded so the next
    /// recording starts from empty rings.
    @discardableResult
    func stop() -> FinishedRecording? {
        lock.lock()
        guard file != nil else {
            lock.unlock()
            return nil
        }
        // Halt the writer first; the closing drain below still needs the file.
        stopping = true
        lock.unlock()

        while uplinkRing.available > 0 && downlinkRing.available > 0 {
            let before = uplinkRing.available + downlinkRing.available
            drainOnce()
            if uplinkRing.available + downlinkRing.available >= before { break }
        }

        lock.lock()
        let finishedFile = file
        file = nil
        let frames = framesWritten
        lock.unlock()

        _ = uplinkRing.drain(upTo: uplinkRing.available)
        _ = downlinkRing.drain(upTo: downlinkRing.available)

        guard let finishedFile else { return nil }
        let currentFormat = format
        return FinishedRecording(
            fileURL: finishedFile.url,
            format: currentFormat,
            frames: frames,
            duration: frames > 0 ? TimeInterval(frames) / currentFormat.sampleRate : 0
        )
    }

    private func runWriter() async {
        while writerShouldContinue {
            drainOnce()
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    /// Locking stays inside this synchronous helper because NSLock is not
    /// callable directly from an async context.
    private var writerShouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopping && file != nil
    }
}

/// One saved call recording, listed per SIM identity scope.
struct RecordingEntry: Codable, Identifiable, Equatable {
    var id: String
    var fileName: String
    var createdAt: Date
    var duration: TimeInterval
    var byteSize: Int
    var number: String?

    private enum CodingKeys: String, CodingKey {
        case id, fileName, createdAt, duration, byteSize, number
    }

    init(
        id: String = UUID().uuidString,
        fileName: String,
        createdAt: Date,
        duration: TimeInterval,
        byteSize: Int,
        number: String?
    ) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.duration = duration
        self.byteSize = byteSize
        self.number = number
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        fileName = try container.decode(String.self, forKey: .fileName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        byteSize = try container.decodeIfPresent(Int.self, forKey: .byteSize) ?? 0
        number = try container.decodeIfPresent(String.self, forKey: .number)
    }
}

/// Persists call recordings under Application Support, isolated per SIM
/// identity (`CallRecordings/<scopeID>/`) like the SMS archive and call log.
/// Index writes are atomic JSON; a corrupt index reads as empty while the
/// audio files remain untouched on disk.
final class RecordingStore {
    private let fileManager: FileManager
    private let baseDirectory: URL
    /// Maximum kept recordings per scope; the oldest are pruned with their files.
    let limit: Int

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        limit: Int = 100
    ) {
        self.fileManager = fileManager
        let applicationSupport = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        baseDirectory = AppIdentity.applicationSupportDirectory(
            base: applicationSupport,
            fileManager: fileManager
        )
            .appendingPathComponent("CallRecordings", isDirectory: true)
        self.limit = max(1, limit)
    }

    func directory(for scope: SIMMessageScope) -> URL {
        baseDirectory.appendingPathComponent(scope.id, isDirectory: true)
    }

    func indexURL(for scope: SIMMessageScope) -> URL {
        directory(for: scope).appendingPathComponent("index.json")
    }

    func fileURL(for entry: RecordingEntry, scope: SIMMessageScope) -> URL {
        directory(for: scope).appendingPathComponent(entry.fileName)
    }

    func load(scope: SIMMessageScope) -> [RecordingEntry] {
        guard let data = try? Data(contentsOf: indexURL(for: scope)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecordingEntry].self, from: data)) ?? []
    }

    /// Registers a finished recording: records its index entry and prunes the
    /// oldest recordings beyond the limit.
    @discardableResult
    func register(_ entry: RecordingEntry, scope: SIMMessageScope) -> [RecordingEntry] {
        var entries = load(scope: scope)
        entries.append(entry)
        entries.sort { $0.createdAt > $1.createdAt }
        let removed = entries.suffix(max(0, entries.count - limit))
        for stale in removed {
            try? fileManager.removeItem(at: fileURL(for: stale, scope: scope))
        }
        entries = Array(entries.prefix(limit))
        persist(entries, scope: scope)
        return entries
    }

    /// Deletes one recording's file and index entry.
    @discardableResult
    func delete(_ entry: RecordingEntry, scope: SIMMessageScope) -> [RecordingEntry] {
        var entries = load(scope: scope)
        try? fileManager.removeItem(at: fileURL(for: entry, scope: scope))
        entries.removeAll { $0.id == entry.id }
        persist(entries, scope: scope)
        return entries
    }

    /// Absolute storage used by the scope's recordings, for a capacity note.
    func totalBytes(scope: SIMMessageScope) -> Int {
        load(scope: scope).reduce(0) { $0 + $1.byteSize }
    }

    func nextFileName(scope: SIMMessageScope, createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        let stamp = formatter.string(from: createdAt)
        var candidate = "call-\(stamp).caf"
        var counter = 1
        while fileManager.fileExists(
            atPath: directory(for: scope).appendingPathComponent(candidate).path
        ) {
            counter += 1
            candidate = "call-\(stamp)-\(counter).caf"
        }
        return candidate
    }

    private func persist(_ entries: [RecordingEntry], scope: SIMMessageScope) {
        do {
            if entries.isEmpty {
                try? fileManager.removeItem(at: indexURL(for: scope))
                return
            }
            try fileManager.createDirectory(at: directory(for: scope), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: indexURL(for: scope), options: .atomic)
        } catch {
            // Recording index persistence is best-effort.
        }
    }
}
