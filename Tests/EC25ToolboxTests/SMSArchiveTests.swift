import Foundation
import XCTest
@testable import EC25Toolbox

final class SMSArchiveTests: XCTestCase {
    private func segment(
        _ body: String,
        storage: String = "SM",
        index: Int,
        sender: String = "+86100",
        date: String = "26/07/15,10:00:00+32",
        unread: Bool = false,
        reference: UInt16? = nil,
        total: Int = 0,
        sequence: Int = 0
    ) -> SMSSegment {
        SMSSegment(
            storage: storage,
            index: index,
            status: unread ? "REC UNREAD" : "REC READ",
            outgoing: false,
            unread: unread,
            sender: sender,
            date: date,
            body: body,
            binaryKind: nil,
            concatenation: reference.map {
                SMSConcatenation(reference: $0, total: total, sequence: sequence)
            },
            rawPDU: nil
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor
    private func makeStore(_ root: URL) -> SMSArchiveStore {
        SMSArchiveStore(
            applicationSupportDirectory: root,
            iCloudDriveRoot: root.appendingPathComponent("no-cloud")
        )
    }

    private func messagesDirectory(of root: URL) -> URL {
        AppIdentity.applicationSupportDirectory(base: root)
            .appendingPathComponent("Messages", isDirectory: true)
    }

    func testRenameCopiesLegacyDataWithoutDeletingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("EC25 Manager", isDirectory: true)
        let legacyFile = legacy.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyFile)

        let migrated = AppIdentity.applicationSupportDirectory(base: root)
        XCTAssertEqual(migrated.lastPathComponent, "EC25 Toolbox")
        XCTAssertEqual(try Data(contentsOf: migrated.appendingPathComponent("settings.json")), Data("legacy".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertEqual(AppIdentity.bundleIdentifier, "ing.fuyaoskyrocket.ec25toolbox")
    }

    func testScopeSeparatesProfilesOnSameEID() {
        let first = SIMMessageScope(eid: "89049032000000000000000000000001", iccid: "8986000000000000001")
        let second = SIMMessageScope(eid: "89049032000000000000000000000001", iccid: "8986000000000000002")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.isIdentified)
    }

    @MainActor
    func testSameSIMKeepsOneHistoryWhenMovedBetweenModules() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-CARD-A", iccid: "ICCID-CARD-A")
        let archive = makeStore(root)
        let listed = [segment("follows the SIM", index: 1)]

        let onModuleA = try archive.synchronize(
            liveSegments: listed,
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope,
            moduleID: "module-a"
        )
        let onModuleB = try archive.synchronize(
            liveSegments: listed,
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope,
            moduleID: "module-b"
        )

        XCTAssertEqual(onModuleB.map(\.id), onModuleA.map(\.id))
        XCTAssertEqual(Set(onModuleB[0].moduleIDs), ["module-a", "module-b"])

        let reloaded = makeStore(root)
        XCTAssertEqual(Set(reloaded.messages(in: scope.id)[0].moduleIDs), ["module-a", "module-b"])
    }

    // MARK: - Two-layer sync

    @MainActor
    func testMissingSegmentStaysHiddenUntilComplete() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-1")
        let archive = makeStore(root)

