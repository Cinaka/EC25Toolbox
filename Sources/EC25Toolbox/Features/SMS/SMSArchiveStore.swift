import CryptoKit
import Foundation

/// Identity boundary used to keep SMS history separated across eSTK profiles.
struct SIMMessageScope: Codable, Equatable {
    var id: String
    var eid: String?
    var iccid: String?

    init(eid: String?, iccid: String?) {
        let cleanEID = Self.normalizedIdentifier(eid)
        let cleanICCID = Self.normalizedIdentifier(iccid)
        self.eid = cleanEID
        self.iccid = cleanICCID
        let identity = [cleanEID ?? "NO-EID", cleanICCID ?? "NO-ICCID"].joined(separator: "|")
        id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var isIdentified: Bool { iccid != nil }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = trimmed(value).uppercased()
        guard !clean.isEmpty, clean != "-", clean != "UNKNOWN" else { return nil }
        return clean
    }
}

struct SMSBackupState: Equatable {
    var localArchivePath = ""
    var iCloudBackupPath: String?
    var currentScopeID: String?
    var lastBackupAt: Date?
    var lastRestoreAt: Date?
    var lastError: String?
}

// MARK: - Persistence schema

/// Schema v1 record, retained to read legacy archives and to keep writing
/// v1 data when the v3 cutover fails.
struct SMSArchiveRecordV1: Codable, Equatable {
    var id: String
    var scopeID: String
    var eid: String?
    var iccid: String?
    var storage: String
    var modemIndex: Int
    var status: String
    var outgoing: Bool
    var unread: Bool
    var peer: String
    var serviceDate: String
    var body: String
    var firstSeenAt: Date
    var updatedAt: Date
    var presentOnModem: Bool
    var deletedAt: Date?
    var binaryKind: String?
    var segmentIndexes: [Int]?

    var message: SMSMessage {
        SMSMessage(
            id: id, storage: storage, index: modemIndex, status: status,
            outgoing: outgoing, unread: unread, sender: peer, date: serviceDate, body: body,
            scopeID: scopeID, presentOnModem: presentOnModem,
            binaryKind: binaryKind.flatMap(BinarySMSKind.init(rawValue:)),
            segmentIndexes: segmentIndexes
        )
    }
}

private struct SMSArchiveDocumentV1: Codable, Equatable {
    var schemaVersion = 1
    var records: [SMSArchiveRecordV1] = []
}

/// Schema v2: logical messages plus the transport segments that produced
/// them. Read-only since R18; new stores write schema v3.
struct SMSArchiveDocumentV2: Codable, Equatable {
    var schemaVersion = 2
    var logical: [SMSLogicalRecord] = []
    var segments: [SMSTransportSegmentRecord] = []
}

extension SMSLogicalRecord {
    /// Converts one v1 record. The timestamp is parsed once against the
    /// migration time and persisted on the record; notified-at is pinned so
    /// historical messages never re-announce after the upgrade.
    init(v1: SMSArchiveRecordV1, migrationDate: Date) {
        let timestamp = SMSTimeParsing.parse(raw: v1.serviceDate, resolvedAt: migrationDate)
        let locations = v1.segmentIndexes.map { indexes in
            indexes.map { SMSMessageLocation(storage: v1.storage, index: $0) }
        } ?? [SMSMessageLocation(storage: v1.storage, index: v1.modemIndex)]
        self.init(
            id: v1.id,
            scopeID: v1.scopeID,
            eid: v1.eid,
            iccid: v1.iccid,
            origin: v1.storage,
            outgoing: v1.outgoing,
            unread: v1.unread,
            peer: v1.peer,
            body: v1.body,
            binaryKind: v1.binaryKind,
            rawServiceTimestamp: v1.serviceDate,
            instant: timestamp?.instant,
            sourceTimeZoneOffsetSeconds: timestamp?.sourceTimeZoneOffsetSeconds,
            centuryAnchor: timestamp.map { _ in migrationDate },
            concatReference: nil,
            concatTotal: nil,
            segmentIDs: [],
            locations: locations,
            presentOnModem: v1.presentOnModem,
            notifiedAt: migrationDate,
            firstSeenAt: v1.firstSeenAt,
            updatedAt: v1.updatedAt,
            deletedAt: v1.deletedAt
        )
    }

    /// Lossy v1 fallback serialization used only when the v3 cutover fails.
    var v1Record: SMSArchiveRecordV1 {
        SMSArchiveRecordV1(
            id: id,
            scopeID: scopeID,
            eid: eid,
            iccid: iccid,
            storage: origin,
            modemIndex: locations.first?.index ?? 0,
            status: unread ? "REC UNREAD" : "REC READ",
            outgoing: outgoing,
            unread: unread,
            peer: peer,
            serviceDate: rawServiceTimestamp ?? "",
            body: body,
            firstSeenAt: firstSeenAt,
            updatedAt: updatedAt,
            presentOnModem: presentOnModem,
            deletedAt: deletedAt,
            binaryKind: binaryKind,
            segmentIndexes: locations.count > 1 ? locations.map(\.index) : nil
        )
    }

