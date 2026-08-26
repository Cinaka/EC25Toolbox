import Foundation

/// One parsed modem-style SMS service timestamp (TP-SCTS).
///
/// The three time facets are stored separately: the absolute instant drives
/// sorting and deduplication, the source offset preserves the timezone the
/// service centre reported (a `+08:00`-style display), and the raw string is
/// kept for diagnostics only — never rendered directly.
struct SMSTimestamp: Equatable, Sendable {
    /// Absolute instant; the SC wall time interpreted in the source zone.
    var instant: Date
    /// Offset of the source timezone east of UTC in seconds (e.g. 28_800 for +08:00).
    var sourceTimeZoneOffsetSeconds: Int
    /// Raw modem representation, e.g. `26/07/10,09:40:48+32`.
    var raw: String
}

/// Parses `AT+CMGL` service timestamps of the form `yy/MM/dd,HH:mm:ss±QQ`.
///
/// `QQ` is the TP-SCTS timezone in quarter-hour units (15 minutes), not
/// hours: `+32` means 32 quarters = `+08:00`. The two-digit year is resolved
/// exactly once against the first-seen time supplied by the caller; callers
/// must persist the resulting instant instead of re-parsing later, so the
/// century never rolls as time passes.
enum SMSTimeParsing {
    /// Segments of one logical message may be stamped minutes apart, but a
    /// reused 8-bit reference from a much later message must not join them.
    static let clusteringWindow: TimeInterval = 24 * 60 * 60

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\d{2})/(\d{2})/(\d{2}),(\d{2}):(\d{2}):(\d{2})([+-])(\d{2})$"#
    )

    static func parse(raw: String, resolvedAt: Date) -> SMSTimestamp? {
        let text = trimmed(raw)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              match.numberOfRanges == 9 else { return nil }

        func field(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }

        guard let year = field(1), let month = field(2), let day = field(3),
              let hour = field(4), let minute = field(5), let second = field(6),
              let quarters = field(8) else { return nil }

        // Out-of-range fields mean a malformed SC timestamp, not a real date.
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second),
              // TS 23.040 caps the zone at ±14 hours = 56 quarters.
              (0...56).contains(quarters) else { return nil }

        let sign: Int = text[Range(match.range(at: 7), in: text)!] == "-" ? -1 : 1
        let offsetSeconds = sign * quarters * 15 * 60
        let fullYear = resolveCentury(twoDigitYear: year, resolvedAt: resolvedAt)

        var components = DateComponents()
        components.year = fullYear
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(identifier: "UTC")

        guard let wall = Calendar(identifier: .gregorian).date(from: components) else {
            return nil
        }
        // The SC reports wall time in its own zone; strip the offset for UTC.
        let instant = wall.addingTimeInterval(TimeInterval(-offsetSeconds))
        return SMSTimestamp(
            instant: instant,
            sourceTimeZoneOffsetSeconds: offsetSeconds,
            raw: text
        )
    }

    /// Resolves a two-digit year against the first-seen date. A candidate
    /// more than one year in the future belongs to the previous century
    /// (e.g. `99` first seen in 2026 is 1999, not 2099).
    static func resolveCentury(twoDigitYear: Int, resolvedAt: Date) -> Int {
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: resolvedAt)
        let century = (currentYear / 100) * 100
        let candidate = century + twoDigitYear
        if candidate > currentYear + 1 {
            return candidate - 100
        }
        return candidate
    }
}
