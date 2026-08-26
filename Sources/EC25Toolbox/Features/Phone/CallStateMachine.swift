import Foundation

/// One `AT+CLCC` call-list entry.
///
/// Format: `+CLCC: <index>,<dir>,<stat>,<mode>,<mpty>[,<number>,<type>[,<alpha>]]`
struct CLCCEntry: Equatable, Sendable {
    enum Direction: Int, Equatable, Sendable {
        case outgoing = 0
        case incoming = 1
    }

    enum Status: Int, Equatable, Sendable {
        case active = 0
        case held = 1
        case dialing = 2
        case alerting = 3
        case incoming = 4
        case waiting = 5
    }

    var index: Int
    var direction: Direction
    var status: Status
    var number: String?

    /// Parses `+CLCC` lines from one `AT+CLCC` response, skipping other text.
    static func parse(_ lines: [String]) -> [CLCCEntry] {
        lines.compactMap(parseLine)
    }

    static func parseLine(_ line: String) -> CLCCEntry? {
        guard line.hasPrefix("+CLCC:") else { return nil }
        let fields = csvParts(String(line.dropFirst("+CLCC:".count)))
        guard fields.count >= 5,
              let index = Int(fields[0]),
              let directionRaw = Int(fields[1]),
              let statusRaw = Int(fields[2]),
              let direction = Direction(rawValue: directionRaw),
              let status = Status(rawValue: statusRaw) else {
            return nil
        }
        let number = fields.count > 5 ? trimQuotes(fields[5]) : nil
        return CLCCEntry(
            index: index,
            direction: direction,
            status: status,
            number: (number?.isEmpty == true) ? nil : number
        )
    }
}

extension CLCCEntry.Direction {
    /// Maps the machine's call direction onto the `AT+CLCC` encoding.
    init(_ direction: CallDirection) {
        self = direction == .outgoing ? .outgoing : .incoming
    }
}

/// Explicit user intent to answer the tracked incoming call (R8).
/// `AT+CLCC active` alone can never promote a tracked incoming call; only
/// the full chain — user request, accepted `ATA`, matching `CLCC active` —
/// may enter `.active`.
enum CallAnswerIntent: Equatable, Sendable {
    case none
    case requested
    case ataAccepted
}

/// Inputs accepted by the voice-call state machine: modem events (URCs and
/// `AT+CLCC` snapshots) plus user intents.
enum CallInput: Equatable, Sendable {
    case ring
    case clip(number: String?)
    case clcc([CLCCEntry])
    /// An `AT+CLCC` response that listed no calls.
    case clccEmpty
    case noCarrier
    case busy
    case noAnswer
    case dialFailure(String)
    case userDialed(number: String)
    /// The user explicitly tapped answer (in-app surface, menu, or
    /// notification action). Captured before `ATA` is sent so a later
    /// `CLCC active` can be attributed to a real user answer (R8).
    case userAnswerRequested
    /// `ATA` returned OK: the modem accepted the answer command. This only
    /// confirms command reception — `active` requires `AT+CLCC` evidence.
    case ataAccepted
    /// `ATA` failed; the remote party may still be ringing.
    case ataFailed
    /// The user asked to end/reject the call; the command is in flight.
    case hangUpRequested
    /// The hang-up/reject command completed successfully.
    case hangUpAccepted
    /// The hang-up/reject command failed; the call may still be live.
    case hangUpFailed
    case transportLost
    case tick

    /// Maps one unsolicited call-related AT line to an input, or `nil` when
    /// the line carries no call meaning.
    static func forURCLine(_ line: String) -> CallInput? {
        switch line {
        case "NO CARRIER": return .noCarrier
        case "BUSY": return .busy
        case "NO ANSWER": return .noAnswer
        default: break
        }
        let entries = CLCCEntry.parse([line])
        return entries.isEmpty ? nil : .clcc(entries)
    }
}

/// Why a call concluded.
enum CallEndReason: Equatable, Sendable {
    case localHangUp
    case remoteHangUp
    case rejected
    case missed
    case busy
    case noAnswer
    case noCarrier
    case dialTimeout
    case answerTimeout
    case dialFailed(String)
    case transportLost
}