    var message: SMSMessage {
        let primary = locations.first
        return SMSMessage(
            id: id,
            storage: primary?.storage ?? origin,
            index: primary?.index ?? 0,
            status: unread ? "REC UNREAD" : "REC READ",
            outgoing: outgoing,
            unread: unread,
            sender: peer,
            date: rawServiceTimestamp ?? "-",
            body: body,
            scopeID: scopeID,
            presentOnModem: presentOnModem,
            binaryKind: binaryKind.flatMap(BinarySMSKind.init(rawValue:)),
            segmentIndexes: locations.count > 1 ? locations.map(\.index) : nil,
            instant: instant,
            sourceTimeZoneOffsetSeconds: sourceTimeZoneOffsetSeconds,
            rawServiceTimestamp: rawServiceTimestamp,
            segmentLocations: locations,
            moduleIDs: moduleIDs ?? []
        )
    }
}

private struct SMSBackupManifest: Codable {
    var schemaVersion = 1
    var updatedAt: Date
    var latestFile = "latest.json"
    var snapshots: [String]
    var lastSnapshotAt: Date?
}

// MARK: - Store

/// Durable local SMS archive with an optional rolling iCloud Drive backup.
///
/// Schema v3 (R18) makes the transport layer authoritative: every load,
/// modem synchronize, and iCloud restore/merge first combines raw layers
/// (segments, local-only records, state) and then rebuilds the visible
/// logical projection through `SMSArchiveRepairer`. Legacy records are only
/// hidden on strong location/concat evidence and are retained verbatim in
/// quarantine. A store loaded from a v1/v2 archive migrates on its first
/// persist: the original file is backed up, the v3 file is written
/// atomically and verified by decoding it back, and only then does the
/// store switch; on any mismatch the v3 file is removed and the original
/// schema's file remains the on-disk truth.
@MainActor
final class SMSArchiveStore {
    private let fileManager: FileManager
    private let localDirectory: URL
    private let v1URL: URL
    private let v1BackupURL: URL
    private let v2URL: URL
    private let v2BackupURL: URL
    private let v3URL: URL
    private let iCloudBackupDirectory: URL?
    private var document: SMSArchiveDocumentV3
    private(set) var state: SMSBackupState
    private(set) var diagnostics: SMSArchiveRepairer.Diagnostics

    private enum ActiveSchema {
        /// v3 file decodes (or a fresh install); every persist writes v3.
        case v3Ready
        /// Loaded from v1; the next persist attempts the v3 cutover.
        case repairingV1
        /// Loaded from v2; the next persist attempts the v3 cutover.
        case repairingV2
        /// The v1→v3 cutover failed; keep serializing v1-shaped data.
        case v1Fallback
        /// The v2→v3 cutover failed; keep serializing v2-shaped data.
        case v2Fallback
    }

    private var schema: ActiveSchema

    /// Exposed for tests and diagnostics.
    var activeSchemaVersion: Int {
        switch schema {
        case .v3Ready: 3
        case .repairingV1, .v1Fallback: 1
        case .repairingV2, .v2Fallback: 2
        }
    }

    var logicalRecordCount: Int { document.logical.count }
    var quarantineRecordCount: Int { document.quarantine.count }
    var transportSegmentCount: Int { document.segments.count }
    var pendingSegmentCount: Int { document.segments.filter { $0.assembly == .pending }.count }
    var v3FileExists: Bool { fileManager.fileExists(atPath: v3URL.path) }
    var v2FileExists: Bool { fileManager.fileExists(atPath: v2URL.path) }
    var v1BackupExists: Bool { fileManager.fileExists(atPath: v1BackupURL.path) }
    var v2BackupExists: Bool { fileManager.fileExists(atPath: v2BackupURL.path) }
    var indexDiagnostics: SMSArchiveRepairer.Diagnostics { diagnostics }

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        iCloudDriveRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        let applicationSupport = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        localDirectory = AppIdentity.applicationSupportDirectory(
            base: applicationSupport,
            fileManager: fileManager
        )
            .appendingPathComponent("Messages", isDirectory: true)
        v1URL = localDirectory.appendingPathComponent("messages-v1.json")
        v1BackupURL = localDirectory.appendingPathComponent("messages-v1.backup.json")
        v2URL = localDirectory.appendingPathComponent("messages-v2.json")
        v2BackupURL = localDirectory.appendingPathComponent("messages-v2.backup.json")
        v3URL = localDirectory.appendingPathComponent("messages-v3.json")

        let cloudDocuments = iCloudDriveRoot ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fileManager.fileExists(atPath: cloudDocuments.path) {
            iCloudBackupDirectory = AppIdentity.iCloudContainerDirectory(
                base: cloudDocuments,
                fileManager: fileManager
            )
                .appendingPathComponent("Backups", isDirectory: true)
        } else {
            iCloudBackupDirectory = nil
        }

