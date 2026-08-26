import Foundation

/// Inputs accepted by the GNSS state machine: engine lifecycle intents,
/// fix/no-fix query outcomes, periodic ticks, and data-source bookkeeping.
enum GNSSInput: Equatable, Sendable {
    case start
    case fix(GNSSFix)
    /// The engine answered but has no position yet (`+CME ERROR: 516`).
    case noFix
    /// The position query itself failed (transport or unexpected CME error).
    case queryFailed(String)
    /// A data source delivered position data and becomes the active source.
    case source(GNSSDataSource)
    /// The active data source was abandoned; carries the structured reason.
    case sourceFallback(String)
    case stop
    case transportLost
    case tick
}

/// Phase change emitted by the machine; nil means "input caused no change".
struct GNSSTransition: Equatable, Sendable {
    var from: GNSSPhase
    var to: GNSSPhase
}

/// Deterministic GNSS engine state. All wall-clock values arrive through
/// `handle(_:now:)` so every transition is unit-testable.
struct GNSSStateMachine: Equatable, Sendable {
    struct Config: Equatable, Sendable {
        /// Searching budget before the phase flips to `.timeout`.
        var searchTimeout: TimeInterval = 120
        /// HDOP above this marks a fix as weak.
        var weakHDOPThreshold: Double = 10
        /// Fewer satellites than this marks a fix as weak.
        var weakSatelliteThreshold: Int = 4
        /// A fix older than this sends the engine back to `.searching`.
        var fixExpiry: TimeInterval = 30
    }

    var config = Config()
    private(set) var status = GNSSStatus()

    var isEngineRunning: Bool { status.isEngineRunning }

    @discardableResult
    mutating func handle(_ input: GNSSInput, now: Date) -> GNSSTransition? {
        switch input {
        case .start:
            guard status.phase != .searching else { return nil }
            let previous = status.phase
            status.phase = .searching
            status.searchingSince = now
            status.lastError = nil
            return GNSSTransition(from: previous, to: .searching)

        case let .fix(fix):
            guard status.phase != .off, status.phase != .lost else { return nil }
            var applied = fix
            if applied.acquiredAt == .distantPast { applied.acquiredAt = now }
            status.lastFix = applied
            let weak = isWeak(applied)
            let target: GNSSPhase = weak ? .weak : .fixed
            guard status.phase != target else { return nil }
            let previous = status.phase
            status.phase = target
            return GNSSTransition(from: previous, to: target)

        case .noFix:
            return nil // keep the current phase; tick handles budgets

        case let .queryFailed(message):
            guard status.phase != .off, status.phase != .lost else { return nil }
            status.lastError = message
            return nil

        case let .source(source):
            guard status.isEngineRunning else { return nil }
            status.dataSource = source
            return nil

        case let .sourceFallback(reason):
            guard status.isEngineRunning else { return nil }
            status.sourceFailure = reason
            return nil

        case .stop:
            guard status.phase != .off else { return nil }
            let previous = status.phase
            status.phase = .off
            status.searchingSince = nil
            status.lastFix = nil
            status.lastError = nil
            status.dataSource = nil
            status.sourceFailure = nil
            return GNSSTransition(from: previous, to: .off)

        case .transportLost:
            guard status.isEngineRunning else { return nil }
            let previous = status.phase
            status.phase = .lost
            status.searchingSince = nil
            status.dataSource = nil
            status.sourceFailure = nil
            return GNSSTransition(from: previous, to: .lost)

        case .tick:
            switch status.phase {
            case .searching:
                guard let since = status.searchingSince,
                      now.timeIntervalSince(since) >= config.searchTimeout else { return nil }
                status.phase = .timeout
                return GNSSTransition(from: .searching, to: .timeout)
            case .fixed, .weak:
                guard let fix = status.lastFix,
                      now.timeIntervalSince(fix.acquiredAt) >= config.fixExpiry else { return nil }
                let previous = status.phase
                status.phase = .searching
                status.searchingSince = now
                return GNSSTransition(from: previous, to: .searching)
            case .off, .timeout, .lost:
                return nil
            }
        }
    }

    private func isWeak(_ fix: GNSSFix) -> Bool {
        if let hdop = fix.hdop, hdop > config.weakHDOPThreshold { return true }
        if let satellites = fix.satelliteCount, satellites < config.weakSatelliteThreshold { return true }
        return false
    }
}