/// A concluded call, ready to be written into the call log.
struct CallOutcome: Equatable, Sendable {
    var number: String?
    var direction: CallDirection?
    var reason: CallEndReason
    /// Set only when the call had actually connected.
    var startedAt: Date?
}

/// One state-machine step reported to the owner.
struct CallTransition: Equatable, Sendable {
    var from: CallPhase
    var to: CallPhase
    /// Set when a call concluded and a log entry should be recorded.
    var outcome: CallOutcome?
    /// The modem may still be setting the call up; the owner should send `ATH`.
    var adviseHangUp: Bool
}

/// Deterministic single-call state machine driven by modem events and user
/// intents. Pure value type: all timestamps come in through inputs so every
/// transition, including timeouts, is testable without waiting.
struct CallStateMachine: Equatable, Sendable {
    struct Config: Equatable, Sendable {
        /// `dialing` → `alerting`/`active` budget.
        var dialTimeout: TimeInterval = 45
        /// `alerting` → `active` budget.
        var alertingTimeout: TimeInterval = 75
        /// Silence between rings after which an incoming call counts as missed.
        var ringSilenceTimeout: TimeInterval = 30
        /// `answering` → `active` budget before the answer is treated as failed.
        var answerTimeout: TimeInterval = 20
        /// `ending` → terminal budget before the pending hang-up concludes.
        var endTimeout: TimeInterval = 10
        /// How long terminal phases stay visible before returning to idle.
        var terminalLinger: TimeInterval = 6
    }

    private(set) var phase: CallPhase = .idle
    private(set) var number: String?
    private(set) var direction: CallDirection?
    private(set) var phaseEnteredAt: Date?
    private(set) var callStartedAt: Date?
    private(set) var lastRingAt: Date?
    private(set) var lastOutcome: CallOutcome?
    /// Why the call should conclude once the pending hang-up resolves.
    private(set) var pendingEndReason: CallEndReason?
    /// Phase to resume if the pending hang-up command fails.
    private(set) var phaseBeforeEnding: CallPhase?
    /// Monotonic identity of the tracked call. Async command results and
    /// notification actions bind to it so a stale result from one call can
    /// never steer another (R8). Zero is the idle sentinel; every `begin`
    /// assigns a fresh epoch.
    private(set) var callEpoch: Int = 0
    /// Explicit user answer intent for the current epoch (R8). `CLCC active`
    /// promotes a tracked incoming call only once this is `.ataAccepted`.
    private(set) var answerIntent: CallAnswerIntent = .none
    /// How many `AT+CLCC` snapshots reported the tracked incoming call as
    /// active although the user never answered it (R8 anomaly, e.g. module
    /// auto-answer `ATS0`). Redacted diagnostics material.
    private(set) var clccActiveAnomalies = 0
    /// True when the call was adopted from a CLCC snapshot as externally
    /// connected instead of being tracked from RING/CLIP (R8 adopt path).
    private(set) var adoptedExternalCall = false
    private var nextEpoch = 1
    var config = Config()

    /// Any phase that needs the maintenance loop (timeouts or the terminal
    /// linger countdown), including terminal phases themselves.
    var isTrackingCall: Bool { phase != .idle }

    /// A call exists that the modem still tracks (not terminal, not idle).
    var hasLiveCall: Bool {
        switch phase {
        case .idle, .ended, .failed, .missed: false
        case .incoming, .answering, .dialing, .alerting, .active, .held, .ending: true
        }
    }

    var status: CallStatus {
        CallStatus(
            phase: phase,
            number: number,
            direction: direction,
            phaseChangedAt: phaseEnteredAt,
            startedAt: callStartedAt,
            epoch: callEpoch,
            clccActiveAnomalies: clccActiveAnomalies,
            isExternalAdoption: adoptedExternalCall
        )
    }