        let migrationDate = Date()
        if let data = try? Data(contentsOf: v3URL),
           let decoded = try? Self.decoder.decode(SMSArchiveDocumentV3.self, from: data),
           decoded.schemaVersion == 3 {
            document = decoded
            schema = .v3Ready
        } else if let data = try? Data(contentsOf: v2URL),
                  let decoded = try? Self.decoder.decode(SMSArchiveDocumentV2.self, from: data),
                  decoded.schemaVersion == 2 {
            // Repair at load so the wrong-logical-with-correct-transport v2
            // state is classified before anything is displayed or persisted.
            document = SMSArchiveDocumentV3(
                segments: decoded.segments,
                logical: decoded.logical
            ).repaired(now: migrationDate)
            schema = .repairingV2
        } else if let data = try? Data(contentsOf: v1URL),
                  let decoded = try? Self.decoder.decode(SMSArchiveDocumentV1.self, from: data),
                  decoded.schemaVersion == 1 {
            // Every decodable v1 record migrates; undecodable files keep
            // using v1 untouched (handled by the fallback persist path on
            // the next write attempt).
            document = SMSArchiveDocumentV3(
                logical: decoded.records.map { SMSLogicalRecord(v1: $0, migrationDate: migrationDate) }
            ).repaired(now: migrationDate)
            schema = .repairingV1
        } else {
            document = SMSArchiveDocumentV3()
            schema = .v3Ready
        }

        // Diagnostics reflect the projection as it would be right now;
        // the peek result is discarded so loading never mutates state.
        diagnostics = SMSArchiveRepairer.repair(
            logical: document.logical,
            quarantine: document.quarantine,
            segments: document.segments,
            idRemap: document.idRemap,
            now: migrationDate
        ).diagnostics