        let partial = try archive.synchronize(
            liveSegments: [segment("A", index: 1, unread: true, reference: 5, total: 2, sequence: 1)],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertTrue(partial.isEmpty, "incomplete concat groups never surface")
        XCTAssertEqual(archive.pendingSegmentCount, 1)
        XCTAssertEqual(archive.messages(in: scope.id).filter(\.unread).count, 0, "pending segments never count as unread")

        let complete = try archive.synchronize(
            liveSegments: [
                segment("A", index: 1, unread: true, reference: 5, total: 2, sequence: 1),
                segment("B", index: 2, date: "26/07/15,10:01:00+32", reference: 5, total: 2, sequence: 2),
            ],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(complete.map(\.body), ["AB"])
        XCTAssertNotNil(complete[0].instant, "the SCTS parsed once into an absolute instant")
        XCTAssertEqual(complete[0].sourceTimeZoneOffsetSeconds, 8 * 3_600)
        XCTAssertEqual(complete[0].segmentLocations.count, 2)
        XCTAssertEqual(archive.pendingSegmentCount, 0)
    }

    @MainActor
    func testDuplicateRedeliveryAfterCompletionStaysHidden() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-1")
        let archive = makeStore(root)

        _ = try archive.synchronize(
            liveSegments: [
                segment("A", index: 1, reference: 5, total: 2, sequence: 1),
                segment("B", index: 2, date: "26/07/15,10:01:00+32", reference: 5, total: 2, sequence: 2),
            ],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        let afterRedelivery = try archive.synchronize(
            liveSegments: [
                segment("A", index: 1, reference: 5, total: 2, sequence: 1),
                segment("B", index: 2, date: "26/07/15,10:01:00+32", reference: 5, total: 2, sequence: 2),
                segment("A2", index: 3, date: "26/07/15,20:00:00+32", reference: 5, total: 2, sequence: 1),
            ],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(afterRedelivery.map(\.body), ["AB"], "the duplicate sequence never duplicates the message")
        XCTAssertEqual(archive.pendingSegmentCount, 1)
    }

    @MainActor
    func testReadStateMirrorsModemListing() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-1")
        let archive = makeStore(root)

        let unread = try archive.synchronize(
            liveSegments: [segment("hello", index: 4, unread: true)],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertTrue(unread[0].unread)

        let read = try archive.synchronize(
            liveSegments: [segment("hello", index: 4, unread: false)],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertFalse(read[0].unread, "reading on the modem clears the logical unread flag")
        XCTAssertEqual(read[0].id, unread[0].id, "identity survives the status change")
    }

    @MainActor
    func testSlotReuseKeepsHistoryAndAddsNewMessage() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-1")
        let archive = makeStore(root)

        _ = try archive.synchronize(
            liveSegments: [segment("old text", index: 1)],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        let afterReuse = try archive.synchronize(
            liveSegments: [segment("new text", index: 1, date: "26/07/16,10:00:00+32")],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(Set(afterReuse.map(\.body)), ["old text", "new text"])
        XCTAssertTrue(afterReuse.first { $0.body == "new text" }!.presentOnModem)
        XCTAssertFalse(afterReuse.first { $0.body == "old text" }!.presentOnModem, "the replaced message stops tracking the reused slot")
    }

    @MainActor
    func testFailedStorageQueryDoesNotMasqueradeAsDeletion() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-1")
        let archive = makeStore(root)

        _ = try archive.synchronize(
            liveSegments: [segment("on modem", storage: "ME", index: 2)],
            presentStorages: ["ME", "SM"],
            legacySent: [],
            scope: scope
        )
        // The next round only ME answers and its listing is empty: the message
        // legitimately leaves the modem, while SM presence stays untouched.
        let next = try archive.synchronize(
            liveSegments: [],
            presentStorages: ["ME"],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertFalse(next[0].presentOnModem)
    }

    @MainActor
    func testNotifyOnceAcrossSyncsAndRestores() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-1")
        let archive = makeStore(root)

        let messages = try archive.synchronize(
            liveSegments: [segment("fresh", index: 6, unread: true)],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        let candidates = Set(messages.map(\.id))
        XCTAssertEqual(archive.pendingNotificationIDs(within: candidates), candidates)

        try archive.markNotified(messageIDs: candidates)
        XCTAssertTrue(archive.pendingNotificationIDs(within: candidates).isEmpty)

        _ = try archive.synchronize(
            liveSegments: [segment("fresh", index: 6, unread: true)],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertTrue(archive.pendingNotificationIDs(within: candidates).isEmpty, "repeated syncs never re-announce")
    }

    @MainActor
    func testDeleteTombstoneSurvivesRelisting() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-1")
        let archive = makeStore(root)

        let messages = try archive.synchronize(
            liveSegments: [segment("doomed", index: 7)],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        try archive.delete(messageID: messages[0].id)
        let relisted = try archive.synchronize(
            liveSegments: [segment("doomed", index: 7)],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertTrue(relisted.isEmpty, "consumed segments of a tombstoned logical never resurrect it")
    }

    // MARK: - Sent / received injection

    @MainActor
    func testAddSentAndAddReceivedCreateLogicalMessages() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-1")
        let archive = makeStore(root)

        try archive.addSent(to: "+86100", body: "outgoing", sentAt: Date(timeIntervalSince1970: 1_800_000_100), scope: scope)
        try archive.addReceived(from: "+86200", body: "incoming", receivedAt: Date(timeIntervalSince1970: 1_800_000_200), scope: scope)

        let messages = archive.messages(in: scope.id)
        XCTAssertEqual(messages.map(\.body), ["incoming", "outgoing"], "sorted by instant, newest first")
        XCTAssertTrue(messages[0].unread)
        XCTAssertFalse(messages[0].presentOnModem)
        XCTAssertTrue(messages[0].segmentLocations.isEmpty, "locally injected messages have no modem slots")
    }

    // MARK: - iCloud partition + merge

    @MainActor
    func testArchivePartitionAndICloudMergeRestore() throws {
        let root = try makeRoot()
        let local = root.appendingPathComponent("local", isDirectory: true)
        let restoredLocal = root.appendingPathComponent("restored", isDirectory: true)
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)

        let firstScope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-1")
        let secondScope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-2")

        let archive = SMSArchiveStore(applicationSupportDirectory: local, iCloudDriveRoot: cloud)
        XCTAssertEqual(
            try archive.synchronize(
                liveSegments: [segment("first", index: 1, sender: "+86100")],
                presentStorages: ["SM"],
                legacySent: [],
                scope: firstScope
            ).count,
            1
        )
        XCTAssertEqual(
            try archive.synchronize(
                liveSegments: [segment("second", index: 1, sender: "+86200")],
                presentStorages: ["SM"],
                legacySent: [],
                scope: secondScope
            ).count,
            1
        )
        XCTAssertEqual(archive.messages(in: firstScope.id).map(\.body), ["first"])
        XCTAssertEqual(archive.messages(in: secondScope.id).map(\.body), ["second"])
        try archive.backupNow()

        let restored = SMSArchiveStore(applicationSupportDirectory: restoredLocal, iCloudDriveRoot: cloud)
        try restored.restoreLatestBackup()
        XCTAssertEqual(restored.messages(in: firstScope.id).map(\.body), ["first"])
        XCTAssertEqual(restored.messages(in: secondScope.id).map(\.body), ["second"])
    }

    @MainActor
    func testICloudMergePropagatesDeletionWithoutResurrection() throws {
        let root = try makeRoot()
        let firstLocal = root.appendingPathComponent("first", isDirectory: true)
        let secondLocal = root.appendingPathComponent("second", isDirectory: true)
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)

        let scope = SIMMessageScope(eid: "EID-SYNC", iccid: "ICCID-SYNC")
        let first = SMSArchiveStore(applicationSupportDirectory: firstLocal, iCloudDriveRoot: cloud)
        let second = SMSArchiveStore(applicationSupportDirectory: secondLocal, iCloudDriveRoot: cloud)

        let firstMessages = try first.synchronize(
            liveSegments: [segment("sync", index: 9, sender: "+86101")],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(firstMessages.count, 1)
        XCTAssertEqual(
            try second.synchronize(
                liveSegments: [segment("sync", index: 9, sender: "+86101")],
                presentStorages: ["SM"],
                legacySent: [],
                scope: scope
            ).count,
            1
        )

        try first.delete(messageID: firstMessages[0].id)
        XCTAssertTrue(
            try second.synchronize(liveSegments: [], presentStorages: ["SM"], legacySent: [], scope: scope).isEmpty
        )
        XCTAssertTrue(second.messages(in: scope.id).isEmpty)
    }

    // MARK: - v1 / v2 → v3 migration (R18)

    private struct V1RecordFixture {
        var id: String
        var body: String
        var modemIndex: Int
        var segmentIndexes: [Int]?
        var unread: Bool
        var deletedAt: String?

        init(
            id: String,
            body: String,
            modemIndex: Int,
            segmentIndexes: [Int]? = nil,
            unread: Bool = true,
            deletedAt: String? = nil
        ) {
            self.id = id
            self.body = body
            self.modemIndex = modemIndex
            self.segmentIndexes = segmentIndexes
            self.unread = unread
            self.deletedAt = deletedAt
        }
    }

    private func writeV1Archive(scope: SIMMessageScope, records: [V1RecordFixture], to directory: URL) throws {
        let messagesDirectory = messagesDirectory(of: directory)
        try FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        let list = records.map { fixture in
            let status = fixture.unread ? "REC UNREAD" : "REC READ"
            let indexes = fixture.segmentIndexes
                .map { "[\($0.map(String.init).joined(separator: ","))]" } ?? "null"
            return """
            {"id":"\(fixture.id)","scopeID":"\(scope.id)","eid":"\(scope.eid!)","iccid":"\(scope.iccid!)","storage":"SM","modemIndex":\(fixture.modemIndex),"status":"\(status)","outgoing":false,"unread":\(fixture.unread),"peer":"+86100","serviceDate":"26/07/15,10:00:00+32","body":"\(fixture.body)","firstSeenAt":"2026-07-15T10:00:00Z","updatedAt":"2026-07-15T10:00:00Z","presentOnModem":false,"deletedAt":\(fixture.deletedAt ?? "null"),"binaryKind":null,"segmentIndexes":\(indexes)}
            """
        }.joined(separator: ",")
        let json = "{\"schemaVersion\":1,\"records\":[\(list)]}"
        try Data(json.utf8).write(to: messagesDirectory.appendingPathComponent("messages-v1.json"))
    }

    private func writeV2Archive(logical: [SMSLogicalRecord], segments: [SMSTransportSegmentRecord], to directory: URL) throws {
        let messagesDirectory = messagesDirectory(of: directory)
        try FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(SMSArchiveDocumentV2(logical: logical, segments: segments))
        try payload.write(to: messagesDirectory.appendingPathComponent("messages-v2.json"))
    }

    @MainActor
    func testV1ArchiveMigratesToV3WithBackupAndPinnedNotifications() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-V1", iccid: "ICCID-V1")
        try writeV1Archive(
            scope: scope,
            records: [V1RecordFixture(id: "legacy-1", body: "legacy body", modemIndex: 3, unread: true)],
            to: root
        )

        let archive = makeStore(root)
        XCTAssertEqual(archive.activeSchemaVersion, 1, "loaded from v1; migration waits for the first persist")

        let messages = try archive.synchronize(
            liveSegments: [],
            presentStorages: [],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(archive.activeSchemaVersion, 3)
        XCTAssertTrue(archive.v3FileExists)
        XCTAssertTrue(archive.v1BackupExists)
        XCTAssertEqual(messages.map(\.body), ["legacy body"])
        XCTAssertEqual(messages[0].id, "legacy-1", "the stored v1 id survives the migration")
        XCTAssertNotNil(messages[0].instant)
        XCTAssertEqual(messages[0].sourceTimeZoneOffsetSeconds, 8 * 3_600)
        XCTAssertTrue(
            archive.pendingNotificationIDs(within: [messages[0].id]).isEmpty,
            "v1 history never re-announces after the upgrade"
        )
        XCTAssertEqual(archive.indexDiagnostics.unresolvedLegacy, 1, "no transport evidence: the legacy single stays visible")

        // A reload after migration reads v3 directly and stays on schema 3.
        let reloaded = makeStore(root)
        XCTAssertEqual(reloaded.activeSchemaVersion, 3)
        XCTAssertEqual(reloaded.messages(in: scope.id).map(\.id), ["legacy-1"])
    }

    @MainActor
    func testCorruptV3FileFallsBackToV1Truth() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-V1", iccid: "ICCID-V1")
        try writeV1Archive(
            scope: scope,
            records: [V1RecordFixture(id: "legacy-1", body: "v1 truth", modemIndex: 3, unread: true)],
            to: root
        )
        try Data("not json".utf8).write(to: messagesDirectory(of: root).appendingPathComponent("messages-v3.json"))

        let archive = makeStore(root)
        XCTAssertEqual(archive.activeSchemaVersion, 1)

        let messages = try archive.synchronize(
            liveSegments: [],
            presentStorages: [],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(archive.activeSchemaVersion, 3, "the corrupt v3 file is replaced and the archive recovers")
        XCTAssertEqual(messages.map(\.body), ["v1 truth"])
    }

    @MainActor
    func testV3WriteFailureKeepsV1FileIntact() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-V1", iccid: "ICCID-V1")
        try writeV1Archive(
            scope: scope,
            records: [V1RecordFixture(id: "legacy-1", body: "v1 truth", modemIndex: 3, unread: true)],
            to: root
        )
        // A directory occupying the v3 path makes the atomic write fail.
        try FileManager.default.createDirectory(
            at: messagesDirectory(of: root).appendingPathComponent("messages-v3.json"),
            withIntermediateDirectories: true
        )

        let archive = makeStore(root)
        XCTAssertThrowsError(
            try archive.synchronize(liveSegments: [], presentStorages: [], legacySent: [], scope: scope)
        )
        XCTAssertEqual(archive.activeSchemaVersion, 1, "the failed cutover leaves the schema untouched")
        let v1Data = try String(contentsOf: messagesDirectory(of: root).appendingPathComponent("messages-v1.json"), encoding: .utf8)
        XCTAssertTrue(v1Data.contains("v1 truth"), "the v1 file is never stranded or truncated")

        try FileManager.default.removeItem(at: messagesDirectory(of: root).appendingPathComponent("messages-v3.json"))
        XCTAssertNoThrow(try archive.synchronize(liveSegments: [], presentStorages: [], legacySent: [], scope: scope))
        XCTAssertEqual(archive.activeSchemaVersion, 3, "recovery succeeds once the obstruction is gone")
    }

    // MARK: - Legacy fragment repair (R18)

    @MainActor
    func testV1LegacyFragmentsHideOnceTransportReListsCompleteGroup() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-F", iccid: "ICCID-F")
        // The pre-assembler v1 archive stored each part of one long message
        // as its own record at SM:1 / SM:2.
        try writeV1Archive(
            scope: scope,
            records: [
                V1RecordFixture(id: "frag-1", body: "part one", modemIndex: 1, unread: true),
                V1RecordFixture(id: "frag-2", body: "part two", modemIndex: 2, unread: true),
            ],
            to: root
        )

        let archive = makeStore(root)
        let messages = try archive.synchronize(
            liveSegments: [
                segment("part one", index: 1, unread: true, reference: 7, total: 2, sequence: 1),
                segment("part two", index: 2, date: "26/07/15,10:01:00+32", unread: false, reference: 7, total: 2, sequence: 2),
            ],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(messages.count, 1, "the complete long message shows exactly once")
        XCTAssertEqual(messages[0].body, "part onepart two")
        XCTAssertEqual(messages[0].segmentLocations.count, 2, "deleting it covers every modem location")
        XCTAssertTrue(messages[0].unread, "the v1 unread state migrates onto the canonical")
        XCTAssertEqual(archive.quarantineRecordCount, 2, "both legacy fragments move to quarantine")
        XCTAssertEqual(archive.indexDiagnostics.hiddenLegacyFragments, 2)
        XCTAssertEqual(archive.indexDiagnostics.visibleLogical, 1)
        XCTAssertTrue(
            archive.pendingNotificationIDs(within: Set(messages.map(\.id))).isEmpty,
            "migration-pinned notifiedAt carries over: legacy history never re-announces"
        )
    }

    @MainActor
    func testV1MergedRecordSupersededByCompleteGroup() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-M", iccid: "ICCID-M")
        // v1 could also store the merged body in one record with both indexes.
        try writeV1Archive(
            scope: scope,
            records: [V1RecordFixture(id: "merged-1", body: "part onepart two", modemIndex: 1, segmentIndexes: [1, 2], unread: true)],
            to: root
        )

        let archive = makeStore(root)
        let messages = try archive.synchronize(
            liveSegments: [
                segment("part one", index: 1, unread: false, reference: 7, total: 2, sequence: 1),
                segment("part two", index: 2, date: "26/07/15,10:01:00+32", unread: false, reference: 7, total: 2, sequence: 2),
            ],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].body, "part onepart two")
        XCTAssertEqual(archive.quarantineRecordCount, 1, "the superseded merged record is quarantined, not deleted")
        XCTAssertEqual(archive.indexDiagnostics.unresolvedLegacy, 0)
    }

    @MainActor
    func testIncompleteLegacyFragmentHiddenUntilGroupCompletes() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-I", iccid: "ICCID-I")
        try writeV1Archive(
            scope: scope,
            records: [V1RecordFixture(id: "frag-1", body: "part one", modemIndex: 1, unread: true)],
            to: root
        )

        let archive = makeStore(root)
        let partial = try archive.synchronize(
            liveSegments: [segment("part one", index: 1, unread: false, reference: 11, total: 2, sequence: 1)],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertTrue(partial.isEmpty, "no complete group and the legacy fragment is already hidden")
        XCTAssertEqual(archive.quarantineRecordCount, 1)
        XCTAssertEqual(archive.pendingSegmentCount, 1)

        let complete = try archive.synchronize(
            liveSegments: [
                segment("part one", index: 1, unread: false, reference: 11, total: 2, sequence: 1),
                segment("part two", index: 2, date: "26/07/15,10:01:00+32", unread: false, reference: 11, total: 2, sequence: 2),
            ],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(complete.map(\.body), ["part onepart two"])
        XCTAssertFalse(
            complete[0].unread,
            "the live listing saying read clears the migrated unread flag; the pure attach behavior is covered by the repairer tests"
        )
        XCTAssertEqual(archive.quarantineRecordCount, 1)
    }

    @MainActor
    func testUnrelatedLegacySinglesStayVisible() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-U", iccid: "ICCID-U")
        try writeV1Archive(
            scope: scope,
            records: [
                V1RecordFixture(id: "single-a", body: "normal a", modemIndex: 5, unread: false),
                V1RecordFixture(id: "single-b", body: "normal b", modemIndex: 6, unread: false),
            ],
            to: root
        )

        let archive = makeStore(root)
        let messages = try archive.synchronize(
            liveSegments: [segment("unrelated", index: 9)],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(
            Set(messages.map(\.body)),
            ["normal a", "normal b", "unrelated"],
            "legacy singles without transport evidence stay visible"
        )
        XCTAssertEqual(archive.indexDiagnostics.unresolvedLegacy, 2)
        XCTAssertEqual(archive.quarantineRecordCount, 0)
    }

    @MainActor
    func testLegacyFragmentSurvivesSlotReuseByDifferentSender() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-G", iccid: "ICCID-G")
        try writeV1Archive(
            scope: scope,
            records: [V1RecordFixture(id: "frag-1", body: "old fragment", modemIndex: 1, unread: false)],
            to: root
        )

        let archive = makeStore(root)
        // The slot now holds a concat segment from a different sender: the
        // location matches but identity disagrees, so the legacy record must
        // stay visible instead of being hidden.
        let messages = try archive.synchronize(
            liveSegments: [segment("x", index: 1, sender: "+86999", reference: 13, total: 2, sequence: 1)],
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(messages.map(\.body), ["old fragment"])
        XCTAssertEqual(archive.quarantineRecordCount, 0)
        XCTAssertEqual(archive.indexDiagnostics.unresolvedLegacy, 1)
    }

    @MainActor
    func testRepeatedMigrationAndReloadStayIdempotent() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-R", iccid: "ICCID-R")
        try writeV1Archive(
            scope: scope,
            records: [V1RecordFixture(id: "frag-1", body: "part one", modemIndex: 1, unread: true)],
            to: root
        )

        let live = [
            segment("part one", index: 1, unread: false, reference: 15, total: 2, sequence: 1),
            segment("part two", index: 2, date: "26/07/15,10:01:00+32", unread: false, reference: 15, total: 2, sequence: 2),
        ]
        let archive = makeStore(root)
        _ = try archive.synchronize(liveSegments: live, presentStorages: ["SM"], legacySent: [], scope: scope)
        _ = try archive.synchronize(liveSegments: live, presentStorages: ["SM"], legacySent: [], scope: scope)
        XCTAssertEqual(archive.quarantineRecordCount, 1, "repeat syncs never grow the quarantine")
        XCTAssertEqual(archive.messages(in: scope.id).count, 1)

        let reloaded = makeStore(root)
        XCTAssertEqual(reloaded.activeSchemaVersion, 3)
        XCTAssertEqual(reloaded.quarantineRecordCount, 1)
        XCTAssertEqual(reloaded.messages(in: scope.id).count, 1)
        _ = try reloaded.synchronize(liveSegments: live, presentStorages: ["SM"], legacySent: [], scope: scope)
        XCTAssertEqual(reloaded.quarantineRecordCount, 1)
        XCTAssertEqual(reloaded.messages(in: scope.id).count, 1)
    }

    @MainActor
    func testV2WrongLogicalPlusTransportRepairOnLoad() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-V2", iccid: "ICCID-V2")
        // A v2 archive whose logical layer still contains the raw fragment
        // while the transport layer already holds the complete group.
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let fragment = SMSLogicalRecord(
            id: "old-frag",
            scopeID: scope.id,
            eid: scope.eid,
            iccid: scope.iccid,
            origin: "SM",
            outgoing: false,
            unread: false,
            peer: "+86100",
            body: "part one",
            binaryKind: nil,
            rawServiceTimestamp: "26/07/15,10:00:00+32",
            instant: timestamp,
            sourceTimeZoneOffsetSeconds: 8 * 3_600,
            centuryAnchor: timestamp,
            concatReference: nil,
            concatTotal: nil,
            segmentIDs: [],
            locations: [SMSMessageLocation(storage: "SM", index: 1)],
            presentOnModem: true,
            notifiedAt: timestamp,
            firstSeenAt: timestamp,
            updatedAt: timestamp,
            deletedAt: nil
        )
        let segments = [
            concatSegmentRecord("part one", scope: scope, index: 1, reference: 9, total: 2, sequence: 1, date: "26/07/15,10:00:00+32"),
            concatSegmentRecord("part two", scope: scope, index: 2, reference: 9, total: 2, sequence: 2, date: "26/07/15,10:01:00+32"),
        ]
        try writeV2Archive(logical: [fragment], segments: segments, to: root)

        let archive = makeStore(root)
        XCTAssertEqual(archive.activeSchemaVersion, 2, "loaded from v2; the v3 cutover waits for the first persist")
        let messages = archive.messages(in: scope.id)
        XCTAssertEqual(messages.count, 1, "repair runs at load, before any persist")
        XCTAssertEqual(messages[0].body, "part onepart two")
        XCTAssertEqual(archive.quarantineRecordCount, 1)
        XCTAssertTrue(
            archive.pendingNotificationIDs(within: Set(messages.map(\.id))).isEmpty,
            "the fragment's announced state carries onto the canonical"
        )

        _ = try archive.synchronize(liveSegments: [], presentStorages: ["SM"], legacySent: [], scope: scope)
        XCTAssertEqual(archive.activeSchemaVersion, 3)
        XCTAssertTrue(archive.v3FileExists)
        XCTAssertTrue(archive.v2BackupExists)
        XCTAssertEqual(archive.messages(in: scope.id).map(\.body), ["part onepart two"])
    }

