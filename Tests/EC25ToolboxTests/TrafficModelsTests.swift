@testable import EC25Toolbox
import XCTest

final class TrafficModelsTests: XCTestCase {
    private func sample(_ seconds: Double, _ bytesIn: UInt64, _ bytesOut: UInt64) -> TrafficSample {
        TrafficSample(date: Date(timeIntervalSinceReferenceDate: seconds), bytesIn: bytesIn, bytesOut: bytesOut)
    }

    // MARK: - Step math

    func testStepComputesRatesAndTotals() throws {
        let step = try XCTUnwrap(TrafficMath.step(
            session: nil,
            previous: sample(0, 1_000, 500),
            current: sample(2, 3_000, 1_500)
        ))
        XCTAssertEqual(step.point.bytesInPerSecond, 1_000, accuracy: 0.001)
        XCTAssertEqual(step.point.bytesOutPerSecond, 500, accuracy: 0.001)
        XCTAssertEqual(step.session.startedAt, sample(0, 0, 0).date)
        XCTAssertEqual(step.session.bytesIn, 2_000)
        XCTAssertEqual(step.session.bytesOut, 1_000)
        XCTAssertEqual(step.session.peakBytesInPerSecond, 1_000, accuracy: 0.001)
    }

    func testStepAccumulatesAcrossSamples() throws {
        var session: TrafficSessionStats?
        let first = try XCTUnwrap(TrafficMath.step(
            session: session,
            previous: sample(0, 0, 0),
            current: sample(2, 100, 50)
        ))
        session = first.session
        let second = try XCTUnwrap(TrafficMath.step(
            session: session,
            previous: sample(2, 100, 50),
            current: sample(4, 500, 100)
        ))
        session = second.session
        let accumulated = try XCTUnwrap(session)
        XCTAssertEqual(second.point.bytesInPerSecond, 200, accuracy: 0.001)
        XCTAssertEqual(accumulated.bytesIn, 500)
        XCTAssertEqual(accumulated.bytesOut, 100)
        XCTAssertEqual(accumulated.peakBytesInPerSecond, 200, accuracy: 0.001)
        XCTAssertTrue(accumulated.hasTraffic)
    }

    func testStepTreatsCounterResetAsZero() throws {
        // Service toggle or re-enumeration resets counters; deltas go to 0.
        let step = try XCTUnwrap(TrafficMath.step(
            session: TrafficSessionStats(startedAt: sample(0, 0, 0).date, bytesIn: 9_000, bytesOut: 9_000),
            previous: sample(10, 10_000, 8_000),
            current: sample(12, 100, 100)
        ))
        XCTAssertEqual(step.point.bytesInPerSecond, 0)
        XCTAssertEqual(step.point.bytesOutPerSecond, 0)
        // Session totals keep what was accumulated before the reset.
        XCTAssertEqual(step.session.bytesIn, 9_000)
        XCTAssertEqual(step.session.bytesOut, 9_000)
    }

    func testStepRejectsNonAdvancingClock() {
        XCTAssertNil(TrafficMath.step(
            session: nil,
            previous: sample(5, 100, 100),
            current: sample(5, 200, 200)
        ))
        XCTAssertNil(TrafficMath.step(
            session: nil,
            previous: sample(6, 100, 100),
            current: sample(5, 200, 200)
        ))
    }

    // MARK: - Series trimming

    func testTrafficStatusTrimsPointHistory() {
        var status = TrafficStatus()
        for index in 0..<(TrafficStatus.maxPoints + 40) {
            status.append(TrafficRatePoint(
                date: Date(timeIntervalSinceReferenceDate: Double(index)),
                bytesInPerSecond: 1,
                bytesOutPerSecond: 1
            ))
        }
        XCTAssertEqual(status.points.count, TrafficStatus.maxPoints)
        XCTAssertEqual(status.points.first?.date, Date(timeIntervalSinceReferenceDate: 40))
    }

    // MARK: - Archive store

    private func makeRecord(_ id: UInt32, bytesIn: UInt64) -> TrafficSessionRecord {
        TrafficSessionRecord(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, UInt8(id & 0xFF), 0, 0, 0, 0, 0, 0, 0, 0)),
            startedAt: Date(timeIntervalSinceReferenceDate: Double(id) * 100),
            endedAt: Date(timeIntervalSinceReferenceDate: Double(id) * 100 + 50),
            bytesIn: bytesIn,
            bytesOut: bytesIn / 2,
            peakBytesInPerSecond: 1_000,
            peakBytesOutPerSecond: 500
        )
    }

    func testArchiveRoundTripAndLastSession() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ec25-traffic-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TrafficArchiveStore(fileURL: url)

        XCTAssertNil(store.lastSession())
        XCTAssertTrue(store.records().isEmpty)

        store.record(makeRecord(1, bytesIn: 1_000))
        store.record(makeRecord(2, bytesIn: 2_000))
        XCTAssertEqual(store.records().count, 2)
        XCTAssertEqual(store.lastSession()?.bytesIn, 2_000)

        // Re-recording the same id replaces instead of duplicating.
        store.record(makeRecord(2, bytesIn: 5_000))
        XCTAssertEqual(store.records().count, 2)
        XCTAssertEqual(store.lastSession()?.bytesIn, 5_000)
    }

    func testArchiveCapsHistory() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ec25-traffic-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TrafficArchiveStore(fileURL: url)
        for index in 0..<70 {
            store.record(makeRecord(UInt32(index), bytesIn: UInt64(index)))
        }
        XCTAssertEqual(store.records().count, 60)
        // Oldest records were trimmed, newest kept.
        XCTAssertEqual(store.records().first?.bytesIn, 10)
        XCTAssertEqual(store.lastSession()?.bytesIn, 69)
    }

    func testArchiveSurvivesCorruptFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ec25-traffic-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let store = TrafficArchiveStore(fileURL: url)
        XCTAssertNil(store.lastSession())
        store.record(makeRecord(1, bytesIn: 42))
        XCTAssertEqual(store.lastSession()?.bytesIn, 42)
    }
}
