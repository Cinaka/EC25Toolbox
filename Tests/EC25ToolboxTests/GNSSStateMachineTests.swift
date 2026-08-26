import XCTest
@testable import EC25Toolbox

final class GNSSStateMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func fix(
        hdop: Double? = 1.0,
        satellites: Int? = 8,
        acquiredAt: Date = .distantPast
    ) -> GNSSFix {
        GNSSFix(
            utc: "061951.000",
            latitude: 31.84,
            longitude: 117.19,
            hdop: hdop,
            satelliteCount: satellites,
            acquiredAt: acquiredAt
        )
    }

    func testStartMovesOffToSearching() {
        var machine = GNSSStateMachine()
        let transition = machine.handle(.start, now: t0)
        XCTAssertEqual(transition, GNSSTransition(from: .off, to: .searching))
        XCTAssertEqual(machine.status.phase, .searching)
        XCTAssertEqual(machine.status.searchingSince, t0)
        XCTAssertTrue(machine.isEngineRunning)
    }

    func testRepeatedStartDoesNotResetSearch() {
        var machine = GNSSStateMachine()
        machine.handle(.start, now: t0)
        XCTAssertNil(machine.handle(.start, now: t0.addingTimeInterval(5)))
        XCTAssertEqual(machine.status.searchingSince, t0)
    }

    func testGoodFixMovesToFixed() {
        var machine = GNSSStateMachine()
        machine.handle(.start, now: t0)
        let transition = machine.handle(.fix(fix()), now: t0.addingTimeInterval(10))
        XCTAssertEqual(transition, GNSSTransition(from: .searching, to: .fixed))
        XCTAssertEqual(machine.status.phase, .fixed)
        XCTAssertEqual(machine.status.lastFix?.latitude, 31.84)
        // acquiredAt is injected by the machine when unset.
        XCTAssertEqual(machine.status.lastFix?.acquiredAt, t0.addingTimeInterval(10))
    }

    func testWeakFixByHDOPAndBySatelliteCount() {
        var machine = GNSSStateMachine()
        machine.handle(.start, now: t0)
        machine.handle(.fix(fix(hdop: 12)), now: t0.addingTimeInterval(1))
        XCTAssertEqual(machine.status.phase, .weak)

        machine.handle(.fix(fix(hdop: 1, satellites: 3)), now: t0.addingTimeInterval(2))
        XCTAssertEqual(machine.status.phase, .weak)

        let transition = machine.handle(.fix(fix(hdop: 1, satellites: 9)), now: t0.addingTimeInterval(3))
        XCTAssertEqual(transition, GNSSTransition(from: .weak, to: .fixed))
    }

    func testFixUpdatesSnapshotWithoutTransition() {
        var machine = GNSSStateMachine()
        machine.handle(.start, now: t0)
        machine.handle(.fix(fix()), now: t0.addingTimeInterval(1))
        XCTAssertNil(machine.handle(.fix(fix(hdop: 2)), now: t0.addingTimeInterval(2)))
        XCTAssertEqual(machine.status.phase, .fixed)
        XCTAssertEqual(machine.status.lastFix?.hdop, 2)
    }

    func testSearchingTimesOut() {
        var machine = GNSSStateMachine()
        machine.handle(.start, now: t0)
        XCTAssertNil(machine.handle(.tick, now: t0.addingTimeInterval(119)))
        let transition = machine.handle(.tick, now: t0.addingTimeInterval(120))
        XCTAssertEqual(transition, GNSSTransition(from: .searching, to: .timeout))
        // A fix after the timeout still recovers the engine.
        let recovered = machine.handle(.fix(fix()), now: t0.addingTimeInterval(130))
        XCTAssertEqual(recovered, GNSSTransition(from: .timeout, to: .fixed))
    }

    func testStaleFixReturnsToSearching() {
        var machine = GNSSStateMachine()
        machine.handle(.start, now: t0)
        machine.handle(.fix(fix()), now: t0.addingTimeInterval(1))
        XCTAssertNil(machine.handle(.tick, now: t0.addingTimeInterval(30)))
        let transition = machine.handle(.tick, now: t0.addingTimeInterval(32))
        XCTAssertEqual(transition, GNSSTransition(from: .fixed, to: .searching))
        XCTAssertEqual(machine.status.phase, .searching)
        XCTAssertEqual(machine.status.searchingSince, t0.addingTimeInterval(32))
    }

    func testStopClearsEverything() {
        var machine = GNSSStateMachine()
        machine.handle(.start, now: t0)
        machine.handle(.fix(fix()), now: t0.addingTimeInterval(1))
        let transition = machine.handle(.stop, now: t0.addingTimeInterval(2))
        XCTAssertEqual(transition, GNSSTransition(from: .fixed, to: .off))
        XCTAssertEqual(machine.status.phase, .off)
        XCTAssertNil(machine.status.lastFix)
        XCTAssertNil(machine.status.searchingSince)
        XCTAssertFalse(machine.isEngineRunning)
        XCTAssertNil(machine.handle(.stop, now: t0.addingTimeInterval(3)))
    }

    func testTransportLostOnlyWhenRunning() {
        var machine = GNSSStateMachine()
        XCTAssertNil(machine.handle(.transportLost, now: t0))
        machine.handle(.start, now: t0)
        let transition = machine.handle(.transportLost, now: t0.addingTimeInterval(1))
        XCTAssertEqual(transition, GNSSTransition(from: .searching, to: .lost))
        XCTAssertFalse(machine.isEngineRunning)
        // Starting again after a loss re-enters searching.
        XCTAssertEqual(machine.handle(.start, now: t0.addingTimeInterval(2)),
                       GNSSTransition(from: .lost, to: .searching))
    }

    func testFixWhileOffIsIgnored() {
        var machine = GNSSStateMachine()
        XCTAssertNil(machine.handle(.fix(fix()), now: t0))
        XCTAssertEqual(machine.status.phase, .off)
        XCTAssertNil(machine.status.lastFix)
    }

    func testNoFixKeepsPhase() {
        var machine = GNSSStateMachine()
        machine.handle(.start, now: t0)
        XCTAssertNil(machine.handle(.noFix, now: t0.addingTimeInterval(1)))
        XCTAssertEqual(machine.status.phase, .searching)
    }

    func testQueryFailedRecordsError() {
        var machine = GNSSStateMachine()
        machine.handle(.start, now: t0)
        XCTAssertNil(machine.handle(.queryFailed("+CME ERROR: 502"), now: t0.addingTimeInterval(1)))
        XCTAssertEqual(machine.status.lastError, "+CME ERROR: 502")
        XCTAssertEqual(machine.status.phase, .searching)
        XCTAssertNil(machine.handle(.queryFailed("x"), now: t0.addingTimeInterval(2)))
    }
}
