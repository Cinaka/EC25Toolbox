import XCTest
@testable import EC25Toolbox

/// R14: the bounded SPSC mono ring that carries voice frames between IOProcs —
/// FIFO order, bounded overrun drops, underrun zero-fills, wrap-around, and
/// counter accounting.
final class AudioSPSCRingTests: XCTestCase {
    func testFIFOOrder() {
        let ring = AudioSPSCRing(capacityFrames: 8)
        let input: [Float] = [1, 2, 3, 4]
        input.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, count: input.count)
        }
        var output = [Float](repeating: -1, count: 4)
        output.withUnsafeMutableBufferPointer { pointer in
            ring.read(into: pointer.baseAddress!, count: 4)
        }
        XCTAssertEqual(output, input)
        XCTAssertEqual(ring.snapshot().availableFrames, 0)
    }

    func testOverrunDropsNewestAndCounts() {
        let ring = AudioSPSCRing(capacityFrames: 4)
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        input.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, count: input.count)
        }
        let snapshot = ring.snapshot()
        XCTAssertEqual(snapshot.availableFrames, 4)
        XCTAssertEqual(snapshot.droppedFrames, 2)
        XCTAssertEqual(snapshot.writtenFrames, 4)
        var output = [Float](repeating: -1, count: 4)
        output.withUnsafeMutableBufferPointer { pointer in
            ring.read(into: pointer.baseAddress!, count: 4)
        }
        // The newest samples (5, 6) were dropped; the ring kept 1–4.
        XCTAssertEqual(output, [1, 2, 3, 4])
    }

    func testUnderrunZeroFillsAndCounts() {
        let ring = AudioSPSCRing(capacityFrames: 8)
        let input: [Float] = [7, 8]
        input.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, count: input.count)
        }
        var output = [Float](repeating: -1, count: 4)
        output.withUnsafeMutableBufferPointer { pointer in
            ring.read(into: pointer.baseAddress!, count: 4)
        }
        XCTAssertEqual(output, [7, 8, 0, 0])
        XCTAssertEqual(ring.snapshot().starvedFrames, 2)
        XCTAssertEqual(ring.snapshot().availableFrames, 0)
    }

    func testWrapAroundPreservesContinuity() {
        let ring = AudioSPSCRing(capacityFrames: 4)
        var expected: [Float] = []
        for round in 0..<5 {
            let chunk: [Float] = [Float(10 * round + 1), Float(10 * round + 2), Float(10 * round + 3)]
            expected.append(contentsOf: chunk)
            chunk.withUnsafeBufferPointer { pointer in
                ring.write(pointer.baseAddress!, count: chunk.count)
            }
            var drained = [Float](repeating: -1, count: 3)
            drained.withUnsafeMutableBufferPointer { pointer in
                ring.read(into: pointer.baseAddress!, count: 3)
            }
            XCTAssertEqual(drained, chunk)
        }
        XCTAssertEqual(ring.snapshot().readFrames, UInt64(expected.count))
        XCTAssertEqual(ring.snapshot().droppedFrames, 0)
        XCTAssertEqual(ring.snapshot().starvedFrames, 0)
    }

    func testFlushClearsContentKeepsCounters() {
        let ring = AudioSPSCRing(capacityFrames: 8)
        let input: [Float] = [1, 2, 3]
        input.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, count: input.count)
        }
        ring.flush()
        let snapshot = ring.snapshot()
        XCTAssertEqual(snapshot.availableFrames, 0)
        XCTAssertEqual(snapshot.writtenFrames, 3, "counters survive a flush for diagnostics")
        var drained = [Float](repeating: -1, count: 2)
        drained.withUnsafeMutableBufferPointer { pointer in
            ring.read(into: pointer.baseAddress!, count: 2)
        }
        XCTAssertEqual(drained, [0, 0], "reading an empty ring zero-fills")
        XCTAssertEqual(ring.snapshot().starvedFrames, 2)
    }

    func testInterleavedProducerConsumerNeverMixesOrder() {
        // Simulates the bridge's cadence: alternating, differently sized
        // writes and reads on a tight ring. Every delivered sample must come
        // out in write order; only drops (counted) may remove samples.
        let ring = AudioSPSCRing(capacityFrames: 32)
        var nextToWrite: Float = 0
        var nextExpected: Float = 0
        var readBuffer = [Float](repeating: -1, count: 24)

        func write(_ count: Int) {
            var chunk = [Float](repeating: 0, count: count)
            for index in 0..<count {
                chunk[index] = nextToWrite
                nextToWrite += 1
            }
            chunk.withUnsafeBufferPointer { pointer in
                ring.write(pointer.baseAddress!, count: count)
            }
        }

        func read(_ count: Int) {
            readBuffer = [Float](repeating: -1, count: count)
            readBuffer.withUnsafeMutableBufferPointer { pointer in
                ring.read(into: pointer.baseAddress!, count: count)
            }
            for sample in readBuffer {
                if sample >= nextExpected {
                    XCTAssertEqual(sample, nextExpected, "frames must advance in write order")
                    nextExpected += 1
                }
                // Samples below nextExpected were dropped by overrun; drops
                // are verified separately through the counters.
            }
        }

        let pattern: [(Int, Int)] = [
            (20, 8), (20, 16), (8, 24), (20, 4), (4, 24), (20, 20), (16, 16), (12, 24)
        ]
        for (writeCount, readCount) in pattern {
            write(writeCount)
            read(readCount)
        }

        let snapshot = ring.snapshot()
        XCTAssertEqual(snapshot.writtenFrames,
                       snapshot.readFrames + UInt64(snapshot.availableFrames),
                       "accepted == delivered + still buffered")
        XCTAssertEqual(snapshot.droppedFrames + snapshot.readFrames + UInt64(snapshot.availableFrames),
                       UInt64(Int(nextToWrite)),
                       "every produced frame is either delivered, buffered, or counted as dropped")
    }
}