    @MainActor
    func testCloudV1BackupMergeDoesNotResurrectQuarantinedFragments() throws {
        let root = try makeRoot()
        let local = root.appendingPathComponent("local", isDirectory: true)
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let scope = SIMMessageScope(eid: "EID-C", iccid: "ICCID-C")
        // An old v1 cloud backup still lists the fragment as a plain record.
        let backupDirectory = AppIdentity.iCloudContainerDirectory(base: cloud)
            .appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try writeV1Archive(
            scope: scope,
            records: [V1RecordFixture(id: "frag-1", body: "part one", modemIndex: 1, unread: true)],
            to: cloud
        )
        try FileManager.default.moveItem(
            at: messagesDirectory(of: cloud).appendingPathComponent("messages-v1.json"),
            to: backupDirectory.appendingPathComponent("latest.json")
        )
        let staleV1Payload = try Data(contentsOf: backupDirectory.appendingPathComponent("latest.json"))

        let archive = SMSArchiveStore(applicationSupportDirectory: local, iCloudDriveRoot: cloud)
        let live = [
            segment("part one", index: 1, unread: false, reference: 19, total: 2, sequence: 1),
            segment("part two", index: 2, date: "26/07/15,10:01:00+32", unread: false, reference: 19, total: 2, sequence: 2),
        ]
        let messages = try archive.synchronize(
            liveSegments: live,
            presentStorages: ["SM"],
            legacySent: [],
            scope: scope
        )
        XCTAssertEqual(messages.map(\.body), ["part onepart two"], "the first merge classifies the cloud fragment away")

        // Force the same old v1 backup to merge again; the fragment must
        // never come back as a visible message.
        try staleV1Payload.write(to: backupDirectory.appendingPathComponent("latest.json"))
        _ = try archive.synchronize(liveSegments: live, presentStorages: ["SM"], legacySent: [], scope: scope)
        XCTAssertEqual(archive.messages(in: scope.id).map(\.body), ["part onepart two"])
        XCTAssertEqual(archive.quarantineRecordCount, 1)
        XCTAssertEqual(archive.indexDiagnostics.unresolvedLegacy, 0)
    }

