import CryptoKit
import Foundation

/// Storage-plus-index position of one transport segment on the modem.
struct SMSMessageLocation: Codable, Equatable, Hashable, Sendable {
    var storage: String
    var index: Int
}

/// Internal transport-level segment: one modem listing entry with its raw
/// PDU metadata and concatenation identity. Segments are never shown in the
/// UI; they exist to assemble logical messages and to retain raw data for
/// diagnostics and complete cleanup.
struct SMSTransportSegmentRecord: Codable, Equatable {
    enum Assembly: String, Codable {
        /// Part of an incomplete (or not yet assembled) group.
        case pending
        /// Absorbed into a logical message.
        case consumed
    }

    /// `scopeID|storage|index` — stable across refreshes, replaced wholesale
    /// when the modem reuses the slot for different content.
    var id: String
    var scopeID: String
    var eid: String?
    var iccid: String?
    /// Modules on which this SIM-owned storage segment was observed.
    var moduleIDs: [String]? = nil
    var storage: String
    var index: Int
    var status: String
    var outgoing: Bool
    var unread: Bool
    var peer: String
    /// Segment body; merged text only ever lives on the logical record.
    var body: String
    var binaryKind: String?
    /// Raw PDU hex in PDU mode; nil for text-mode listings.
    var rawPDU: String?
    var reference: Int?
    var total: Int?
    var sequence: Int?
    // Time model: parsed once, persisted, never re-derived on later loads.
    var rawServiceTimestamp: String?
    var instant: Date?
    var sourceTimeZoneOffsetSeconds: Int?
    var centuryAnchor: Date?
    var assembly: Assembly
    /// Set once the segment becomes part of a logical message.
    var consumedByLogicalID: String?
    var presentOnModem: Bool
    var firstSeenAt: Date
    var updatedAt: Date

    /// Fields that identify the underlying message; a change here means the
    /// modem reused this slot for a different message.
    func sharesIdentity(with other: SMSTransportSegmentRecord) -> Bool {
        outgoing == other.outgoing && peer == other.peer
            && rawServiceTimestamp == other.rawServiceTimestamp
            && body == other.body && binaryKind == other.binaryKind
            && reference == other.reference && total == other.total
            && sequence == other.sequence
    }
}

/// Logical message: the only data source for the UI, conversations, search,
/// unread counts, and notifications. Identity never depends on the merged
/// body, so a late segment completing a group cannot change its ID.
struct SMSLogicalRecord: Codable, Equatable {
    var id: String
    var scopeID: String
    var eid: String?
    var iccid: String?
    /// Module provenance is an index, never an identity boundary. The same
    /// SIM therefore keeps one record when moved between modules.
    var moduleIDs: [String]? = nil
    /// `"ME"`, `"SM"`, `"SENT"`, or `"VOWIFI"` — drives delete semantics.
    var origin: String
    var outgoing: Bool
    var unread: Bool
    var peer: String
    var body: String
    var binaryKind: String?
    var rawServiceTimestamp: String?
    var instant: Date?
    var sourceTimeZoneOffsetSeconds: Int?
    var centuryAnchor: Date?
    /// Concatenation identity retained so scope migration can re-derive IDs.
    var concatReference: Int?
    var concatTotal: Int?
    var segmentIDs: [String] = []
    /// Every modem position that must be deleted to remove this message.
    var locations: [SMSMessageLocation] = []
    var presentOnModem = false
    /// Set when a notification has been posted for this record; prevents
    /// re-announcing after restores or archive reloads.
    var notifiedAt: Date?
    var firstSeenAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Set by `SMSArchiveRepairer` on legacy records it could not attribute
    /// to any complete transport message; they stay visible rather than
    /// being hidden on weak evidence.
    var isUnresolvedLegacy: Bool? = nil
}

/// Stable logical identity. Concatenated messages key on scope, direction,
/// peer, reference, total, and the anchor (sequence-1) service timestamp —
/// never on the merged body. Singles keep the v1 content formula so
/// migration and fresh IDs agree.
enum SMSLogicalIdentity {
    static func concatenatedID(
        scopeID: String,
        outgoing: Bool,
        peer: String,
        reference: Int,
        total: Int,
        anchorRawTimestamp: String
    ) -> String {
        digest([
            scopeID,
            outgoing ? "out" : "in",
            peer,
            "concat",
            String(reference),
            String(total),
            anchorRawTimestamp,
        ])
    }

