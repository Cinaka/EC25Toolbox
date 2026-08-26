import Foundation

/// One redacted entry of the incoming-call event timeline (R8). The timeline
/// is the collection aid for real-device call regressions: every RING, CLIP,
/// `AT+CLCC` snapshot (index/direction/status codes only), user action, ATA
/// result, notification post/retract, and phase change of the tracked epoch.
///
/// Safe by construction: entries never contain phone numbers, caller names,
/// or any other subscriber data.
struct CallTimelineEntry: Equatable, Codable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case ring
        case clip
        case clccSnapshot
        case clccAnomaly
        case userAnswer
        case userReject
        case userHangUp
        case ataAccepted
        case ataFailed
        case hangUpAccepted
        case hangUpFailed
        case notifyPosted
        case notifyReplaced
        case notifyRetracted
        case phaseChanged
        case callConcluded
        case externalAdopted
        case transportLost
    }

    var id: Int
    var at: Date
    var kind: Kind
    var epoch: Int
    var phase: String
    /// Machine-readable detail such as `idx=1 dir=1 stat=0` or a retract
    /// reason; never subscriber data.
    var detail: String?

    var formatted: String {
        let base = "\(kind.rawValue)|epoch=\(epoch)|phase=\(phase)"
        return detail.map { "\(base)|\($0)" } ?? base
    }
}

/// Bounded, newest-last buffer of redacted call events for diagnostics.
struct CallTimeline: Equatable, Sendable {
    private(set) var entries: [CallTimelineEntry] = []
    private var nextID = 1
    var limit = 60

    mutating func append(
        _ kind: CallTimelineEntry.Kind,
        at date: Date,
        epoch: Int,
        phase: CallPhase,
        detail: String? = nil
    ) {
        entries.append(
            CallTimelineEntry(
                id: nextID,
                at: date,
                kind: kind,
                epoch: epoch,
                phase: phase.rawValue,
                detail: detail
            )
        )
        nextID += 1
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    /// True when an entry of this kind exists (test synchronization aid).
    func contains(_ kind: CallTimelineEntry.Kind) -> Bool {
        entries.contains { $0.kind == kind }
    }
}