        var initialState = SMSBackupState(
            localArchivePath: v3URL.path,
            iCloudBackupPath: iCloudBackupDirectory?.path
        )
        if let directory = iCloudBackupDirectory,
           let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
           let manifest = try? Self.decoder.decode(SMSBackupManifest.self, from: data) {
            initialState.lastBackupAt = manifest.updatedAt
        }
        state = initialState
    }

    // MARK: - Sync

    /// Merges one modem listing into the archive and returns the visible
    /// logical messages for the scope.
    ///
    /// `presentStorages` lists the storages that actually answered this
    /// round; presence flags of other storages stay untouched so a failed
    /// query cannot masquerade as a mass deletion.
    func synchronize(
        liveSegments: [SMSSegment],
        presentStorages: Set<String>,
        legacySent: [SentMessage],
        scope: SIMMessageScope,
        moduleID: String? = nil
    ) throws -> [SMSMessage] {
        state.currentScopeID = scope.id
        let now = Date()
        var changed = false
        if iCloudBackupDirectory != nil {
            do {
                changed = try mergeLatestCloudBackup() || changed
                state.lastError = nil
            } catch {
                state.lastError = error.localizedDescription
            }
        }
        changed = migrateRecordsToKnownEID(scope) || changed

        // 1) Upsert live segments; timestamps parse exactly once per segment.
        var liveSegmentIDs = Set<String>()
        for entry in liveSegments {
            let id = SMSLogicalIdentity.segmentID(scopeID: scope.id, storage: entry.storage, index: entry.index)
            liveSegmentIDs.insert(id)
            changed = upsertSegment(makeSegmentRecord(
                entry,
                id: id,
                scope: scope,
                moduleID: moduleID,
                now: now
            )) || changed
        }

        // 2) Presence flags only for storages that reported this round.
        for position in document.segments.indices
        where document.segments[position].scopeID == scope.id
            && presentStorages.contains(document.segments[position].storage) {
            let present = liveSegmentIDs.contains(document.segments[position].id)
            if document.segments[position].presentOnModem != present {
                document.segments[position].presentOnModem = present
                document.segments[position].updatedAt = now
                changed = true
            }
        }

        // 3) Rebuild the visible projection from the authoritative transport
        //    layer; incomplete groups and superseded fragments stay hidden.
        changed = rebuildProjection(now: now) || changed

        // 4) Mirror read state and presence from live member segments.
        for position in document.logical.indices
        where document.logical[position].scopeID == scope.id
            && document.logical[position].deletedAt == nil {
            let id = document.logical[position].id
            let liveMembers = document.segments.filter { $0.consumedByLogicalID == id && $0.presentOnModem }
            if !liveMembers.isEmpty {
                let anyUnread = liveMembers.contains(where: \.unread)
                if document.logical[position].unread, !anyUnread {
                    document.logical[position].unread = false
                    document.logical[position].updatedAt = now
                    changed = true
                }
                if !document.logical[position].presentOnModem {
                    document.logical[position].presentOnModem = true
                    document.logical[position].updatedAt = now
                    changed = true
                }
            } else if document.logical[position].presentOnModem,
                document.logical[position].origin == "ME" || document.logical[position].origin == "SM",
                !document.logical[position].segmentIDs.isEmpty {
                document.logical[position].presentOnModem = false
                document.logical[position].updatedAt = now
                changed = true
            }
        }

        // 5) Adopt legacy sent-message log entries once.
        for sent in legacySent {
            let sentAt = Date(timeIntervalSince1970: TimeInterval(sent.ts) / 1_000)
            let record = SMSLogicalRecord(
                id: SMSLogicalIdentity.singleID(
                    scopeID: scope.id,
                    outgoing: true,
                    peer: sent.to,
                    rawServiceTimestamp: sent.date,
                    body: sent.body,
                    nonce: String(sent.ts)
                ),
                scopeID: scope.id,
                eid: scope.eid,
                iccid: scope.iccid,
                moduleIDs: moduleID.map { [$0] } ?? [],
                origin: "SENT",
                outgoing: true,
                unread: false,
                peer: sent.to,
                body: sent.body,
                binaryKind: nil,
                rawServiceTimestamp: sent.date,
                instant: sentAt,
                sourceTimeZoneOffsetSeconds: TimeZone.current.secondsFromGMT(for: sentAt),
                centuryAnchor: sentAt,
                concatReference: nil,
                concatTotal: nil,
                segmentIDs: [],
                locations: [],
                presentOnModem: false,
                notifiedAt: sentAt,
                firstSeenAt: sentAt,
                updatedAt: now,
                deletedAt: nil
            )
            changed = upsertLocalRecord(record) || changed
        }

        // A loaded-but-unmigrated v1/v2 archive persists even when this round
        // had no other change: the first persist performs the v3 cutover.
        if changed || schema == .repairingV1 || schema == .repairingV2 { try persistAndBackup() }
        return messages(in: scope.id)
    }

    func addSent(
        to number: String,
        body: String,
        sentAt: Date,
        scope: SIMMessageScope,
        moduleID: String? = nil
    ) throws {
        let raw = modemDateNow()
        let nonce = String(Int64(sentAt.timeIntervalSince1970 * 1_000))
        let record = SMSLogicalRecord(
            id: SMSLogicalIdentity.singleID(
                scopeID: scope.id, outgoing: true, peer: number,
                rawServiceTimestamp: raw, body: body, nonce: nonce
            ),
            scopeID: scope.id,
            eid: scope.eid,
            iccid: scope.iccid,
            moduleIDs: moduleID.map { [$0] } ?? [],
            origin: "SENT",
            outgoing: true,
            unread: false,
            peer: number,
            body: body,
            binaryKind: nil,
            rawServiceTimestamp: raw,
            instant: sentAt,
            sourceTimeZoneOffsetSeconds: TimeZone.current.secondsFromGMT(for: sentAt),
            centuryAnchor: sentAt,
            concatReference: nil,
            concatTotal: nil,
            segmentIDs: [],
            locations: [],
            presentOnModem: false,
            notifiedAt: sentAt,
            firstSeenAt: sentAt,
            updatedAt: Date(),
            deletedAt: nil
        )
        if upsertLocalRecord(record) { try persistAndBackup() }
    }

    func addReceived(
        from sender: String,
        body: String,
        receivedAt: Date,
        scope: SIMMessageScope,
        moduleID: String? = nil
    ) throws {
        let raw = modemDateNow()
        let nonce = String(Int64(receivedAt.timeIntervalSince1970 * 1_000))
        let record = SMSLogicalRecord(
            id: SMSLogicalIdentity.singleID(
                scopeID: scope.id, outgoing: false, peer: sender,
                rawServiceTimestamp: raw, body: body, nonce: nonce
            ),
            scopeID: scope.id,
            eid: scope.eid,
            iccid: scope.iccid,
            moduleIDs: moduleID.map { [$0] } ?? [],
            origin: "VOWIFI",
            outgoing: false,
            unread: true,
            peer: sender,
            body: body,
            binaryKind: nil,
            rawServiceTimestamp: raw,
            instant: receivedAt,
            sourceTimeZoneOffsetSeconds: TimeZone.current.secondsFromGMT(for: receivedAt),
            centuryAnchor: receivedAt,
            concatReference: nil,
            concatTotal: nil,
            segmentIDs: [],
            locations: [],
            presentOnModem: false,
            notifiedAt: nil,
            firstSeenAt: receivedAt,
            updatedAt: Date(),
            deletedAt: nil
        )
        if upsertLocalRecord(record) { try persistAndBackup() }
    }

    func delete(messageID: String) throws {
        guard let index = document.logical.firstIndex(where: { $0.id == messageID }),
              document.logical[index].deletedAt == nil else { return }
        let now = Date()
        document.logical[index].deletedAt = now
        document.logical[index].updatedAt = now
        try persistAndBackup()
    }

    func markRead(messageIDs: Set<String>) throws {
        var changed = false
        for index in document.logical.indices
            where document.logical[index].deletedAt == nil
                && messageIDs.contains(document.logical[index].id)
                && document.logical[index].unread {
            document.logical[index].unread = false
            document.logical[index].updatedAt = Date()
            changed = true
        }
        if changed { try persistAndBackup() }
    }

    /// IDs within `candidates` that are unread incoming messages which have
    /// never been announced. Used so restores and archive reloads never
    /// re-notify a message that already bannered once.
    func pendingNotificationIDs(within candidates: Set<String>) -> Set<String> {
        Set(
            document.logical
                .filter { candidates.contains($0.id) && $0.notifiedAt == nil && !$0.outgoing && $0.unread && $0.deletedAt == nil }
                .map(\.id)
        )
    }

    func markNotified(messageIDs: Set<String>) throws {
        var changed = false
        let now = Date()
        for index in document.logical.indices
            where document.logical[index].notifiedAt == nil
                && messageIDs.contains(document.logical[index].id) {
            document.logical[index].notifiedAt = now
            document.logical[index].updatedAt = now
            changed = true
        }
        if changed { try persistAndBackup() }
    }

    /// The only read API for the visible projection: UI, conversations,
    /// search, unread counts, and notification candidates all derive from
    /// these records.
    func displayableLogicalRecords(in scopeID: String) -> [SMSLogicalRecord] {
        document.logical.filter { $0.scopeID == scopeID && $0.deletedAt == nil }
    }

    func messages(in scopeID: String) -> [SMSMessage] {
        displayableLogicalRecords(in: scopeID)
            .map(\.message)
            .sorted { lhs, rhs in
                let left = lhs.instant ?? .distantPast
                let right = rhs.instant ?? .distantPast
                if left != right { return left > right }
                if lhs.date == rhs.date { return lhs.id > rhs.id }
                return lhs.date > rhs.date
            }
    }

    /// Recomputes the display projection and persists. Backing for the
    /// Settings "rebuild message index" entry; raw segments and quarantined
    /// records are never deleted, so the operation is always reversible.
    func rebuildProjectionAndPersist() throws {
        let changed = rebuildProjection(now: Date())
        if changed || schema == .repairingV1 || schema == .repairingV2 {
            try persistAndBackup()
        }
    }

    func backupNow() throws {
        if iCloudBackupDirectory == nil {
            try persistLocal()
            throw SMSArchiveError.iCloudDriveUnavailable
        }
        try backupToICloud(forceSnapshot: true)
    }

    func restoreLatestBackup() throws {
        guard let directory = iCloudBackupDirectory else { throw SMSArchiveError.iCloudDriveUnavailable }
        let data = try Data(contentsOf: directory.appendingPathComponent("latest.json"))
        guard let backup = Self.decodeBackup(data) else { throw SMSArchiveError.unsupportedBackup }

        let merged = merge(backup)
        let rebuilt = rebuildProjection(now: Date())
        if merged || rebuilt { try persistLocal() }
        state.lastRestoreAt = Date()
        state.lastError = nil
    }

    // MARK: - Projection rebuild

    @discardableResult
    private func rebuildProjection(now: Date) -> Bool {
        let outcome = SMSArchiveRepairer.repair(
            logical: document.logical,
            quarantine: document.quarantine,
            segments: document.segments,
            idRemap: document.idRemap,
            now: now
        )
        let logicalChanged = outcome.logical != document.logical
        let quarantineChanged = outcome.quarantine != document.quarantine
        let remapChanged = outcome.idRemap != document.idRemap
        document.logical = outcome.logical
        document.quarantine = outcome.quarantine
        document.idRemap = outcome.idRemap
        document.projectionVersion = SMSProjection.version
        diagnostics = outcome.diagnostics

        var assemblyChanged = false
        for position in document.segments.indices {
            let consumer = outcome.consumedBySegmentID[document.segments[position].id]
            let assembly: SMSTransportSegmentRecord.Assembly = consumer == nil ? .pending : .consumed
            if document.segments[position].assembly != assembly
                || document.segments[position].consumedByLogicalID != consumer {
                document.segments[position].assembly = assembly
                document.segments[position].consumedByLogicalID = consumer
                document.segments[position].updatedAt = now
                assemblyChanged = true
            }
        }
        return logicalChanged || quarantineChanged || remapChanged || assemblyChanged
    }

    // MARK: - Segment records

    private func makeSegmentRecord(
        _ entry: SMSSegment,
        id: String,
        scope: SIMMessageScope,
        moduleID: String?,
        now: Date
    ) -> SMSTransportSegmentRecord {
        var record = SMSTransportSegmentRecord(
            id: id,
            scopeID: scope.id,
            eid: scope.eid,
            iccid: scope.iccid,
            moduleIDs: moduleID.map { [$0] } ?? [],
            storage: entry.storage,
            index: entry.index,
            status: entry.status,
            outgoing: entry.outgoing,
            unread: entry.unread,
            peer: entry.sender,
            body: entry.body,
            binaryKind: entry.binaryKind?.rawValue,
            rawPDU: entry.rawPDU,
            reference: entry.concatenation.map { Int($0.reference) },
            total: entry.concatenation.map { Int($0.total) },
            sequence: entry.concatenation.map { Int($0.sequence) },
            rawServiceTimestamp: entry.date,
            instant: nil,
            sourceTimeZoneOffsetSeconds: nil,
            centuryAnchor: nil,
            assembly: .pending,
            consumedByLogicalID: nil,
            presentOnModem: true,
            firstSeenAt: now,
            updatedAt: now
        )
        if let existing = document.segments.first(where: { $0.id == id }),
           existing.sharesIdentity(with: record) {
            // Same message re-listed: keep the one-time time parse and the
            // assembly linkage from the earlier sighting.
            record.instant = existing.instant
            record.sourceTimeZoneOffsetSeconds = existing.sourceTimeZoneOffsetSeconds
            record.centuryAnchor = existing.centuryAnchor
            record.assembly = existing.assembly
            record.consumedByLogicalID = existing.consumedByLogicalID
            record.firstSeenAt = existing.firstSeenAt
            record.moduleIDs = Array(Set((existing.moduleIDs ?? []) + (record.moduleIDs ?? []))).sorted()
        } else if let timestamp = SMSTimeParsing.parse(raw: entry.date, resolvedAt: now) {
            record.instant = timestamp.instant
            record.sourceTimeZoneOffsetSeconds = timestamp.sourceTimeZoneOffsetSeconds
            record.centuryAnchor = now
        }
        return record
    }

    private func upsertSegment(_ replacement: SMSTransportSegmentRecord) -> Bool {
        guard let index = document.segments.firstIndex(where: { $0.id == replacement.id }) else {
            document.segments.append(replacement)
            return true
        }
        var updated = replacement
        updated.firstSeenAt = document.segments[index].firstSeenAt
        if updated == document.segments[index] { return false }
        updated.updatedAt = Date()
        document.segments[index] = updated
        return true
    }

    /// Upserts a local-only record (`SENT`/`VOWIFI`). These never take part
    /// in transport projection; identity comes from the send-time nonce.
    private func upsertLocalRecord(_ record: SMSLogicalRecord) -> Bool {
        guard let index = document.logical.firstIndex(where: { $0.id == record.id }) else {
            document.logical.append(record)
            return true
        }
        // Tombstones stay untouched; the modem copy is retried by cleanup.
        guard document.logical[index].deletedAt == nil else { return false }
        var updated = record
        updated.firstSeenAt = document.logical[index].firstSeenAt
        updated.notifiedAt = document.logical[index].notifiedAt
        updated.moduleIDs = Array(Set(
            (document.logical[index].moduleIDs ?? []) + (record.moduleIDs ?? [])
        )).sorted()
        if updated == document.logical[index] { return false }
        updated.updatedAt = Date()
        document.logical[index] = updated
        return true
    }

    private func migrateRecordsToKnownEID(_ scope: SIMMessageScope) -> Bool {
        guard let eid = scope.eid, let iccid = scope.iccid else { return false }
        var changed = false
        var idRemap: [String: String] = [:]

        for position in document.logical.indices
        where document.logical[position].eid == nil && document.logical[position].iccid == iccid {
            let oldID = document.logical[position].id
            document.logical[position].eid = eid
            document.logical[position].scopeID = scope.id
            // Only modem-listed records have content-derived IDs. SENT/VOWIFI
            // ids embed a time nonce that cannot be recomputed from content.
            if document.logical[position].origin == "ME" || document.logical[position].origin == "SM" {
                document.logical[position].id = recomputedID(for: document.logical[position], scope: scope)
            }
            document.logical[position].updatedAt = Date()
            idRemap[oldID] = document.logical[position].id
            changed = true
        }
        for position in document.quarantine.indices
        where document.quarantine[position].eid == nil && document.quarantine[position].iccid == iccid {
            let oldID = document.quarantine[position].id
            document.quarantine[position].eid = eid
            document.quarantine[position].scopeID = scope.id
            if document.quarantine[position].origin == "ME" || document.quarantine[position].origin == "SM" {
                document.quarantine[position].id = recomputedID(for: document.quarantine[position], scope: scope)
            }
            document.quarantine[position].updatedAt = Date()
            idRemap[oldID] = document.quarantine[position].id
            changed = true
        }
        if !idRemap.isEmpty {
            // Quarantined and legacy identities participate in the remap on
            // both sides so old→canonical links survive the scope change.
            var remapped: [String: String] = [:]
            for (old, canonical) in document.idRemap {
                remapped[idRemap[old] ?? old] = idRemap[canonical] ?? canonical
            }
            document.idRemap = remapped
        }
        for position in document.segments.indices
        where document.segments[position].eid == nil && document.segments[position].iccid == iccid {
            document.segments[position].eid = eid
            document.segments[position].scopeID = scope.id
            document.segments[position].id = SMSLogicalIdentity.segmentID(
                scopeID: scope.id,
                storage: document.segments[position].storage,
                index: document.segments[position].index
            )
            document.segments[position].updatedAt = Date()
            changed = true
        }
        if changed {
            var newestByID: [String: SMSLogicalRecord] = [:]
            for record in document.logical {
                if let existing = newestByID[record.id], existing.updatedAt >= record.updatedAt { continue }
                newestByID[record.id] = record
            }
            document.logical = Array(newestByID.values)

            var newestQuarantine: [String: SMSLogicalRecord] = [:]
            for record in document.quarantine {
                if let existing = newestQuarantine[record.id], existing.updatedAt >= record.updatedAt { continue }
                newestQuarantine[record.id] = record
            }
            document.quarantine = Array(newestQuarantine.values)

            var newestSegments: [String: SMSTransportSegmentRecord] = [:]
            for record in document.segments {
                if let existing = newestSegments[record.id], existing.updatedAt >= record.updatedAt { continue }
                newestSegments[record.id] = record
            }
            document.segments = Array(newestSegments.values)
        }
        return changed
    }

    private func recomputedID(for record: SMSLogicalRecord, scope: SIMMessageScope) -> String {
        if let reference = record.concatReference, let total = record.concatTotal {
            return SMSLogicalIdentity.concatenatedID(
                scopeID: scope.id,
                outgoing: record.outgoing,
                peer: record.peer,
                reference: reference,
                total: total,
                anchorRawTimestamp: record.rawServiceTimestamp ?? ""
            )
        }
        return SMSLogicalIdentity.singleID(
            scopeID: scope.id,
            outgoing: record.outgoing,
            peer: record.peer,
            rawServiceTimestamp: record.rawServiceTimestamp ?? "",
            body: record.body,
            nonce: ""
        )
    }

    // MARK: - Persistence

    private func persistAndBackup() throws {
        guard iCloudBackupDirectory != nil else {
            try persistLocal()
            state.lastError = nil
            return
        }
        do {
            try backupToICloud(forceSnapshot: false)
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    private func persistLocal() throws {
        try fileManager.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        switch schema {
        case .v3Ready:
            try Self.encoder.encode(document).write(to: v3URL, options: .atomic)
        case .repairingV1, .repairingV2:
            // Back up the original file, write v3 atomically, and switch only
            // when the file decodes back to the canonical roundtrip of the
            // same document. (`.iso8601` truncates sub-second precision, so
            // the reference is itself an encode+decode pass rather than the
            // live object.)
            let sourceURL = schema == .repairingV1 ? v1URL : v2URL
            let backupURL = schema == .repairingV1 ? v1BackupURL : v2BackupURL
            if !fileManager.fileExists(atPath: backupURL.path),
               fileManager.fileExists(atPath: sourceURL.path) {
                try? fileManager.copyItem(at: sourceURL, to: backupURL)
            }
            let payload = try Self.encoder.encode(document)
            try payload.write(to: v3URL, options: .atomic)
            let reference = try Self.decoder.decode(SMSArchiveDocumentV3.self, from: payload)
            if let data = try? Data(contentsOf: v3URL),
               let decoded = try? Self.decoder.decode(SMSArchiveDocumentV3.self, from: data),
               decoded == reference {
                schema = .v3Ready
            } else {
                // Cutover failed: remove the unverifiable v3 file, fall back
                // to the original schema's on-disk truth, and keep
                // serializing that shape so no data is stranded.
                try? fileManager.removeItem(at: v3URL)
                document = Self.reloadRawOriginal(
                    schema: schema,
                    v1URL: v1URL,
                    v2URL: v2URL,
                    fallbackDate: Date()
                )
                schema = schema == .repairingV1 ? .v1Fallback : .v2Fallback
                state.lastError = localized("sms.backup.error.migration_failed")
                try writeFallback()
                return
            }
        case .v1Fallback:
            try writeV1Fallback()
        case .v2Fallback:
            try writeV2Fallback()
        }
    }

    /// Reloads the pre-cutover file as the un-repaired truth after a failed
    /// v3 write; the next launch retries the migration from scratch.
    private static func reloadRawOriginal(
        schema: ActiveSchema,
        v1URL: URL,
        v2URL: URL,
        fallbackDate: Date
    ) -> SMSArchiveDocumentV3 {
        if schema == .repairingV1,
           let data = try? Data(contentsOf: v1URL),
           let v1 = try? decoder.decode(SMSArchiveDocumentV1.self, from: data),
           v1.schemaVersion == 1 {
            return SMSArchiveDocumentV3(
                logical: v1.records.map { SMSLogicalRecord(v1: $0, migrationDate: fallbackDate) }
            )
        }
        if schema == .repairingV2,
           let data = try? Data(contentsOf: v2URL),
           let v2 = try? decoder.decode(SMSArchiveDocumentV2.self, from: data),
           v2.schemaVersion == 2 {
            return SMSArchiveDocumentV3(segments: v2.segments, logical: v2.logical)
        }
        return SMSArchiveDocumentV3()
    }

    private func writeFallback() throws {
        switch schema {
        case .v1Fallback:
            try writeV1Fallback()
        case .v2Fallback:
            try writeV2Fallback()
        case .v3Ready, .repairingV1, .repairingV2:
            break
        }
    }

    private func writeV1Fallback() throws {
        let v1Document = SMSArchiveDocumentV1(records: document.logical.map(\.v1Record))
        try Self.encoder.encode(v1Document).write(to: v1URL, options: .atomic)
    }

    private func writeV2Fallback() throws {
        let v2Document = SMSArchiveDocumentV2(logical: document.logical, segments: document.segments)
        try Self.encoder.encode(v2Document).write(to: v2URL, options: .atomic)
    }

    private func backupToICloud(forceSnapshot: Bool) throws {
        guard let directory = iCloudBackupDirectory else { throw SMSArchiveError.iCloudDriveUnavailable }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let latestURL = directory.appendingPathComponent("latest.json")
        var coordinationError: NSError?
        var operationError: Error?
        var data = Data()
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: latestURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                if let cloudData = try? Data(contentsOf: coordinatedURL),
                   let cloudDocument = Self.decodeBackup(cloudData) {
                    _ = merge(cloudDocument)
                    _ = rebuildProjection(now: Date())
                }
                data = try Self.encoder.encode(document)
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        try persistLocal()

        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? Self.decoder.decode(SMSBackupManifest.self, from: $0) }
            ?? SMSBackupManifest(updatedAt: .distantPast, snapshots: [], lastSnapshotAt: nil)
        let needsSnapshot = forceSnapshot
            || manifest.lastSnapshotAt.map { Date().timeIntervalSince($0) >= 86_400 } != false
        if needsSnapshot {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "messages-\(formatter.string(from: Date())).json"
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            manifest.snapshots.append(name)
            manifest.lastSnapshotAt = Date()
            while manifest.snapshots.count > 30 {
                let removed = manifest.snapshots.removeFirst()
                try? fileManager.removeItem(at: directory.appendingPathComponent(removed))
            }
        }
        manifest.updatedAt = Date()
        try Self.encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        state.lastBackupAt = manifest.updatedAt
    }

    private func mergeLatestCloudBackup() throws -> Bool {
        guard let directory = iCloudBackupDirectory else { return false }
        let latestURL = directory.appendingPathComponent("latest.json")
        guard fileManager.fileExists(atPath: latestURL.path) else { return false }

        var coordinationError: NSError?
        var operationError: Error?
        var changed = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: latestURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let cloudData = try Data(contentsOf: coordinatedURL)
                guard let cloudDocument = Self.decodeBackup(cloudData) else {
                    throw SMSArchiveError.unsupportedBackup
                }
                changed = merge(cloudDocument)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        return changed
    }

    /// Cloud backups may be v1, v2, or v3; anything newer than v3 is
    /// unsupported. Older schemas are converted and repaired with the same
    /// evidence rules as a local load.
    private static func decodeBackup(_ data: Data) -> SMSArchiveDocumentV3? {
        if let v3 = try? decoder.decode(SMSArchiveDocumentV3.self, from: data), v3.schemaVersion == 3 {
            return v3
        }
        if let v2 = try? decoder.decode(SMSArchiveDocumentV2.self, from: data), v2.schemaVersion == 2 {
            return SMSArchiveDocumentV3(segments: v2.segments, logical: v2.logical)
                .repaired(now: Date())
        }
        if let v1 = try? decoder.decode(SMSArchiveDocumentV1.self, from: data), v1.schemaVersion == 1 {
            let date = Date()
            return SMSArchiveDocumentV3(
                logical: v1.records.map { SMSLogicalRecord(v1: $0, migrationDate: date) }
            ).repaired(now: date)
        }
        return nil
    }

    /// Raw-layer merge at the transport/local/state level. Remote logical
    /// records this device has already reclassified (quarantined or remapped)
    /// are routed back into quarantine so an old cloud backup can never
    /// resurrect hidden fragments into the visible layer.
    private func merge(_ incoming: SMSArchiveDocumentV3) -> Bool {
        var changed = false
        let quarantinedIDs = Set(document.quarantine.map(\.id))
        let remappedIDs = Set(document.idRemap.keys)
        let supersededIDs = quarantinedIDs.union(remappedIDs)

        for record in incoming.logical {
            if supersededIDs.contains(record.id) {
                if let index = document.quarantine.firstIndex(where: { $0.id == record.id }) {
                    if record.updatedAt > document.quarantine[index].updatedAt {
                        document.quarantine[index] = record
                        changed = true
                    }
                } else {
                    document.quarantine.append(record)
                    changed = true
                }
                continue
            }
            if let index = document.logical.firstIndex(where: { $0.id == record.id }) {
                let current = document.logical[index]
                // Deletions are monotone: a tombstone always wins an ID match
                // in both directions. Plain fields still use last-writer-wins,
                // but timestamps decoded from disk are second-truncated, so
                // they must never compete with a tombstone's intent.
                let incomingWins: Bool
                if current.deletedAt != nil {
                    incomingWins = false
                } else if record.deletedAt != nil {
                    incomingWins = true
                } else {
                    incomingWins = record.updatedAt > current.updatedAt
                }
                if incomingWins {
                    document.logical[index] = record
                    changed = true
                }
            } else {
                document.logical.append(record)
                changed = true
            }
        }
        for record in incoming.quarantine {
            if let index = document.quarantine.firstIndex(where: { $0.id == record.id }) {
                if record.updatedAt > document.quarantine[index].updatedAt {
                    document.quarantine[index] = record
                    changed = true
                }
            } else {
                document.quarantine.append(record)
                changed = true
            }
        }
        for record in incoming.segments {
            if let index = document.segments.firstIndex(where: { $0.id == record.id }) {
                let current = document.segments[index]
                let incomingWins = record.updatedAt > current.updatedAt
                if incomingWins {
                    document.segments[index] = record
                    changed = true
                }
            } else {
                document.segments.append(record)
                changed = true
            }
        }
        for (old, canonical) in incoming.idRemap where document.idRemap[old] == nil {
            document.idRemap[old] = canonical
            changed = true
        }
        return changed
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum SMSArchiveError: LocalizedError {
    case iCloudDriveUnavailable
    case unsupportedBackup
    case migrationFailed

    var errorDescription: String? {
        switch self {
        case .iCloudDriveUnavailable: localized("sms.backup.error.icloud_unavailable")
        case .unsupportedBackup: localized("sms.backup.error.unsupported")
        case .migrationFailed: localized("sms.backup.error.migration_failed")
        }
    }
}
