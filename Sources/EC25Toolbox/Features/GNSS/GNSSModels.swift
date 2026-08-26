import Foundation

/// One GNSS position fix. Numeric fields are optional so missing or invalid
/// modem data stays visibly absent instead of being replaced by defaults;
/// `*Raw` strings keep the modem's original precision for display.
struct GNSSFix: Equatable, Sendable {
    /// Raw `hhmmss.sss` UTC time from the module.
    var utc: String?
    var latitude: Double?
    var longitude: Double?
    /// Original coordinate strings (hemisphere or decimal form).
    var latitudeRaw: String?
    var longitudeRaw: String?
    var hdop: Double?
    var altitudeMeters: Double?
    /// Module-reported fix mode (QGPSLOC `<fix>` field).
    var fixType: Int?
    var courseDegrees: Double?
    var speedKmh: Double?
    var speedKnots: Double?
    /// Raw `ddmmyy` date from the module.
    var date: String?
    var satelliteCount: Int?
    /// Wall-clock acquisition time, injected by the store — never parsed.
    var acquiredAt: Date = .distantPast
}

/// Discrete phases of the GNSS engine lifecycle.
enum GNSSPhase: String, Equatable, Codable, Sendable {
    /// Engine off (initial and post-stop state).
    case off
    /// Engine on, waiting for the first fix.
    case searching
    /// A good-quality fix is available.
    case fixed
    /// A fix exists but HDOP/satellite count indicates weak signal.
    case weak
    /// Searching exceeded the configured budget without any fix.
    case timeout
    /// The transport dropped while the engine was running.
    case lost
}

/// Outcome of the `AT+QGPS=?` firmware capability probe. Only a definitive
/// firmware rejection downgrades to `unsupported`; transport problems stay
/// `.error` so one flaky probe never hides the tab.
enum GNSSCapability: String, Equatable, Codable, Sendable {
    /// Not probed yet (before the first connect completes).
    case unknown
    /// The probe answered `OK` — a GNSS engine is present.
    case supported
    /// The firmware rejected the command as unknown/unsupported.
    case unsupported
    /// The probe could not complete (timeout, transport failure).
    case error

    var localizationKey: String { "gnss.capability.\(rawValue)" }

    /// Classifies one probe outcome. A thrown `ERROR` line or a CME
    /// "operation not supported" is a firmware verdict; anything else
    /// (timeouts, USB stalls, localization strings) is a transport problem.
    static func classify(_ result: Result<[String], any Error>) -> GNSSCapability {
        switch result {
        case .success:
            return .supported
        case let .failure(error):
            let message = error.localizedDescription
            if message == "ERROR" { return .unsupported }
            if let code = GNSSParsing.cmeErrorCode(in: message),
               code == 4 || code == 100 {
                return .unsupported
            }
            if message.contains("operation not supported")
                || message.contains("operation not allowed") && message.contains("+CME") {
                return .unsupported
            }
            return .error
        }
    }
}

/// Position data sources in fallback order (R4): Quectel's AT-based location
/// queries first, the independent USB NMEA interface as the last resort.
enum GNSSDataSource: String, Equatable, Codable, Sendable, CaseIterable {
    /// `AT+QGPSLOC=2` — multi-constellation query; some firmware rejects it.
    case qgpsloc2
    /// `AT+QGPSLOC` — default-constellation query.
    case qgpsloc
    /// `AT+QGPSGNMEA` — NMEA sentences over the AT port (needs `nmeasrc`).
    case qgpsgnmea
    /// The modem's independent USB NMEA interface, read directly.
    case nmeaPort

    /// The AT command this source polls, or nil for the USB endpoint.
    var atCommand: String? {
        switch self {
        case .qgpsloc2: "AT+QGPSLOC=2"
        case .qgpsloc: "AT+QGPSLOC"
        case .qgpsgnmea: "AT+QGPSGNMEA"
        case .nmeaPort: nil
        }
    }

    /// The next source down the chain; the USB endpoint is terminal.
    var fallback: GNSSDataSource? {
        switch self {
        case .qgpsloc2: .qgpsloc
        case .qgpsloc: .qgpsgnmea
        case .qgpsgnmea: .nmeaPort
        case .nmeaPort: nil
        }
    }

    var localizationKey: String { "gnss.source.\(rawValue)" }
}

/// One poll cycle's raw outcome, before fallback policy is applied.
enum GNSSPollOutcome: Equatable, Sendable {
    /// The source delivered a position fix.
    case fix
    /// The engine is running but has no position yet (CME 516 family).
    case noPosition
    /// The query itself failed; the message is the structured modem error.
    case failure(String)
}

/// Pure fallback policy for the source chain: two consecutive source-level
/// failures advance to the next source; "no position yet" never does — the
/// source works, the satellites are just not in view.
enum GNSSSourcePolicy {
    /// Failures tolerated before advancing to the next source.
    static let failureThreshold = 2

    struct Decision: Equatable, Sendable {
        /// The source to use next; nil keeps the current one.
        var advanceTo: GNSSDataSource?
        /// Structured reason recorded for diagnostics when advancing.
        var reason: String?
        /// Consecutive-failure counter for the next cycle.
        var failureCount: Int
    }

    static func evaluate(
        source: GNSSDataSource,
        outcome: GNSSPollOutcome,
        consecutiveFailures: Int
    ) -> Decision {
        switch outcome {
        case .fix:
            return Decision(advanceTo: nil, reason: nil, failureCount: 0)
        case .noPosition:
            return Decision(advanceTo: nil, reason: nil, failureCount: 0)
        case let .failure(message):
            let count = consecutiveFailures + 1
            guard count >= failureThreshold, let next = source.fallback else {
                return Decision(advanceTo: nil, reason: nil, failureCount: count)
            }
            return Decision(advanceTo: next, reason: message, failureCount: 0)
        }
    }
}

/// Render-ready snapshot of the GNSS engine for the UI.
struct GNSSStatus: Equatable, Sendable {
    var phase: GNSSPhase = .off
    var lastFix: GNSSFix?
    var lastError: String?
    var searchingSince: Date?
    /// Which source delivered the last position data. Informational, for the
    /// UI and diagnostics; nil until a source delivers a fix, cleared when
    /// the engine stops.
    var dataSource: GNSSDataSource?
    /// Structured reason the previous data source was abandoned, recorded in
    /// the diagnostics snapshot.
    var sourceFailure: String?

    var isEngineRunning: Bool {
        switch phase {
        case .searching, .fixed, .weak, .timeout: true
        case .off, .lost: false
        }
    }
}