    /// Applies one input at `now` and returns the transition, or `nil` when
    /// the input does not move the machine.
    mutating func handle(_ input: CallInput, now: Date) -> CallTransition? {
        switch input {
        case .tick:
            return advance(now: now)
        case .ring:
            lastRingAt = now
            if !hasLiveCall {
                // A bare RING carries no caller number; +CLIP supplies it next.
                return begin(.incoming, number: nil, direction: .incoming, now: now)
            }
            return nil
        case let .clip(caller):
            if !hasLiveCall {
                return begin(.incoming, number: caller, direction: .incoming, now: now)
            }
            if phase == .incoming, number == nil, let caller, !caller.isEmpty {
                number = caller
            }
            return nil
        case let .clcc(entries):
            return apply(entries: entries, now: now)
        case .clccEmpty:
            return apply(entries: [], now: now)
        case .noCarrier:
            switch phase {
            case .incoming:
                return conclude(.missed, now: now, adviseHangUp: false)
            case .answering:
                // The remote party vanished while the answer was connecting.
                return conclude(.missed, now: now, adviseHangUp: false)
            case .ending:
                return concludePendingEnd(now: now)
            case .dialing, .alerting:
                return conclude(.noCarrier, now: now, adviseHangUp: false)
            case .active, .held:
                return conclude(.remoteHangUp, now: now, adviseHangUp: false)
            case .idle, .ended, .failed, .missed:
                return nil
            }
        case .busy:
            switch phase {
            case .dialing, .alerting: return conclude(.busy, now: now, adviseHangUp: false)
            default: return nil
            }
        case .noAnswer:
            switch phase {
            case .dialing, .alerting: return conclude(.noAnswer, now: now, adviseHangUp: false)
            default: return nil
            }
        case let .dialFailure(detail):
            switch phase {
            case .dialing, .alerting: return conclude(.dialFailed(detail), now: now, adviseHangUp: false)
            default: return nil
            }
        case let .userDialed(dialed):
            guard !hasLiveCall else { return nil }
            return begin(.dialing, number: dialed, direction: .outgoing, now: now)
        case .userAnswerRequested:
            // The explicit user answer intent: enter `.answering` immediately
            // so the surface shows pending feedback while `ATA` is in flight
            // (R8). Without this request, `CLCC active` can never follow.
            guard phase == .incoming, answerIntent == .none else { return nil }
            answerIntent = .requested
            return enter(.answering, now: now)
        case .ataAccepted:
            // Only an answer the user requested may be confirmed. The call
            // stays in `.answering` until a matching `CLCC active` arrives.
            guard phase == .answering, answerIntent == .requested else { return nil }
            answerIntent = .ataAccepted
            return nil
        case .ataFailed:
            // The caller may still be ringing; return to incoming so the user
            // can retry. Intent resets so an un-answered `CLCC active` stays
            // gated (R8).
            guard phase == .answering else { return nil }
            answerIntent = .none
            return enter(.incoming, now: now)
        case .hangUpRequested:
            switch phase {
            case .incoming:
                pendingEndReason = .rejected
                phaseBeforeEnding = .incoming
                return enter(.ending, now: now)
            case .answering, .dialing, .alerting, .active, .held:
                pendingEndReason = .localHangUp
                phaseBeforeEnding = phase
                return enter(.ending, now: now)
            case .idle, .ended, .failed, .missed, .ending:
                return nil
            }
        case .hangUpAccepted:
            guard phase == .ending, let reason = pendingEndReason else { return nil }
            return conclude(reason, now: now, adviseHangUp: false)
        case .hangUpFailed:
            // The call may still be live; resume the phase the user tried to
            // end so they can retry. The next CLCC snapshot reconciles.
            guard phase == .ending, let resume = phaseBeforeEnding else { return nil }
            pendingEndReason = nil
            phaseBeforeEnding = nil
            return enter(resume, now: now)
        case .transportLost:
            guard hasLiveCall else { return nil }
            return conclude(.transportLost, now: now, adviseHangUp: false)
        }
    }

