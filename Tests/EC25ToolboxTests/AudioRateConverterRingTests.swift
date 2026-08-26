import XCTest
@testable import EC25Toolbox

final class AudioRateConverterRingTests: XCTestCase {
    func testPlaybackConversionKeepsPlannedClockWhenVirtualFormatIsStale() {
        let configuration = CoreAudioDuplexBridge.Configuration(
            macInputUID: nil,
            macOutputUID: nil,
            moduleCaptureUID: "module-capture",
            modulePlaybackUID: "module-playback",
            uplinkSourceRate: 24_000,
            uplinkTargetRate: 8_000,
            downlinkSourceRate: 8_000,
            downlinkTargetRate: 48_000
        )

        XCTAssertEqual(
            configuration.uplinkPlaybackClockRate(virtualFormatRate: 24_000),
            8_000
        )
        XCTAssertEqual(
            configuration.downlinkPlaybackClockRate(virtualFormatRate: 24_000),
            48_000
        )
    }

    func testEqualRateCopiesWithoutInterpolationLatency() {
        let ring = AudioRateConverterRing(capacityFrames: 16)
        let source: [Float] = [0, 1, 2, 3]
        source.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
        var output = [Float](repeating: -1, count: 4)
        output.withUnsafeMutableBufferPointer {
            ring.readResampled(into: $0.baseAddress!, count: 4, sourceRate: 48_000, targetRate: 48_000)
        }
        XCTAssertEqual(output, source)
    }

    func testFixedEightKilohertzSourceUpsamplesForMacOutput() {
        let ring = AudioRateConverterRing(capacityFrames: 32)
        let source: [Float] = [0, 1, 2, 3]
        source.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
        var output = [Float](repeating: 0, count: 12)
        output.withUnsafeMutableBufferPointer {
            ring.readResampled(into: $0.baseAddress!, count: 12, sourceRate: 8_000, targetRate: 48_000)
        }
        XCTAssertEqual(output[0], 0, accuracy: 0.001)
        XCTAssertEqual(output[3], 0.5, accuracy: 0.001)
        XCTAssertEqual(output[6], 1, accuracy: 0.001)
        XCTAssertTrue(output.contains { $0 > 1 })
    }

    func testMacInputDownsamplesForFixedModuleClock() {
        let ring = AudioRateConverterRing(capacityFrames: 64)
        let source = (0..<24).map(Float.init)
        source.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
        var output = [Float](repeating: 0, count: 4)
        output.withUnsafeMutableBufferPointer {
            ring.readResampled(into: $0.baseAddress!, count: 4, sourceRate: 48_000, targetRate: 8_000)
        }
        XCTAssertEqual(output[0], 0, accuracy: 0.001)
        XCTAssertEqual(output[1], 6, accuracy: 0.001)
        XCTAssertEqual(output[2], 12, accuracy: 0.001)
        XCTAssertEqual(output[3], 18, accuracy: 0.001)
    }

    func testUnderrunZeroFillsAndCounts() {
        let ring = AudioRateConverterRing(capacityFrames: 8)
        var output = [Float](repeating: 1, count: 5)
        output.withUnsafeMutableBufferPointer {
            ring.readResampled(into: $0.baseAddress!, count: 5, sourceRate: 8_000, targetRate: 48_000)
        }
        XCTAssertEqual(output, [0, 0, 0, 0, 0])
        XCTAssertEqual(ring.snapshot().starvedFrames, 5)
    }
}
