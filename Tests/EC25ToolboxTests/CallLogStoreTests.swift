import XCTest
@testable import EC25Toolbox

final class CallLogStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        super.tearDown()
    }

    private func makeStore() -> CallLogStore {
        CallLogStore(applicationSupportDirectory: temporaryDirectory)
    }

    func testRoundTripAndScopeIsolation() {
        let store = makeStore()
        let scopeA = SIMMessageScope(eid: "EID-A", iccid: "8986A")
        let scopeB = SIMMessageScope(eid: nil, iccid: "8986B")

        let events = [
            CallEvent(title: "phone.call.missed", detail: "+8613", failed: false),
            CallEvent(title: "phone.ended", detail: "10086", failed: true)
        ]
        store.replace(events, scope: scopeA)
        store.replace([], scope: scopeB)

        let loaded = store.load(scope: scopeA)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.title), ["phone.call.missed", "phone.ended"])
        XCTAssertEqual(loaded.map(\.detail), ["+8613", "10086"])
        XCTAssertEqual(loaded.map(\.failed), [false, true])
        XCTAssertTrue(store.load(scope: scopeB).isEmpty)
        // The same identity re-derives the same bucket.
        XCTAssertEqual(store.load(scope: SIMMessageScope(eid: "EID-A", iccid: "8986A")).count, 2)
    }

    func testEmptyReplaceRemovesFileAndMissingScopeIsEmpty() {
        let store = makeStore()
        let scope = SIMMessageScope(eid: nil, iccid: "8986C")
        XCTAssertTrue(store.load(scope: scope).isEmpty)
        store.replace([CallEvent(title: "phone.ended", detail: "x")], scope: scope)
        XCTAssertEqual(store.load(scope: scope).count, 1)
        store.replace([], scope: scope)
        XCTAssertTrue(store.load(scope: scope).isEmpty)
    }

    func testCorruptFileReturnsEmpty() throws {
        let store = makeStore()
        let scope = SIMMessageScope(eid: nil, iccid: "8986D")
        store.replace([CallEvent(title: "a", detail: "b")], scope: scope)
        try Data("not json".utf8).write(to: store.url(for: scope), options: .atomic)
        XCTAssertTrue(store.load(scope: scope).isEmpty)
    }

    func testCallEventCodableRoundTrip() throws {
        let acknowledgedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CallEvent(
            title: "phone.call.missed",
            detail: "+8613",
            failed: true,
            acknowledgedAt: acknowledgedAt
        )
        let data = try JSONEncoder().encode([event])
        let decoded = try JSONDecoder().decode([CallEvent].self, from: data)
        XCTAssertEqual(decoded, [event])
        XCTAssertFalse(decoded[0].isUnacknowledgedMissedCall)
    }

    func testSameSIMLoadsModuleProvenanceAfterHardwareMove() {
        let store = makeStore()
        let cardScope = SIMMessageScope(eid: "EID-CARD-A", iccid: "ICCID-CARD-A")
        let event = CallEvent(
            title: "phone.call.missed",
            detail: "+8613800138000",
            moduleID: "module-a",
            moduleSerialNumber: "SERIAL-A",
            moduleName: "Desk modem"
        )

        store.replace([event], scope: cardScope)

        // A store attached to module B derives the same SIM scope and reads
        // the history without changing its recorded source module.
        let loadedOnModuleB = store.load(scope: SIMMessageScope(
            eid: "EID-CARD-A",
            iccid: "ICCID-CARD-A"
        ))
        XCTAssertEqual(loadedOnModuleB, [event])
        XCTAssertEqual(loadedOnModuleB[0].moduleID, "module-a")
        XCTAssertEqual(loadedOnModuleB[0].moduleSerialNumber, "SERIAL-A")
    }

    func testLegacyCallEventWithoutAcknowledgementStillDecodesAsMissed() throws {
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","date":0,"title":"phone.call.missed","detail":"13800138000","failed":false}]
        """
        let decoded = try JSONDecoder().decode([CallEvent].self, from: Data(json.utf8))
        XCTAssertNil(decoded[0].acknowledgedAt)
        XCTAssertTrue(decoded[0].isUnacknowledgedMissedCall)
    }
}