    /// Evaluates phase timeouts and the terminal linger countdown.
    private mutating func advance(now: Date) -> CallTransition? {
        switch phase {
        case .idle:
            return nil
        case .incoming:
            let reference = lastRingAt ?? phaseEnteredAt ?? now
            guard now.timeIntervalSince(reference) > config.ringSilenceTimeout else { return nil }
            return conclude(.missed, now: now, adviseHangUp: false)
        case .answering:
            guard now.timeIntervalSince(phaseEnteredAt ?? now) > config.answerTimeout else { return nil }
            return conclude(.answerTimeout, now: now, adviseHangUp: true)
        case .dialing:
            guard now.timeIntervalSince(phaseEnteredAt ?? now) > config.dialTimeout else { return nil }
            return conclude(.dialTimeout, now: now, adviseHangUp: true)
        case .alerting:
            guard now.timeIntervalSince(phaseEnteredAt ?? now) > config.alertingTimeout else { return nil }
            return conclude(.noAnswer, now: now, adviseHangUp: true)
        case .ending:
            guard now.timeIntervalSince(phaseEnteredAt ?? now) > config.endTimeout else { return nil }
            return concludePendingEnd(now: now, adviseHangUp: true)
        case .active, .held:
            return nil
        case .ended, .failed, .missed:
            guard now.timeIntervalSince(phaseEnteredAt ?? now) > config.terminalLinger else { return nil }
            return enter(.idle, now: now)
        }
    }

    /// Reconciles one `AT+CLCC` snapshot with the tracked call.
    private mutating func apply(entries: [CLCCEntry], now: Date) -> CallTransition? {
        guard hasLiveCall else {
            guard let entry = entries.first else { return nil }
            return adopt(entry, now: now)
        }

        if phase == .ending {
            // A pending hang-up owns the transition. If the modem already
            // dropped the call, conclude with the stashed reason; otherwise
            // wait for the command result or the end timeout.
            guard let trackedDirection = direction.map(CLCCEntry.Direction.init),
                  entries.contains(where: { $0.direction == trackedDirection }) else {
                return concludePendingEnd(now: now)
            }
            return nil
        }

        guard let trackedDirection = direction.map(CLCCEntry.Direction.init),
              let tracked = entries.first(where: { $0.direction == trackedDirection }) else {
            // The tracked call vanished while other calls exist: conclude it.
            // A remaining incoming call is adopted by the next snapshot, after
            // the concluded outcome has been delivered.
            return conclude(vanishedCallReason, now: now, adviseHangUp: false)
        }

        switch tracked.status {
        case .active:
            if phase == .active { return nil }
            // R8 gate: a tracked incoming call may only become active through
            // this epoch's user answer — request, accepted `ATA`, and now the
            // matching `CLCC active`. A snapshot that claims active without
            // that chain (module auto-answer such as `ATS0`, or a direction
            // glitch) keeps the incoming surface actionable and is recorded
            // as a redacted anomaly instead.
            if (phase == .incoming || phase == .answering),
               trackedDirection == .incoming,
               answerIntent != .ataAccepted {
                clccActiveAnomalies += 1
                return nil
            }
            return enter(.active, now: now)
        case .held:
            if phase != .held { return enter(.held, now: now) }
        case .dialing:
            if phase != .dialing { return enter(.dialing, now: now) }
        case .alerting:
            if phase != .alerting { return enter(.alerting, now: now) }
        case .incoming, .waiting:
            if phase == .incoming { lastRingAt = now }
            if let trackedNumber = tracked.number, number == nil {
                number = trackedNumber
            }
        }
        return nil
    }

    /// Concludes the call with the reason stashed when the hang-up was
    /// requested, clearing the pending bookkeeping.
    private mutating func concludePendingEnd(now: Date, adviseHangUp: Bool = false) -> CallTransition? {
        let reason = pendingEndReason ?? .localHangUp
        pendingEndReason = nil
        phaseBeforeEnding = nil
        return conclude(reason, now: now, adviseHangUp: adviseHangUp)
    }

    private var vanishedCallReason: CallEndReason {
        switch phase {
        case .incoming, .answering: .missed
        case .active, .held: .remoteHangUp
        default: .noCarrier
        }
    }

