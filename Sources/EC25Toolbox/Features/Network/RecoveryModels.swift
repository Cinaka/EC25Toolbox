import Foundation

/// Escalation ladder for automatic modem recovery, gentlest tier first.
enum RecoveryTier: Int, CaseIterable, Equatable, Hashable, Sendable, Codable {
    /// Reopens the AT transport (covers unplug/replug and re-enumeration).
    case usbReconnect
    /// Renews the module service DHCP lease and refreshes the interface.
    case dhcpRenew
    /// Re-attaches the packet domain and re-registers (CGATT/COPS).
    case networkReattach
    /// Cycles module RF without a USB re-enumeration (CFUN 0/1).
    case moduleReset
    /// Full module reboot; strictly rate-limited (CFUN=1,1).
    case hardReset

    var localizationKey: String {
        switch self {
        case .usbReconnect: return "recovery.tier.usb_reconnect"
        case .dhcpRenew: return "recovery.tier.dhcp_renew"
        case .networkReattach: return "recovery.tier.network_reattach"
        case .moduleReset: return "recovery.tier.module_reset"
        case .hardReset: return "recovery.tier.hard_reset"
        }
    }

    /// Minimum spacing between recovery attempts at this tier.
    var defaultCooldown: TimeInterval {
        switch self {
        case .usbReconnect: return 10
        case .dhcpRenew: return 45
        case .networkReattach: return 60
        case .moduleReset: return 300
        case .hardReset: return 600
        }
    }

    /// Attempts allowed at this tier per recovery episode.
    var defaultMaxAttempts: Int {
        switch self {
        case .usbReconnect: return 3
        case .dhcpRenew: return 2
        case .networkReattach: return 2
        case .moduleReset: return 1
        case .hardReset: return 1
        }
    }

    /// First tier tried for a symptom; earlier tiers are skipped because
    /// their preconditions cannot hold.
    static func firstTier(for symptom: RecoverySymptom) -> RecoveryTier {
        symptom == .transportLost ? .usbReconnect : .dhcpRenew
    }
}

/// Symptom that drives the escalation ladder.
enum RecoverySymptom: Equatable, Sendable {
    /// The AT transport is gone (unplug, re-enumeration, sleep).
    case transportLost
    /// AT answers but the module data path is unusable.
    case dataStalled
}

/// Result of authorizing a recovery attempt.
struct RecoveryBegin: Equatable, Sendable {
    var tier: RecoveryTier
    /// True when an exhausted episode restarted after its pause.
    var restartedEpisode: Bool
}

/// Result of reporting a tier outcome back to the machine.
struct RecoveryOutcomeReport: Equatable, Sendable {
    var recovered: Bool
    /// All applicable tiers of the episode are exhausted; the machine
    /// restarts the ladder after `Config.episodeRetryDelay`.
    var exhausted: Bool
    var attemptsAtTier: Int
}

/// Deterministic escalation state for automatic recovery. Every wall-clock
/// value arrives through the mutating calls so all decisions are testable;
/// the driver owns the actual modem/helper actions.
struct RecoveryStateMachine: Equatable, Sendable {
    struct Config: Equatable, Sendable {
        /// Per-tier cooldown overrides; missing entries use tier defaults.
        var cooldowns: [RecoveryTier: TimeInterval] = [:]
        /// Per-tier attempt caps; missing entries use tier defaults.
        var maxAttempts: [RecoveryTier: Int] = [:]
        /// Pause before an exhausted episode restarts from its first tier.
        var episodeRetryDelay: TimeInterval = 300

        func cooldown(_ tier: RecoveryTier) -> TimeInterval {
            cooldowns[tier] ?? tier.defaultCooldown
        }

        func attemptsAllowed(_ tier: RecoveryTier) -> Int {
            maxAttempts[tier] ?? tier.defaultMaxAttempts
        }
    }

    var config = Config()
    private(set) var symptom: RecoverySymptom?
    private(set) var attempts: [RecoveryTier: Int] = [:]
    /// Timestamp of the last authorized attempt or user activity; paces
    /// every tier decision and survives episode resets.
    private(set) var lastAttemptAt: Date?
    private(set) var exhaustedAt: Date?

