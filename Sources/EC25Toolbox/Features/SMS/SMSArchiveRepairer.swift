import Foundation

/// Version of the logical projection algorithm. Bumped whenever
/// `SMSArchiveRepairer` changes how visible logical records derive from the
/// transport layer; documents carrying an older version rebuild on their
/// next synchronize.
enum SMSProjection {
    static let version = 1
}

/// Schema v3 (R18): the transport layer is authoritative and the visible
/// `logical` array is a rebuildable projection of it. `quarantine` retains
/// legacy records reclassified by strong evidence verbatim — never shown,
/// never deleted — and `idRemap` carries old→canonical identity so
/// read/notified/deleted state survives projection rebuilds.
struct SMSArchiveDocumentV3: Codable, Equatable {
    var schemaVersion = 3
    var projectionVersion = SMSProjection.version
    var segments: [SMSTransportSegmentRecord] = []
    var logical: [SMSLogicalRecord] = []
    var quarantine: [SMSLogicalRecord] = []
    var idRemap: [String: String] = [:]
}

extension SMSArchiveDocumentV3 {
    /// Runs the repairer over this document's raw layers, keeping segments
    /// untouched (they are the authoritative input, not a projection).
    func repaired(now: Date) -> SMSArchiveDocumentV3 {
        let outcome = SMSArchiveRepairer.repair(
            logical: logical,
            quarantine: quarantine,
            segments: segments,
            idRemap: idRemap,
            now: now
        )
        return SMSArchiveDocumentV3(
            schemaVersion: 3,
            projectionVersion: SMSProjection.version,
            segments: segments,
            logical: outcome.logical,
            quarantine: outcome.quarantine,
            idRemap: outcome.idRemap
        )
    }
}

/// Rebuilds the visible projection of an SMS archive from its authoritative
/// transport layer (R18). Pure and deterministic: identical inputs and the
/// same `now` always produce identical output, so repeat runs, crash
/// restarts, and multi-device merges converge without compounding effects.
///
/// Classification of every stored logical record:
/// - local-only (`SENT`/`VOWIFI`) — kept verbatim, never mixed with modem
///   transport;
/// - reproduced canonical — the current projection assembles the same ID;
///   the canonical replaces it and inherits its state;
/// - transport fragment / superseded logical — hidden only on strong
///   evidence: a scope/storage/index location hitting a transport segment
///   that carries concat reference/total/sequence, or hitting a member
///   location/segment ID of a complete *concatenated* canonical, in both
///   cases with agreeing direction and peer. Body similarity is never
///   evidence. Superseded records move to `quarantine` and their state
///   migrates through `idRemap`;
/// - unresolved legacy — no strong evidence; stays visible.
enum SMSArchiveRepairer {
    struct Diagnostics: Codable, Equatable, Sendable {
        var visibleLogical = 0
        var pendingTransport = 0
        var hiddenLegacyFragments = 0
        var unresolvedLegacy = 0
        var projectionVersion = SMSProjection.version
    }

    struct Outcome: Equatable {
        var logical: [SMSLogicalRecord]
        var quarantine: [SMSLogicalRecord]
        var idRemap: [String: String]
        /// Segment ID → canonical logical that consumed it. Segments absent
        /// from this map belong to still-incomplete groups (pending).
        var consumedBySegmentID: [String: String]
        var diagnostics: Diagnostics
    }

    struct Evidence: Equatable {
        /// Strong evidence exists; the record leaves the visible layer.
        var quarantine = false
        /// The complete canonical that supersedes the record, when the
        /// owning group has already assembled.
        var ownerID: String?
    }

    private struct LocationKey: Hashable {
        let scopeID: String
        let storage: String
        let index: Int
    }

