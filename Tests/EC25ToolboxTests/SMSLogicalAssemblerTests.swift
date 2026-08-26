import XCTest
@testable import EC25Toolbox

final class SMSLogicalAssemblerTests: XCTestCase {
    private let scope = SIMMessageScope(eid: "EID-A", iccid: "ICCID-A")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func segment(
        _ body: String,
        storage: String = "SM",
        index: Int,
        peer: String = "+8613800138000",
        raw: String = "26/08/21,10:00:00+32",
        unread: Bool = false,
        outgoing: Bool = false,
        reference: Int? = nil,
        total: Int? = nil,
        sequence: Int? = nil,
        binaryKind: String? = nil
    ) -> SMSTransportSegmentRecord {
        let timestamp = SMSTimeParsing.parse(raw: raw, resolvedAt: now)
        return SMSTransportSegmentRecord(
            id: SMSLogicalIdentity.segmentID(scopeID: scope.id, storage: storage, index: index),
            scopeID: scope.id,
            eid: scope.eid,
            iccid: scope.iccid,
            storage: storage,
            index: index,
            status: unread ? "REC UNREAD" : "REC READ",
            outgoing: outgoing,
            unread: unread,
            peer: peer,
            body: body,
            binaryKind: binaryKind,
            rawPDU: nil,
            reference: reference,
            total: total,
            sequence: sequence,
            rawServiceTimestamp: raw,
            instant: timestamp?.instant,
            sourceTimeZoneOffsetSeconds: timestamp?.sourceTimeZoneOffsetSeconds,
            centuryAnchor: timestamp.map { _ in now },
            assembly: .pending,
            consumedByLogicalID: nil,
            presentOnModem: true,
            firstSeenAt: now,
            updatedAt: now
        )
    }

    // MARK: - Completion and ordering

    func testOutOfOrderSegmentsMergeInSequenceOrder() {
        let segments = [
            segment("C", index: 3, raw: "26/08/21,10:02:00+32", reference: 5, total: 3, sequence: 3),
            segment("A", index: 1, raw: "26/08/21,10:00:00+32", unread: true, reference: 5, total: 3, sequence: 1),
            segment("B", index: 2, raw: "26/08/21,10:01:00+32", reference: 5, total: 3, sequence: 2),
        ]
        let outcome = SMSLogicalAssembler.assemble(segments: segments, scope: scope, now: now)
        XCTAssertEqual(outcome.logicals.count, 1)
        let merged = outcome.logicals[0]
        XCTAssertEqual(merged.body, "ABC")
        XCTAssertTrue(merged.unread, "any unread segment marks the message unread")
        XCTAssertEqual(merged.locations, [
            SMSMessageLocation(storage: "SM", index: 1),
            SMSMessageLocation(storage: "SM", index: 2),
            SMSMessageLocation(storage: "SM", index: 3),
        ])
        XCTAssertEqual(outcome.consumedSegmentIDs, Set(segments.map(\.id)))
        XCTAssertTrue(outcome.pendingSegmentIDs.isEmpty)
    }

    func testConcatenatedIDKeysOnAnchorTimestampNotBody() {
        let first = segment("A", index: 1, reference: 5, total: 2, sequence: 1)
        let second = segment("B", index: 2, reference: 5, total: 2, sequence: 2)
        let expected = SMSLogicalIdentity.concatenatedID(
            scopeID: scope.id,
            outgoing: false,
            peer: first.peer,
            reference: 5,
            total: 2,
            anchorRawTimestamp: first.rawServiceTimestamp!
        )
        let outcome = SMSLogicalAssembler.assemble(segments: [first, second], scope: scope, now: now)
        XCTAssertEqual(outcome.logicals[0].id, expected)
    }

    func testSixteenBitReferenceMerges() {
        let segments = [
            segment("X", index: 7, reference: 0x1234, total: 2, sequence: 1),
            segment("Y", index: 9, reference: 0x1234, total: 2, sequence: 2),
        ]
        let outcome = SMSLogicalAssembler.assemble(segments: segments, scope: scope, now: now)
        XCTAssertEqual(outcome.logicals.count, 1)
        XCTAssertEqual(outcome.logicals[0].body, "XY")
    }

    // MARK: - Hidden groups

    func testMissingSegmentStaysHiddenAsPending() {
        let segments = [
            segment("A", index: 1, reference: 5, total: 2, sequence: 1),
        ]
        let outcome = SMSLogicalAssembler.assemble(segments: segments, scope: scope, now: now)
        XCTAssertTrue(outcome.logicals.isEmpty, "incomplete groups never surface a message")
        XCTAssertEqual(outcome.pendingSegmentIDs, Set(segments.map(\.id)))
        XCTAssertTrue(outcome.consumedSegmentIDs.isEmpty)
    }

    func testLateSegmentCompletesGroupWithSameIdentity() {
        let first = segment("A", index: 1, reference: 5, total: 2, sequence: 1)
        let early = SMSLogicalAssembler.assemble(segments: [first], scope: scope, now: now)
        XCTAssertTrue(early.logicals.isEmpty)

        let second = segment("B", index: 2, raw: "26/08/21,10:01:00+32", reference: 5, total: 2, sequence: 2)
        let late = SMSLogicalAssembler.assemble(segments: [first, second], scope: scope, now: now)
        XCTAssertEqual(late.logicals.count, 1)
        XCTAssertEqual(late.logicals[0].body, "AB")
    }