    var isActive: Bool { symptom != nil }

    func attempts(at tier: RecoveryTier) -> Int {
        attempts[tier] ?? 0
    }

    /// Starts an episode for the symptom, or switches ladders when the
    /// symptom changed. Repeated reports of the same symptom are no-ops so
    /// the driver can call this on every poll tick.
    mutating func reportSymptom(_ symptom: RecoverySymptom, now: Date) {
        guard self.symptom != symptom else { return }
        self.symptom = symptom
        attempts = [:]
        exhaustedAt = nil
    }

    /// Authorizes the next attempt: the lowest applicable tier that still
    /// has attempts left and whose cooldown has elapsed. Returns nil while
    /// idle, cooling down, paused after exhaustion, or with no applicable
    /// tier; marks the episode exhausted when applicable tiers ran out.
    mutating func beginAttempt(now: Date, applicable: Set<RecoveryTier>) -> RecoveryBegin? {
        guard symptom != nil else { return nil }
        if let exhaustedAt {
            guard now.timeIntervalSince(exhaustedAt) >= config.episodeRetryDelay else { return nil }
            attempts = [:]
            self.exhaustedAt = nil
            return authorizedAttempt(now: now, applicable: applicable, restarted: true)
        }
        return authorizedAttempt(now: now, applicable: applicable, restarted: false)
    }

    /// Records the outcome of an attempt. Success ends the episode; failure
    /// consumes one attempt and escalates once the tier's cap is reached.
    mutating func reportOutcome(
        _ tier: RecoveryTier,
        succeeded: Bool,
        now: Date,
        applicable: Set<RecoveryTier>
    ) -> RecoveryOutcomeReport {
        guard symptom != nil else {
            return RecoveryOutcomeReport(recovered: false, exhausted: false, attemptsAtTier: attempts(at: tier))
        }
        if succeeded {
            reset()
            return RecoveryOutcomeReport(recovered: true, exhausted: false, attemptsAtTier: attempts(at: tier))
        }
        attempts[tier, default: 0] += 1
        let ladder = ladder(for: symptom!)
        let exhausted = ladder.contains { applicable.contains($0) }
            && !ladder.contains { applicable.contains($0) && attempts(at: $0) < config.attemptsAllowed($0) }
        if exhausted {
            exhaustedAt = now
        }
        return RecoveryOutcomeReport(recovered: false, exhausted: exhausted, attemptsAtTier: attempts(at: tier))
    }

    /// A user operation took priority; automation paces itself from now.
    mutating func reportUserActivity(now: Date) {
        lastAttemptAt = now
    }

    /// The user explicitly took over (manual connect/reconnect).
    mutating func cancel() {
        reset()
    }

    /// Health was confirmed by a poll; ends any active episode.
    mutating func reportHealthy() {
        reset()
    }

    // MARK: - Internals

    private mutating func reset() {
        symptom = nil
        attempts = [:]
        exhaustedAt = nil
    }

    private func ladder(for symptom: RecoverySymptom) -> [RecoveryTier] {
        let first = RecoveryTier.firstTier(for: symptom).rawValue
        return RecoveryTier.allCases.filter { $0.rawValue >= first }
    }

    private mutating func authorizedAttempt(
        now: Date,
        applicable: Set<RecoveryTier>,
        restarted: Bool
    ) -> RecoveryBegin? {
        let ladder = ladder(for: symptom!)
        guard let tier = ladder.first(where: {
            applicable.contains($0) && attempts(at: $0) < config.attemptsAllowed($0)
        }) else {
            // Only counts as exhaustion when the ladder had candidates at
            // all; with nothing applicable the driver keeps waiting for
            // preconditions to return (e.g. the NIC re-appearing).
            if ladder.contains(where: { applicable.contains($0) }) {
                exhaustedAt = now
            }
            return nil
        }
        if let last = lastAttemptAt, now.timeIntervalSince(last) < config.cooldown(tier) {
            return nil
        }
        lastAttemptAt = now
        return RecoveryBegin(tier: tier, restartedEpisode: restarted)
    }
}
