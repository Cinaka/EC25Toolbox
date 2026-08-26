import XCTest
@testable import EC25Toolbox

/// R4 fallback-chain coverage: policy decisions, runtime bookkeeping, state
/// machine source inputs, and the new parsers.
final class GNSSSourceTests: XCTestCase {
    // MARK: - Policy

    func testPolicyKeepsSourceOnFixAndNoPosition() {
        XCTAssertEqual(
            GNSSSourcePolicy.evaluate(source: .qgpsloc2, outcome: .fix, consecutiveFailures: 1),
            GNSSSourcePolicy.Decision(advanceTo: nil, reason: nil, failureCount: 0)
        )
        // CME 516 means the engine runs but has no satellites in view; the
        // source itself is healthy.
        XCTAssertEqual(
            GNSSSourcePolicy.evaluate(source: .qgpsloc2, outcome: .noPosition, consecutiveFailures: 1),
            GNSSSourcePolicy.Decision(advanceTo: nil, reason: nil, failureCount: 0)
        )
    }

    func testPolicyAdvancesAfterConsecutiveFailures() {
        let first = GNSSSourcePolicy.evaluate(
            source: .qgpsloc2, outcome: .failure("+CME ERROR: 504"), consecutiveFailures: 0
        )
        XCTAssertEqual(first.advanceTo, nil)
        XCTAssertEqual(first.failureCount, 1)

        let second = GNSSSourcePolicy.evaluate(
            source: .qgpsloc2, outcome: .failure("+CME ERROR: 504"), consecutiveFailures: 1
        )
        XCTAssertEqual(second.advanceTo, .qgpsloc)
        XCTAssertEqual(second.reason, "+CME ERROR: 504")
        XCTAssertEqual(second.failureCount, 0)
    }

    func testPolicyTerminalSourceNeverAdvances() {
        let decision = GNSSSourcePolicy.evaluate(
            source: .nmeaPort, outcome: .failure("usb read failed"), consecutiveFailures: 5
        )
        XCTAssertNil(decision.advanceTo)
        XCTAssertNil(decision.reason)
        XCTAssertEqual(decision.failureCount, 6)
    }

    func testSourceChainOrder() {
        XCTAssertEqual(GNSSDataSource.qgpsloc2.fallback, .qgpsloc)
        XCTAssertEqual(GNSSDataSource.qgpsloc.fallback, .qgpsgnmea)
        XCTAssertEqual(GNSSDataSource.qgpsgnmea.fallback, .nmeaPort)
        XCTAssertNil(GNSSDataSource.nmeaPort.fallback)
        XCTAssertEqual(GNSSDataSource.qgpsloc2.atCommand, "AT+QGPSLOC=2")
        XCTAssertEqual(GNSSDataSource.qgpsloc.atCommand, "AT+QGPSLOC")
        XCTAssertEqual(GNSSDataSource.qgpsgnmea.atCommand, "AT+QGPSGNMEA")
        XCTAssertNil(GNSSDataSource.nmeaPort.atCommand)
    }

    func testRuntimeResetsOnDeliveryAndAdvance() {
        var runtime = GNSSSourceRuntime()
        runtime.apply(GNSSSourcePolicy.Decision(advanceTo: nil, reason: nil, failureCount: 1))
        runtime.delivered()
        XCTAssertEqual(runtime.consecutiveFailures, 0)

        runtime.apply(GNSSSourcePolicy.Decision(advanceTo: .qgpsloc, reason: "+CME ERROR: 504", failureCount: 0))
        XCTAssertEqual(runtime.current, .qgpsloc)
        XCTAssertEqual(runtime.consecutiveFailures, 0)
    }

    // MARK: - State machine source bookkeeping

    func testMachineRecordsSourceAndFallbackReason() {
        var machine = GNSSStateMachine()
        machine.handle(.start, now: Date())
        machine.handle(.source(.qgpsloc2), now: Date())
        XCTAssertEqual(machine.status.dataSource, .qgpsloc2)

        machine.handle(.sourceFallback("+CME ERROR: 504"), now: Date())
        XCTAssertEqual(machine.status.sourceFailure, "+CME ERROR: 504")
        // Bookkeeping does not change the phase.
        XCTAssertEqual(machine.status.phase, .searching)
    }

    func testStopAndTransportLostClearSourceFields() {
        var machine = GNSSStateMachine()
        machine.handle(.start, now: Date())
        machine.handle(.source(.qgpsgnmea), now: Date())
        machine.handle(.sourceFallback("endpoint gone"), now: Date())

        machine.handle(.stop, now: Date())
        XCTAssertNil(machine.status.dataSource)
        XCTAssertNil(machine.status.sourceFailure)

        machine.handle(.start, now: Date())
        machine.handle(.source(.nmeaPort), now: Date())
        machine.handle(.transportLost, now: Date())
        XCTAssertNil(machine.status.dataSource)
        XCTAssertNil(machine.status.sourceFailure)
        XCTAssertEqual(machine.status.phase, .lost)
    }