    /// Byte-compatible with the v1 `stableID` formula so upgraded archives
    /// and fresh listings agree on single-message identity.
    static func singleID(
        scopeID: String,
        outgoing: Bool,
        peer: String,
        rawServiceTimestamp: String,
        body: String,
        nonce: String = ""
    ) -> String {
        digest([
            scopeID,
            outgoing ? "out" : "in",
            peer,
            rawServiceTimestamp,
            body,
            nonce,
        ])
    }

    static func segmentID(scopeID: String, storage: String, index: Int) -> String {
        digest([scopeID, storage, String(index), "segment"])
    }

    private static func digest(_ parts: [String]) -> String {
        let identity = parts.joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Assembles pending transport segments into logical messages. Incomplete
/// concatenation groups and duplicate-sequence groups produce no logical
/// message at all — their segments stay pending and hidden. Clustering is
/// deterministic, so identical input yields identical IDs; a cluster that
/// reaches completeness freezes its membership and later duplicate-sequence
/// segments (reference wraparound or redelivery) open a new cluster.
enum SMSLogicalAssembler {
    struct Outcome: Equatable {
        /// Newly completed logical records (prototypes for archive upsert).
        var logicals: [SMSLogicalRecord]
        var consumedSegmentIDs: Set<String>
        var pendingSegmentIDs: Set<String>
    }

    static func assemble(segments: [SMSTransportSegmentRecord], scope: SIMMessageScope, now: Date) -> Outcome {
        var logicals: [SMSLogicalRecord] = []
        var singles: [SMSTransportSegmentRecord] = []
        var groups: [GroupKey: [SMSTransportSegmentRecord]] = [:]

        for segment in segments {
            guard let reference = segment.reference,
                  let total = segment.total,
                  segment.sequence != nil,
                  segment.binaryKind == nil,
                  total >= 2 else {
                singles.append(segment)
                continue
            }
            let key = GroupKey(segment: segment, reference: reference, total: total)
            groups[key, default: []].append(segment)
        }

        var consumed: Set<String> = []
        for (key, members) in groups {
            for cluster in cluster(members: members) {
                if let record = complete(cluster: cluster, key: key, scope: scope, now: now) {
                    logicals.append(record)
                    consumed.formUnion(cluster.map(\.id))
                }
            }
        }

        for single in singles {
            logicals.append(singleRecord(single, scope: scope, now: now))
            consumed.insert(single.id)
        }

        let consumedIDs = Set(segments.map(\.id)).intersection(consumed)
        // A single is always logically complete, so "pending" here means
        // concat segments whose group has not reached its total yet.
        let pendingIDs = Set(segments.map(\.id)).subtracting(consumedIDs)
        return Outcome(
            logicals: logicals.sorted { ($0.instant ?? .distantPast) > ($1.instant ?? .distantPast) },
            consumedSegmentIDs: consumedIDs,
            pendingSegmentIDs: pendingIDs
        )
    }

    private struct GroupKey: Hashable {
        var storage: String
        var peer: String
        var outgoing: Bool
        var reference: Int
        var total: Int

        init(segment: SMSTransportSegmentRecord, reference: Int, total: Int) {
            storage = segment.storage
            peer = segment.peer
            outgoing = segment.outgoing
            self.reference = reference
            self.total = total
        }
    }

    /// Splits one group's segments into clusters. Segments join the newest
    /// compatible cluster: same or earlier time window and a sequence number
    /// not already claimed by that cluster. Complete clusters accept nothing.
    private static func cluster(members: [SMSTransportSegmentRecord]) -> [[SMSTransportSegmentRecord]] {
        let ordered = members.sorted { lhs, rhs in
            let left = lhs.instant ?? lhs.firstSeenAt
            let right = rhs.instant ?? rhs.firstSeenAt
            if left != right { return left < right }
            return lhs.index < rhs.index
        }
        var clusters: [[SMSTransportSegmentRecord]] = []
        for segment in ordered {
            var placed = false
            for position in stride(from: clusters.count - 1, through: 0, by: -1) {
                let cluster = clusters[position]
                let claimed = Set(cluster.compactMap(\.sequence))
                guard let sequence = segment.sequence, !claimed.contains(sequence) else { continue }
                if isComplete(cluster, total: segment.total ?? 0) { continue }
                guard let anchor = cluster.first, withinWindow(anchor, segment) else { continue }
                clusters[position].append(segment)
                placed = true
                break
            }
            if !placed {
                clusters.append([segment])
            }
        }
        return clusters
    }

    private static func isComplete(_ cluster: [SMSTransportSegmentRecord], total: Int) -> Bool {
        guard total >= 2 else { return false }
        let claimed = Set(cluster.compactMap(\.sequence))
        return claimed.count == total && claimed == Set(1...total)
    }

    private static func withinWindow(_ anchor: SMSTransportSegmentRecord, _ candidate: SMSTransportSegmentRecord) -> Bool {
        let left = anchor.instant ?? anchor.firstSeenAt
        let right = candidate.instant ?? candidate.firstSeenAt
        return abs(right.timeIntervalSince(left)) <= SMSTimeParsing.clusteringWindow
    }

    private static func complete(
        cluster: [SMSTransportSegmentRecord],
        key: GroupKey,
        scope: SIMMessageScope,
        now: Date
    ) -> SMSLogicalRecord? {
        let total = key.total
        guard isComplete(cluster, total: total) else { return nil }

        var bySequence: [Int: SMSTransportSegmentRecord] = [:]
        for segment in cluster {
            guard let sequence = segment.sequence else { return nil }
            bySequence[sequence] = segment
        }
        let ordered = (1...total).compactMap { bySequence[$0] }
        guard ordered.count == total, let first = ordered.first else { return nil }

        let anchorRaw = first.rawServiceTimestamp ?? ""
        let instant = ordered.compactMap(\.instant).max()
        let anchor = ordered.compactMap(\.centuryAnchor).min() ?? now
        return SMSLogicalRecord(
            id: SMSLogicalIdentity.concatenatedID(
                scopeID: scope.id,
                outgoing: first.outgoing,
                peer: first.peer,
                reference: key.reference,
                total: total,
                anchorRawTimestamp: anchorRaw
            ),
            scopeID: scope.id,
            eid: scope.eid,
            iccid: scope.iccid,
            moduleIDs: Array(Set(ordered.flatMap { $0.moduleIDs ?? [] })).sorted(),
            origin: first.storage,
            outgoing: first.outgoing,
            unread: ordered.contains(where: \.unread),
            peer: first.peer,
            body: ordered.map(\.body).joined(),
            binaryKind: nil,
            rawServiceTimestamp: anchorRaw,
            instant: instant,
            sourceTimeZoneOffsetSeconds: ordered.compactMap(\.sourceTimeZoneOffsetSeconds).first,
            centuryAnchor: anchor,
            concatReference: key.reference,
            concatTotal: total,
            segmentIDs: ordered.map(\.id),
            locations: ordered.map { SMSMessageLocation(storage: $0.storage, index: $0.index) },
            presentOnModem: true,
            notifiedAt: nil,
            firstSeenAt: ordered.compactMap(\.firstSeenAt).min() ?? now,
            updatedAt: now,
            deletedAt: nil
        )
    }

    private static func singleRecord(
        _ segment: SMSTransportSegmentRecord,
        scope: SIMMessageScope,
        now: Date
    ) -> SMSLogicalRecord {
        let raw = segment.rawServiceTimestamp ?? ""
        return SMSLogicalRecord(
            id: SMSLogicalIdentity.singleID(
                scopeID: scope.id,
                outgoing: segment.outgoing,
                peer: segment.peer,
                rawServiceTimestamp: raw,
                body: segment.body
            ),
            scopeID: scope.id,
            eid: scope.eid,
            iccid: scope.iccid,
            moduleIDs: segment.moduleIDs,
            origin: segment.storage,
            outgoing: segment.outgoing,
            unread: segment.unread,
            peer: segment.peer,
            body: segment.body,
            binaryKind: segment.binaryKind,
            rawServiceTimestamp: raw,
            instant: segment.instant,
            sourceTimeZoneOffsetSeconds: segment.sourceTimeZoneOffsetSeconds,
            centuryAnchor: segment.centuryAnchor,
            concatReference: nil,
            concatTotal: nil,
            segmentIDs: [segment.id],
            locations: [SMSMessageLocation(storage: segment.storage, index: segment.index)],
            presentOnModem: true,
            notifiedAt: nil,
            firstSeenAt: segment.firstSeenAt,
            updatedAt: now,
            deletedAt: nil
        )
    }
}
