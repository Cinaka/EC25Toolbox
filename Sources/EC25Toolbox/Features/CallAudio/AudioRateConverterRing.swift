import Foundation

/// Bounded mono Float ring with realtime-safe linear sample-rate conversion.
/// Capture IOProcs write at their native clock and playback IOProcs read at
/// their own native clock; fixed 8/16 kHz modem endpoints therefore no longer
/// force a 44.1/48 kHz Mac device to change its nominal rate.
final class AudioRateConverterRing: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private var storedFrames = 0
    private var readPhase: Double = 0

    private(set) var writtenFrames: UInt64 = 0
    private(set) var readFrames: UInt64 = 0
    private(set) var droppedFrames: UInt64 = 0
    private(set) var starvedFrames: UInt64 = 0

    init(capacityFrames: Int) {
        storage = [Float](repeating: 0, count: max(2, capacityFrames))
    }

    var availableFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames
    }

    func write(_ pointer: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        let capacity = storage.count
        let accepted = min(count, capacity - storedFrames)
        if accepted > 0 {
            var remaining = accepted
            var sourceOffset = 0
            while remaining > 0 {
                let chunk = min(remaining, capacity - writeIndex)
                storage.withUnsafeMutableBufferPointer { buffer in
                    buffer.baseAddress!.advanced(by: writeIndex).update(
                        from: pointer.advanced(by: sourceOffset),
                        count: chunk
                    )
                }
                writeIndex = (writeIndex + chunk) % capacity
                sourceOffset += chunk
                remaining -= chunk
            }
            storedFrames += accepted
            writtenFrames &+= UInt64(accepted)
        }
        if accepted < count {
            droppedFrames &+= UInt64(count - accepted)
        }
        lock.unlock()
    }

    /// Produces exactly `count` destination frames. Missing source data is
    /// zero-filled; conversion never allocates, blocks, or mutates a device's
    /// nominal sample rate.
    func readResampled(
        into pointer: UnsafeMutablePointer<Float>,
        count: Int,
        sourceRate: Double,
        targetRate: Double
    ) {
        guard count > 0 else { return }
        guard sourceRate > 0, targetRate > 0 else {
            memset(pointer, 0, count * MemoryLayout<Float>.size)
            lock.lock()
            starvedFrames &+= UInt64(count)
            lock.unlock()
            return
        }

        lock.lock()
        if abs(sourceRate - targetRate) < 0.5 {
            readWithoutConversion(into: pointer, count: count)
            lock.unlock()
            return
        }

        let ratio = sourceRate / targetRate
        let capacity = storage.count
        var produced = 0
        while produced < count {
            let baseOffset = Int(readPhase)
            guard storedFrames > baseOffset + 1 else { break }

            let fraction = Float(readPhase - Double(baseOffset))
            let firstIndex = (readIndex + baseOffset) % capacity
            let secondIndex = (firstIndex + 1) % capacity
            let first = storage[firstIndex]
            pointer[produced] = first + (storage[secondIndex] - first) * fraction
            produced += 1

            readPhase += ratio
            let requestedConsume = Int(readPhase)
            if requestedConsume > 0 {
                // Preserve one sample as the interpolation boundary for the
                // next producer block.
                let consumed = min(requestedConsume, max(0, storedFrames - 1))
                readIndex = (readIndex + consumed) % capacity
                storedFrames -= consumed
                readFrames &+= UInt64(consumed)
                readPhase -= Double(consumed)
            }
        }

        if produced < count {
            memset(
                pointer.advanced(by: produced),
                0,
                (count - produced) * MemoryLayout<Float>.size
            )
            starvedFrames &+= UInt64(count - produced)
        }
        lock.unlock()
    }

    private func readWithoutConversion(into pointer: UnsafeMutablePointer<Float>, count: Int) {
        let capacity = storage.count
        let delivered = min(count, storedFrames)
        if delivered > 0 {
            var remaining = delivered
            var destinationOffset = 0
            while remaining > 0 {
                let chunk = min(remaining, capacity - readIndex)
                storage.withUnsafeBufferPointer { buffer in
                    pointer.advanced(by: destinationOffset).update(
                        from: buffer.baseAddress!.advanced(by: readIndex),
                        count: chunk
                    )
                }
                readIndex = (readIndex + chunk) % capacity
                destinationOffset += chunk
                remaining -= chunk
            }
            storedFrames -= delivered
            readFrames &+= UInt64(delivered)
        }
        if delivered < count {
            memset(
                pointer.advanced(by: delivered),
                0,
                (count - delivered) * MemoryLayout<Float>.size
            )
            starvedFrames &+= UInt64(count - delivered)
        }
    }

    func snapshot() -> AudioSPSCRing.Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return AudioSPSCRing.Snapshot(
            writtenFrames: writtenFrames,
            readFrames: readFrames,
            availableFrames: storedFrames,
            droppedFrames: droppedFrames,
            starvedFrames: starvedFrames
        )
    }

    func flush() {
        lock.lock()
        writeIndex = 0
        readIndex = 0
        storedFrames = 0
        readPhase = 0
        lock.unlock()
    }
}