    func testSourceInputsIgnoredWhileEngineOff() {
        var machine = GNSSStateMachine()
        machine.handle(.source(.qgpsloc), now: Date())
        machine.handle(.sourceFallback("reason"), now: Date())
        XCTAssertNil(machine.status.dataSource)
        XCTAssertNil(machine.status.sourceFailure)
    }

    // MARK: - Parsing additions

    func testParseQGPSState() {
        XCTAssertEqual(GNSSParsing.parseQGPSState(["+QGPS: 0", "OK"]), false)
        XCTAssertEqual(GNSSParsing.parseQGPSState(["+QGPS: 1", "OK"]), true)
        XCTAssertNil(GNSSParsing.parseQGPSState(["OK"]))
        XCTAssertNil(GNSSParsing.parseQGPSState(["+QGPS: x", "OK"]))
    }

    func testQGPSGNMEASentenceExtraction() {
        let sentences = GNSSParsing.parseQGPSGNMEASentences([
            "OK",
            "$GNRMC,061951.000,A,3150.7223,N,11711.9293,E,0.6,12.50,230513,,,A*79",
            "$GNGGA,061951.000,3150.7223,N,11711.9293,E,1,09,1.1,90.0,M,0.0,M,,*4D"
        ])
        XCTAssertEqual(sentences.count, 2)
        XCTAssertTrue(sentences.allSatisfy { $0.hasPrefix("$") })
        // Empty engine output is a no-position answer, not an error.
        XCTAssertTrue(GNSSParsing.parseQGPSGNMEASentences(["OK"]).isEmpty)
    }

    func testFixFromNMEACombinesRMCAndGGA() {
        let fix = GNSSParsing.fixFromNMEA([
            "$GNRMC,061951.000,A,3150.7223,N,11711.9293,E,0.6,12.50,230513,,,A*79",
            "$GNGGA,061951.000,3150.7223,N,11711.9293,E,1,09,1.1,90.0,M,0.0,M,,*4D"
        ])
        XCTAssertEqual(fix?.latitude ?? 0, 31.845371, accuracy: 0.000001)
        XCTAssertEqual(fix?.longitude ?? 0, 117.198821, accuracy: 0.000001)
        XCTAssertEqual(fix?.satelliteCount, 9)
        XCTAssertEqual(fix?.hdop, 1.1)
        XCTAssertEqual(fix?.altitudeMeters, 90.0)
        XCTAssertEqual(fix?.speedKnots, 0.6)
        // knots → km/h
        XCTAssertEqual(fix?.speedKmh ?? 0, 0.6 * 1.852, accuracy: 0.001)
        XCTAssertEqual(fix?.courseDegrees, 12.5)
        XCTAssertEqual(fix?.date, "230513")
    }

    func testFixFromNMEARejectsVoidRMCWithoutGGA() {
        XCTAssertNil(GNSSParsing.fixFromNMEA(["$GNRMC,120000.000,V,,,,,,,010124,,,N*56"]))
        // Void RMC plus a quality GGA still yields a position.
        let fix = GNSSParsing.fixFromNMEA([
            "$GNRMC,120000.000,V,,,,,,,010124,,,N*56",
            "$GNGGA,061951.000,3150.7223,N,11711.9293,E,1,09,1.1,90.0,M,0.0,M,,*4D"
        ])
        XCTAssertEqual(fix?.latitude ?? 0, 31.845371, accuracy: 0.000001)
        // A GGA without a fix (quality 0) is not a position either.
        XCTAssertNil(GNSSParsing.fixFromNMEA(["$GNGGA,061951.000,,,,,0,00,,,,,,*40"]))
    }

    func testCMECodeExtractionAndNoPositionDetection() {
        XCTAssertEqual(GNSSParsing.cmeErrorCode(in: "+CME ERROR: 516"), 516)
        XCTAssertEqual(GNSSParsing.cmeErrorCode(in: "+CME ERROR: 504"), 504)
        // Verbose CMEE=2 phrasing carries no number.
        XCTAssertNil(GNSSParsing.cmeErrorCode(in: "+CME ERROR: not fixed now"))
        XCTAssertNil(GNSSParsing.cmeErrorCode(in: "command timeout"))

        XCTAssertTrue(GNSSParsing.isNoPositionError("+CME ERROR: 516"))
        XCTAssertTrue(GNSSParsing.isNoPositionError("+CME ERROR: not fixed now"))
        XCTAssertTrue(GNSSParsing.isNoPositionError("+CME ERROR: gps not fixed now"))
        XCTAssertFalse(GNSSParsing.isNoPositionError("+CME ERROR: 504"))
        XCTAssertFalse(GNSSParsing.isNoPositionError("command timeout"))
    }
}