    @MainActor
    func testCompleteConcatGroupDisplaysAndNotifiesOnce() throws {
        let root = try makeRoot()
        let scope = SIMMessageScope(eid: "EID-N", iccid: "ICCID-N")
        let archive = makeStore(root)
        let live = [
            segment("a", index: 1, unread: true, reference: 17, total: 2, sequence: 1),
            segment("b", index: 2, date: "26/07/15,10:01:00+32", unread: true, reference: 17, total: 2, sequence: 2),
        ]
        let messages = try archive.synchronize(liveSegments: live, presentStorages: ["SM"], legacySent: [], scope: scope)
        XCTAssertEqual(messages.map(\.body), ["ab"])
        let candidates = Set(messages.map(\.id))
        XCTAssertEqual(archive.pendingNotificationIDs(within: candidates), candidates)

        try archive.markNotified(messageIDs: candidates)
        // Re-syncs and an explicit rebuild never re-announce the group.
        _ = try archive.synchronize(liveSegments: live, presentStorages: ["SM"], legacySent: [], scope: scope)
        try archive.rebuildProjectionAndPersist()
        _ = try archive.synchronize(liveSegments: live, presentStorages: ["SM"], legacySent: [], scope: scope)
        XCTAssertEqual(archive.messages(in: scope.id).count, 1)
        XCTAssertTrue(archive.pendingNotificationIDs(within: candidates).isEmpty)
    }

    // MARK: - Fixtures

    private func concatSegmentRecord(
        _ body: String,
        scope: SIMMessageScope,
        index: Int,
        reference: Int,
        total: Int,
        sequence: Int,
        date: String
    ) -> SMSTransportSegmentRecord {
        let id = SMSLogicalIdentity.segmentID(scopeID: scope.id, storage: "SM", index: index)
        let timestamp = SMSTimeParsing.parse(raw: date, resolvedAt: Date(timeIntervalSince1970: 1_800_000_000))
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
            peer: "+86100",
            body: body,
            binaryKind: nil,
            rawPDU: nil,
            reference: reference,
            total: total,
            sequence: sequence,
            rawServiceTimestamp: date,
            instant: timestamp?.instant,
            sourceTimeZoneOffsetSeconds: timestamp?.sourceTimeZoneOffsetSeconds,
            centuryAnchor: Date(timeIntervalSince1970: 1_800_000_000),
            assembly: .pending,
            consumedByLogicalID: nil,
            presentOnModem: true,
            firstSeenAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
