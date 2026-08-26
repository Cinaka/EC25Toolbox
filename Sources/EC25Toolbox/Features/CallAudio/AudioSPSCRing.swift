import Foundation

/// Bounded single-producer/single-consumer mono Float ring (R14). The
/// producer side runs inside CoreAudio IOProcs: `write` and `read` never
/// allocate, never log, and touch the mutex only for the short counter
/// window — matching the project's realtime convention (short-lock counting
/// with bounded watermarks). Overruns drop the newest samples; underruns
/// zero-fill the requested remainder, so both sides always see continuous
/// frame-shaped data and every drop/starve is counted.
final class AudioSPSCRing: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private var storedFrames = 0

    // Counters snapshotted for diagnostics; written under the short lock.
    private(set) var writtenFrames: UInt64 = 0
    private(set) var readFrames: UInt64 = 0
    private(set) var droppedFrames: UInt64 = 0
    private(set) var starvedFrames: UInt64 = 0

    init(capacityFrames: Int) {
        storage = [Float](repeating: 0, count: max(1, capacityFrames))
    }

    var capacity: Int { storage.count }

    var availableFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames
    }

    /// Copies `count` frames in. Frames past capacity are dropped and
    /// counted; the ring never blocks or grows.
    func write(_ pointer: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        let capacity = storage.count
        let free = capacity - storedFrames
        let accepted = min(count, free)
        if accepted > 0 {
            var remaining = accepted
            var offset = 0
            while remaining > 0 {
                let chunk = min(remaining, capacity - writeIndex)
                withExtendedLifetime(storage) {
                    storage.withUnsafeMutableBufferPointer { buffer in
                        buffer.baseAddress!
                            .advanced(by: writeIndex)
                            .update(from: pointer.advanced(by: offset), count: chunk)
                    }
                }
                writeIndex = (writeIndex + chunk) % capacity
                offset += chunk
                remaining -= chunk
            }
            storedFrames += accepted
            writtenFrames &+= UInt64(accepted)
        }
        if count > accepted {
            droppedFrames &+= UInt64(count - accepted)
        }
        lock.unlock()
    }

    /// Reads up to `count` frames into `pointer`. Missing frames are
    /// zero-filled and counted as starved so the consumer always returns a
    /// full, continuous block.
    func read(into pointer: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        let capacity = storage.count
        let available = storedFrames
        let delivered = min(count, available)
        if delivered > 0 {
            var remaining = delivered
            var offset = 0
            while remaining > 0 {
                let chunk = min(remaining, capacity - readIndex)
                storage.withUnsafeMutableBufferPointer { buffer in
                    pointer.advanced(by: offset).update(
                        from: buffer.baseAddress!.advanced(by: readIndex),
                        count: chunk
                    )
                }
                readIndex = (readIndex + chunk) % capacity
                offset += chunk
                remaining -= chunk
            }
            storedFrames -= delivered
            readFrames &+= UInt64(delivered)
        }
        if count > delivered {
            memset(pointer + delivered, 0, (count - delivered) * MemoryLayout<Float>.size)
            starvedFrames &+= UInt64(count - delivered)
        }
        lock.unlock()
    }

    struct Snapshot: Equatable, Sendable {
        var writtenFrames: UInt64
        var readFrames: UInt64
        var availableFrames: Int
        var droppedFrames: UInt64
        var starvedFrames: UInt64
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            writtenFrames: writtenFrames,
            readFrames: readFrames,
            availableFrames: storedFrames,
            droppedFrames: droppedFrames,
            starvedFrames: starvedFrames
        )
    }

    /// Drops buffered content (link teardown/rebuild); counters are kept.
    func flush() {
        lock.lock()
        writeIndex = 0
        readIndex = 0
        storedFrames = 0
        lock.unlock()
    }
}