    /// Starts tracking a call reported only through `AT+CLCC`. This is the
    /// R8 adopt path for calls this app never tracked from RING/CLIP — a
    /// call that is already active here was connected externally (module
    /// auto-answer, another tool) and is adopted as such. It never relaxes
    /// the gating applied to tracked incoming calls.
    private mutating func adopt(_ entry: CLCCEntry, now: Date) -> CallTransition? {
        switch entry.direction {
        case .incoming:
            switch entry.status {
            case .incoming, .waiting:
                return begin(.incoming, number: entry.number, direction: .incoming, now: now)
            case .active:
                let transition = begin(.active, number: entry.number, direction: .incoming, now: now)
                adoptedExternalCall = true
                callStartedAt = now
                return transition
            case .held:
                let transition = begin(.held, number: entry.number, direction: .incoming, now: now)
                adoptedExternalCall = true
                callStartedAt = now
                return transition
            case .dialing, .alerting:
                return nil
            }
        case .outgoing:
            switch entry.status {
            case .dialing: return begin(.dialing, number: entry.number, direction: .outgoing, now: now)
            case .alerting: return begin(.alerting, number: entry.number, direction: .outgoing, now: now)
            case .active:
                let transition = begin(.active, number: entry.number, direction: .outgoing, now: now)
                adoptedExternalCall = true
                callStartedAt = now
                return transition
            case .held:
                let transition = begin(.held, number: entry.number, direction: .outgoing, now: now)
                adoptedExternalCall = true
                callStartedAt = now
                return transition
            case .incoming, .waiting: return nil
            }
        }
    }

    private mutating func begin(
        _ target: CallPhase,
        number newNumber: String?,
        direction newDirection: CallDirection,
        now: Date
    ) -> CallTransition? {
        let from = phase
        callEpoch = nextEpoch
        nextEpoch += 1
        phase = target
        number = newNumber
        direction = newDirection
        phaseEnteredAt = now
        pendingEndReason = nil
        phaseBeforeEnding = nil
        answerIntent = .none
        clccActiveAnomalies = 0
        adoptedExternalCall = false
        if target == .incoming { lastRingAt = now }
        if target != .active { callStartedAt = nil }
        return CallTransition(from: from, to: target, outcome: nil, adviseHangUp: false)
    }

    /// Moves to a new phase of the same call.
    private mutating func enter(_ target: CallPhase, now: Date) -> CallTransition? {
        let from = phase
        phase = target
        phaseEnteredAt = now
        if target == .active {
            if callStartedAt == nil { callStartedAt = now }
        } else if target == .incoming {
            lastRingAt = now
        } else if target == .idle {
            number = nil
            direction = nil
            callStartedAt = nil
            pendingEndReason = nil
            phaseBeforeEnding = nil
            answerIntent = .none
            adoptedExternalCall = false
        }
        return CallTransition(from: from, to: target, outcome: nil, adviseHangUp: false)
    }

    private mutating func conclude(
        _ reason: CallEndReason,
        now: Date,
        adviseHangUp: Bool
    ) -> CallTransition? {
        let from = phase
        let outcome = CallOutcome(
            number: number,
            direction: direction,
            reason: reason,
            startedAt: callStartedAt
        )
        lastOutcome = outcome
        phase = Self.terminalPhase(for: reason)
        phaseEnteredAt = now
        callStartedAt = nil
        pendingEndReason = nil
        phaseBeforeEnding = nil
        answerIntent = .none
        return CallTransition(from: from, to: phase, outcome: outcome, adviseHangUp: adviseHangUp)
    }

    /// Terminal display phase for an end reason.
    static func terminalPhase(for reason: CallEndReason) -> CallPhase {
        switch reason {
        case .localHangUp, .remoteHangUp, .rejected: .ended
        case .missed: .missed
        case .busy, .noAnswer, .noCarrier, .dialTimeout, .answerTimeout, .dialFailed, .transportLost: .failed
        }
    }
}