    static func repair(
        logical: [SMSLogicalRecord],
        quarantine: [SMSLogicalRecord],
        segments: [SMSTransportSegmentRecord],
        idRemap: [String: String],
        now: Date
    ) -> Outcome {
        // Canonical projection, assembled from every retained segment of
        // every scope so the result never depends on prior assembly state.
        var canonicalOrder: [String] = []
        var canonicalsByID: [String: SMSLogicalRecord] = [:]
        var consumedBySegmentID: [String: String] = [:]
        var segmentByID: [String: SMSTransportSegmentRecord] = [:]
        for segment in segments {
            segmentByID[segment.id] = segment
        }
        let scopes = Dictionary(grouping: segments, by: \.scopeID)
        for (_, scopeSegments) in scopes.sorted(by: { $0.key < $1.key }) {
            let scope = SIMMessageScope(eid: scopeSegments.first?.eid, iccid: scopeSegments.first?.iccid)
            let outcome = SMSLogicalAssembler.assemble(segments: scopeSegments, scope: scope, now: now)
            for record in outcome.logicals {
                if canonicalsByID[record.id] == nil { canonicalOrder.append(record.id) }
                canonicalsByID[record.id] = record
                for segmentID in record.segmentIDs {
                    consumedBySegmentID[segmentID] = record.id
                }
            }
        }
        // The assembler prototypes claim presence; the projection derives it
        // from the members actually listed so rebuilds never resurrect a
        // presence flag the mirror already cleared.
        for id in canonicalOrder {
            if let canonical = canonicalsByID[id] {
                canonicalsByID[id]?.presentOnModem = canonical.segmentIDs.contains {
                    segmentByID[$0]?.presentOnModem == true
                }
            }
        }

        // Evidence maps. Concat segments and members of complete concat
        // canonicals only: a replaced single must survive slot reuse as
        // visible history, so single canonicals never count as evidence.
        var concatSegmentByLocation: [LocationKey: SMSTransportSegmentRecord] = [:]
        for segment in segments
        where segment.reference != nil && segment.total != nil && segment.sequence != nil {
            concatSegmentByLocation[
                LocationKey(scopeID: segment.scopeID, storage: segment.storage, index: segment.index)
            ] = segment
        }
        var concatOwnerByLocation: [LocationKey: String] = [:]
        var concatOwnerBySegmentID: [String: String] = [:]
        for id in canonicalOrder {
            guard let canonical = canonicalsByID[id], canonical.concatTotal != nil else { continue }
            for segmentID in canonical.segmentIDs {
                concatOwnerBySegmentID[segmentID] = id
                if let segment = segmentByID[segmentID] {
                    concatOwnerByLocation[
                        LocationKey(scopeID: segment.scopeID, storage: segment.storage, index: segment.index)
                    ] = id
                }
            }
        }

        func evidence(for record: SMSLogicalRecord) -> Evidence {
            // Assembled-era records (non-empty segmentIDs) are only ever
            // superseded by a *complete* canonical claiming their members;
            // an incomplete group at the same location must not hide a
            // merged message whose member slot was reused. Legacy fragment
            // records (empty segmentIDs) may also be hidden on raw concat
            // metadata so they disappear while the group is still filling.
            let allowIncompleteGroupEvidence = record.segmentIDs.isEmpty
            var owners = Set<String>()
            var hit = false
            for segmentID in record.segmentIDs {
                if let owner = concatOwnerBySegmentID[segmentID] {
                    hit = true
                    owners.insert(owner)
                }
            }
            for location in record.locations {
                let key = LocationKey(scopeID: record.scopeID, storage: location.storage, index: location.index)
                if let owner = concatOwnerByLocation[key] {
                    hit = true
                    owners.insert(owner)
                } else if allowIncompleteGroupEvidence,
                    let segment = concatSegmentByLocation[key],
                    segment.outgoing == record.outgoing,
                    segment.peer == record.peer {
                    hit = true
                }
            }
            guard hit else { return Evidence() }
            // Identity guard: the superseding canonical must agree on
            // direction and peer; otherwise the slot was reused by an
            // unrelated message and the record stays visible.
            let agreeing = owners.filter { owner in
                guard let canonical = canonicalsByID[owner] else { return false }
                return canonical.outgoing == record.outgoing && canonical.peer == record.peer
            }
            if agreeing.count == 1 {
                return Evidence(quarantine: true, ownerID: agreeing.first)
            }
            if owners.isEmpty {
                // Concat metadata present but the group is not complete yet;
                // hide now, attach the state when the group completes.
                return Evidence(quarantine: true, ownerID: nil)
            }
            // Ambiguous or identity-disagreeing owners: prefer visible.
            return Evidence()
        }

        // Restores one-way user state onto a freshly assembled canonical.
        func restoreState(of old: SMSLogicalRecord, into canonicalID: String) {
            guard var canonical = canonicalsByID[canonicalID] else { return }
            canonical.firstSeenAt = min(canonical.firstSeenAt, old.firstSeenAt)
            canonical.unread = canonical.unread || old.unread
            if canonical.notifiedAt == nil { canonical.notifiedAt = old.notifiedAt }
            canonical.deletedAt = old.deletedAt ?? canonical.deletedAt
            canonical.presentOnModem = canonical.presentOnModem || old.presentOnModem
            canonical.moduleIDs = Array(Set(
                (canonical.moduleIDs ?? []) + (old.moduleIDs ?? [])
            )).sorted()
            canonicalsByID[canonicalID] = canonical
        }

        var kept: [SMSLogicalRecord] = []
        var newQuarantine: [SMSLogicalRecord] = []
        var quarantinedIDs = Set<String>()
        var newRemap = idRemap

        for record in logical {
            if record.origin == "SENT" || record.origin == "VOWIFI" {
                kept.append(record)
                continue
            }
            if canonicalsByID[record.id] != nil {
                restoreState(of: record, into: record.id)
                continue
            }
            let verdict = evidence(for: record)
            if verdict.quarantine {
                quarantinedIDs.insert(record.id)
                newQuarantine.append(record)
                if let owner = verdict.ownerID {
                    newRemap[record.id] = owner
                    restoreState(of: record, into: owner)
                }
                continue
            }
            var unresolved = record
            unresolved.isUnresolvedLegacy = true
            kept.append(unresolved)
        }

        for record in quarantine {
            if quarantinedIDs.insert(record.id).inserted {
                newQuarantine.append(record)
            }
            // A stale remap whose canonical no longer assembles is retried
            // so the state attaches as soon as the group completes again.
            var owner = newRemap[record.id].flatMap { canonicalsByID[$0] != nil ? $0 : nil }
            if owner == nil {
                owner = evidence(for: record).ownerID
                if let owner { newRemap[record.id] = owner }
            }
            if let owner {
                restoreState(of: record, into: owner)
            }
        }

        var logicalOutput: [SMSLogicalRecord] = []
        for id in canonicalOrder {
            if let canonical = canonicalsByID[id] {
                logicalOutput.append(canonical)
            }
        }
        logicalOutput.append(contentsOf: kept)

        let diagnostics = Diagnostics(
            visibleLogical: logicalOutput.count { $0.deletedAt == nil },
            pendingTransport: segments.count - consumedBySegmentID.count,
            hiddenLegacyFragments: newQuarantine.count,
            unresolvedLegacy: logicalOutput.count { $0.isUnresolvedLegacy == true && $0.deletedAt == nil },
            projectionVersion: SMSProjection.version
        )
        return Outcome(
            logical: logicalOutput,
            quarantine: newQuarantine,
            idRemap: newRemap,
            consumedBySegmentID: consumedBySegmentID,
            diagnostics: diagnostics
        )
    }
}