    func testDuplicateSequenceAfterCompletionOpensNewHiddenCluster() {
        let seq1a = segment("A", index: 1, raw: "26/08/21,10:00:00+32", reference: 5, total: 2, sequence: 1)
        let seq2a = segment("B", index: 2, raw: "26/08/21,10:01:00+32", reference: 5, total: 2, sequence: 2)
        let complete = SMSLogicalAssembler.assemble(segments: [seq1a, seq2a], scope: scope, now: now)
        XCTAssertEqual(complete.logicals.count, 1)

        // Redelivery / reference reuse: a second seq-1 must not join the frozen
        // cluster, and on its own it stays hidden.
        let seq1b = segment("A'", index: 3, raw: "26/08/21,18:00:00+32", reference: 5, total: 2, sequence: 1)
        let redelivered = SMSLogicalAssembler.assemble(segments: [seq1a, seq2a, seq1b], scope: scope, now: now)
        XCTAssertEqual(redelivered.logicals.count, 1, "the duplicate never surfaces")
        XCTAssertEqual(redelivered.pendingSegmentIDs, [seq1b.id])
    }

    func testWraparoundFormsTwoCompleteClusters() {
        let segments = [
            segment("A", index: 1, raw: "26/08/21,10:00:00+32", reference: 5, total: 2, sequence: 1),
            segment("B", index: 2, raw: "26/08/21,10:01:00+32", reference: 5, total: 2, sequence: 2),
            segment("C", index: 3, raw: "26/08/22,10:00:00+32", reference: 5, total: 2, sequence: 1),
            segment("D", index: 4, raw: "26/08/22,10:01:00+32", reference: 5, total: 2, sequence: 2),
        ]
        let outcome = SMSLogicalAssembler.assemble(segments: segments, scope: scope, now: now)
        XCTAssertEqual(outcome.logicals.count, 2)
        XCTAssertEqual(Set(outcome.logicals.map(\.body)), ["AB", "CD"])
        XCTAssertNotEqual(outcome.logicals[0].id, outcome.logicals[1].id, "different anchors produce different ids")
        XCTAssertTrue(outcome.pendingSegmentIDs.isEmpty)
    }

    func testSegmentsOutsideClusteringWindowDoNotJoin() {
        let segments = [
            segment("A", index: 1, raw: "26/08/21,10:00:00+32", reference: 5, total: 2, sequence: 1),
            segment("B", index: 2, raw: "26/09/25,10:00:00+32", reference: 5, total: 2, sequence: 2),
        ]
        let outcome = SMSLogicalAssembler.assemble(segments: segments, scope: scope, now: now)
        XCTAssertTrue(outcome.logicals.isEmpty, "35 days apart: both stay pending")
        XCTAssertEqual(outcome.pendingSegmentIDs.count, 2)
    }

    func testDifferentReferencesPeersAndStoragesNeverMerge() {
        let segments = [
            segment("A", index: 1, reference: 5, total: 2, sequence: 1),
            segment("B", index: 2, reference: 6, total: 2, sequence: 2),
            segment("C", index: 3, peer: "+86555", reference: 5, total: 2, sequence: 2),
            segment("D", storage: "ME", index: 4, reference: 5, total: 2, sequence: 2),
        ]
        let outcome = SMSLogicalAssembler.assemble(segments: segments, scope: scope, now: now)
        XCTAssertTrue(outcome.logicals.isEmpty)
        XCTAssertEqual(outcome.pendingSegmentIDs.count, 4)
    }

    // MARK: - Singles and binary

    func testSinglesPassThroughWithV1CompatibleIdentity() {
        let single = segment("plain", index: 8, unread: true)
        let outcome = SMSLogicalAssembler.assemble(segments: [single], scope: scope, now: now)
        XCTAssertEqual(outcome.logicals.count, 1)
        let record = outcome.logicals[0]
        XCTAssertTrue(record.unread)
        XCTAssertEqual(record.body, "plain")
        XCTAssertEqual(
            record.id,
            SMSLogicalIdentity.singleID(
                scopeID: scope.id, outgoing: false, peer: single.peer,
                rawServiceTimestamp: single.rawServiceTimestamp!, body: "plain"
            )
        )
        XCTAssertEqual(outcome.consumedSegmentIDs, [single.id])
    }

    func testBinarySegmentsAreNeverMerged() {
        let segments = [
            segment("", index: 1, reference: 5, total: 2, sequence: 1, binaryKind: BinarySMSKind.unknownBinary.rawValue),
            segment("", index: 2, reference: 5, total: 2, sequence: 2, binaryKind: BinarySMSKind.unknownBinary.rawValue),
        ]
        let outcome = SMSLogicalAssembler.assemble(segments: segments, scope: scope, now: now)
        XCTAssertEqual(outcome.logicals.count, 2, "binary segments surface individually as read-only records")
        XCTAssertTrue(outcome.logicals.allSatisfy { $0.binaryKind == BinarySMSKind.unknownBinary.rawValue })
        XCTAssertTrue(outcome.pendingSegmentIDs.isEmpty)
    }
}
