import Foundation
import XCTest
@testable import EC25Toolbox

/// Pure-value classification matrix for the R18 projection repairer.
final class SMSArchiveRepairerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let scope = SIMMessageScope(eid: "EID-REPAIR", iccid: "ICCID-REPAIR")

    private func segmentRecord(
        _ body: String,
        index: Int,
        sender: String = "+86100",
        date: String = "26/07/15,10:00:00+32",
        reference: Int? = nil,
        total: Int? = nil,
        sequence: Int? = nil
    ) -> SMSTransportSegmentRecord {
        let id = SMSLogicalIdentity.segmentID(scopeID: scope.id, storage: "SM", index: index)
        let timestamp = SMSTimeParsing.parse(raw: date, resolvedAt: now)
        return SMSTransportSegmentRecord(
            id: id,
            scopeID: scope.id,
            eid: scope.eid,
            iccid: scope.iccid,
            storage: "SM",
            index: index,
            status: "REC READ",
            outgoing: false,
            unread: false,
            peer: sender,
            body: body,
            binaryKind: nil,
            rawPDU: nil,
            reference: reference,
            total: total,
            sequence: sequence,
            rawServiceTimestamp: date,
            instant: timestamp?.instant,
            sourceTimeZoneOffsetSeconds: timestamp?.sourceTimeZoneOffsetSeconds,
            centuryAnchor: now,
            assembly: .pending,
            consumedByLogicalID: nil,
            presentOnModem: true,
            firstSeenAt: now,
            updatedAt: now
        )
    }

    private func record(
        id: String,
        body: String,
        locations: [SMSMessageLocation],
        segmentIDs: [String] = [],
        outgoing: Bool = false,
        peer: String = "+86100",
        origin: String = "SM",
        unread: Bool = false,
        notifiedAt: Date? = nil,
        deletedAt: Date? = nil
    ) -> SMSLogicalRecord {
        SMSLogicalRecord(
            id: id,
            scopeID: scope.id,
            eid: scope.eid,
            iccid: scope.iccid,
            origin: origin,
            outgoing: outgoing,
            unread: unread,
            peer: peer,
            body: body,
            binaryKind: nil,
            rawServiceTimestamp: "26/07/15,10:00:00+32",
            instant: now,
            sourceTimeZoneOffsetSeconds: 8 * 3_600,
            centuryAnchor: now,
            concatReference: nil,
            concatTotal: nil,
            segmentIDs: segmentIDs,
            locations: locations,
            presentOnModem: false,
            notifiedAt: notifiedAt,
            firstSeenAt: now,
            updatedAt: now,
            deletedAt: deletedAt
        )
    }

    private func repair(
        logical: [SMSLogicalRecord] = [],
        quarantine: [SMSLogicalRecord] = [],
        segments: [SMSTransportSegmentRecord] = [],
        idRemap: [String: String] = [:]
    ) -> SMSArchiveRepairer.Outcome {
        SMSArchiveRepairer.repair(
            logical: logical,
            quarantine: quarantine,
            segments: segments,
            idRemap: idRemap,
            now: now
        )
    }

    private var completeGroup: [SMSTransportSegmentRecord] {
        [
            segmentRecord("part one", index: 1, reference: 21, total: 2, sequence: 1),
            segmentRecord("part two", index: 2, date: "26/07/15,10:01:00+32", reference: 21, total: 2, sequence: 2),
        ]
    }

    func testLocalOnlyRecordsPassThroughUntouched() {
        let sent = record(id: "sent-1", body: "hi", locations: [], origin: "SENT")
        let vowifi = record(id: "vowifi-1", body: "yo", locations: [], origin: "VOWIFI")
        let outcome = repair(logical: [sent, vowifi], segments: completeGroup)
        XCTAssertTrue(outcome.logical.contains(sent))
        XCTAssertTrue(outcome.logical.contains(vowifi))
        XCTAssertEqual(outcome.quarantine.count, 0)
    }

    func testReproducedCanonicalInheritsState() {
        let segments = completeGroup
        let canonicalID = SMSLogicalIdentity.concatenatedID(
            scopeID: scope.id,
            outgoing: false,
            peer: "+86100",
            reference: 21,
            total: 2,
            anchorRawTimestamp: "26/07/15,10:00:00+32"
        )
        let stored = record(
            id: canonicalID,
            body: "stale body",
            locations: [SMSMessageLocation(storage: "SM", index: 1)],
            notifiedAt: now
        )
        let outcome = repair(logical: [stored], segments: segments)
        XCTAssertEqual(outcome.logical.count { $0.id == canonicalID }, 1)
        let canonical = outcome.logical.first { $0.id == canonicalID }!
        XCTAssertEqual(canonical.body, "part onepart two", "the fresh projection wins the content")
        XCTAssertEqual(canonical.notifiedAt, now, "announced state survives the rebuild")

        let tombstoned = record(
            id: canonicalID,
            body: "stale body",
            locations: [],
            deletedAt: now
        )
        let deleted = repair(logical: [tombstoned], segments: segments)
        XCTAssertEqual(deleted.diagnostics.visibleLogical, 0, "a user deletion always wins over the fresh projection")
    }

    func testLegacyFragmentWithConcatLocationIsQuarantinedAndRemapped() {
        let segments = completeGroup
        let canonicalID = SMSLogicalIdentity.concatenatedID(
            scopeID: scope.id,
            outgoing: false,
            peer: "+86100",
            reference: 21,
            total: 2,
            anchorRawTimestamp: "26/07/15,10:00:00+32"
        )
        let fragment = record(
            id: "old-frag",
            body: "part one",
            locations: [SMSMessageLocation(storage: "SM", index: 1)],
            unread: true
        )
        let outcome = repair(logical: [fragment], segments: segments)
        XCTAssertEqual(outcome.quarantine.map(\.id), ["old-frag"])
        XCTAssertEqual(outcome.idRemap["old-frag"], canonicalID)
        XCTAssertEqual(outcome.logical.map(\.id), [canonicalID])
        XCTAssertTrue(outcome.logical[0].unread, "the fragment's unread state migrates through the remap")
        XCTAssertEqual(outcome.diagnostics.hiddenLegacyFragments, 1)
        XCTAssertEqual(outcome.diagnostics.visibleLogical, 1)
    }

    func testIncompleteGroupDefersRemapUntilCompletion() {
        let partial = [segmentRecord("part one", index: 1, reference: 21, total: 2, sequence: 1)]
        let fragment = record(
            id: "old-frag",
            body: "part one",
            locations: [SMSMessageLocation(storage: "SM", index: 1)],
            unread: true
        )
        let first = repair(logical: [fragment], segments: partial)
        XCTAssertEqual(first.quarantine.map(\.id), ["old-frag"], "hidden as soon as the concat metadata hits its slot")
        XCTAssertTrue(first.logical.isEmpty)
        XCTAssertNil(first.idRemap["old-frag"], "no canonical exists yet; the remap defers")
        XCTAssertEqual(first.diagnostics.pendingTransport, 1)

        let completed = repair(logical: [], quarantine: [fragment], segments: completeGroup)
        XCTAssertEqual(completed.logical.count, 1)
        XCTAssertEqual(completed.idRemap["old-frag"], completed.logical[0].id, "the deferred remap attaches on completion")
        XCTAssertTrue(completed.logical[0].unread)
    }

    func testIdentityDisagreementKeepsRecordVisible() {
        // A concat segment from another sender now occupies the fragment's
        // slot; location evidence exists but identity disagrees.
        let reused = [segmentRecord("x", index: 1, sender: "+86999", reference: 21, total: 2, sequence: 1)]
        let fragment = record(
            id: "old-frag",
            body: "old text",
            locations: [SMSMessageLocation(storage: "SM", index: 1)]
        )
        let outcome = repair(logical: [fragment], segments: reused)
        XCTAssertTrue(outcome.quarantine.isEmpty)
        XCTAssertEqual(outcome.logical.map(\.id), ["old-frag"])
        XCTAssertEqual(outcome.diagnostics.unresolvedLegacy, 1)
    }

    func testSupersededAssembledRecordQuarantinedByMembership() {
        let segments = completeGroup
        let canonicalID = SMSLogicalIdentity.concatenatedID(
            scopeID: scope.id,
            outgoing: false,
            peer: "+86100",
            reference: 21,
            total: 2,
            anchorRawTimestamp: "26/07/15,10:00:00+32"
        )
        // A v2-era record healed onto a v1 id but carrying real membership.
        let healed = record(
            id: "healed-v1-id",
            body: "part onepart two",
            locations: segments.map { SMSMessageLocation(storage: $0.storage, index: $0.index) },
            segmentIDs: segments.map(\.id),
            notifiedAt: now
        )
        let outcome = repair(logical: [healed], segments: segments)
        XCTAssertEqual(outcome.logical.map(\.id), [canonicalID], "the fresh canonical replaces the healed record")
        XCTAssertEqual(outcome.quarantine.map(\.id), ["healed-v1-id"])
        XCTAssertEqual(outcome.idRemap["healed-v1-id"], canonicalID)
        XCTAssertEqual(outcome.logical[0].notifiedAt, now)
    }

    func testAssembledCanonicalSurvivesMemberSlotReuseBySingle() {
        // The group's first member slot was reused by a plain single; the
        // old merged canonical must remain visible history.
        let single = segmentRecord("replacement", index: 1)
        let leftover = segmentRecord("part two", index: 2, date: "26/07/15,10:01:00+32", reference: 21, total: 2, sequence: 2)
        let oldCanonical = record(
            id: "old-canonical",
            body: "part onepart two",
            locations: [SMSMessageLocation(storage: "SM", index: 1), SMSMessageLocation(storage: "SM", index: 2)],
            segmentIDs: [single.id, leftover.id]
        )
        let outcome = repair(logical: [oldCanonical], segments: [single, leftover])
        XCTAssertEqual(outcome.logical.count, 2, "the old canonical and the new single both stay visible")
        XCTAssertTrue(outcome.logical.contains { $0.id == "old-canonical" })
        XCTAssertTrue(outcome.quarantine.isEmpty)
        XCTAssertEqual(outcome.diagnostics.pendingTransport, 1, "the leftover concat half is incomplete")
    }

    func testRepairIsIdempotentWithAFixedClock() {
        let segments = completeGroup
        let fragment = record(
            id: "old-frag",
            body: "part one",
            locations: [SMSMessageLocation(storage: "SM", index: 1)],
            unread: true
        )
        let first = repair(logical: [fragment], segments: segments)
        let second = repair(
            logical: first.logical,
            quarantine: first.quarantine,
            segments: segments,
            idRemap: first.idRemap
        )
        XCTAssertEqual(second.logical, first.logical)
        XCTAssertEqual(second.quarantine, first.quarantine)
        XCTAssertEqual(second.idRemap, first.idRemap)
        XCTAssertEqual(second.diagnostics, first.diagnostics)
    }

    func testConsumedBySegmentIDMarksAssembly() {
        let segments = completeGroup + [segmentRecord("lone", index: 3)]
        let outcome = repair(segments: segments)
        XCTAssertEqual(outcome.consumedBySegmentID.count, 3, "the single is its own canonical")
        XCTAssertEqual(outcome.diagnostics.pendingTransport, 0)
        XCTAssertEqual(outcome.logical.map(\.body).sorted(), ["lone", "part onepart two"])
    }
}
