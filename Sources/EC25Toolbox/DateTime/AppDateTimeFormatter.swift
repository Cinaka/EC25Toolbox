import Foundation

/// Application-wide formatter for every user-visible date-time string (R0).
///
/// All rendering goes through a semantic role (`full`, `dateOnly`,
/// `timeOnly`, `compact`) instead of ad-hoc `DateFormatter`s scattered
/// through views. `DateFormatter` is mutable and not sendable, so every
/// instance is created and cached inside this `@MainActor` service — the
/// cache is the safety boundary, and views (which are MainActor) call the
/// service directly. Background code that needs a display string hops
/// through `MainActor.run`.
///
/// Machine formats (protocol fields, Codable payloads, Unix timestamps,
/// stable IDs, file and snapshot names) never route through this service.
@MainActor
final class AppDateTimeFormatter {
    static let shared = AppDateTimeFormatter()

    private struct CacheKey: Hashable {
        /// Empty pattern marks a follow-system formatter, where the role maps
        /// to `DateFormatter` styles instead of an LDML pattern.
        let pattern: String
        let role: DateTimeDisplayRole
        let localeIdentifier: String
        let timeZoneIdentifier: String
    }

    private var preferences = DateTimeDisplayPreferences.default
    /// BCP-47 app language override; empty follows the system locale.
    private var languageIdentifier = ""
    private var cache: [CacheKey: DateFormatter] = [:]

    var cacheEntryCount: Int { cache.count }

    /// Installed by the presentation layer whenever settings change. Changing
    /// the preferences drops every cached formatter so the next render picks
    /// up new patterns, zones, or mode.
    func apply(preferences: DateTimeDisplayPreferences) {
        guard preferences != self.preferences else { return }
        self.preferences = preferences
        cache.removeAll()
    }

    /// Mirrors `setAppLocale`: an explicit language fixes the formatter
    /// locale; empty follows the system.
    func apply(languageIdentifier: String) {
        guard languageIdentifier != self.languageIdentifier else { return }
        self.languageIdentifier = languageIdentifier
        cache.removeAll()
    }

    /// Renders one user-visible date-time string for a display role. The
    /// optional source offset (e.g. an SMS SCTS offset in seconds) is only
    /// consulted under the `.source` zone policy.
    func string(from date: Date, role: DateTimeDisplayRole, sourceTimeZoneOffsetSeconds: Int? = nil) -> String {
        let zone = timeZone(forSourceOffsetSeconds: sourceTimeZoneOffsetSeconds)
        let locale = resolvedLocale

        if preferences.mode == .followSystem {
            let formatter = cachedFormatter(
                pattern: "",
                role: role,
                locale: locale,
                timeZone: zone
            ) { formatter in
                let styles = Self.systemStyles(for: role)
                formatter.dateStyle = styles.date
                formatter.timeStyle = styles.time
            }
            return formatter.string(from: date)
        }

        let resolved = preferences.resolvedPattern(for: role)
        let formatter = cachedFormatter(
            pattern: resolved.pattern,
            role: role,
            locale: locale,
            timeZone: zone
        ) { formatter in
            formatter.dateFormat = resolved.pattern
        }
        return formatter.string(from: date)
    }

    /// The zone a timestamp renders in under the current policy. `.source`
    /// with an unknown offset, and an unrecognized custom identifier, both
    /// fall back to the system zone so rendering never fails.
    func timeZone(forSourceOffsetSeconds offsetSeconds: Int?) -> TimeZone {
        switch preferences.zonePolicy {
        case .source:
            if let offsetSeconds, let zone = TimeZone(secondsFromGMT: offsetSeconds) {
                return zone
            }
            return .current
        case .system:
            return .current
        case .utc:
            return TimeZone(secondsFromGMT: 0) ?? .current
        case .custom:
            return preferences.customTimeZone ?? .current
        }
    }

    var currentPreferences: DateTimeDisplayPreferences { preferences }

    /// Whether the current custom zone policy is missing an unrecognized IANA
    /// identifier; the settings page explains this with
    /// `datetime.error.invalid_timezone`.
    var hasInvalidCustomTimeZone: Bool { preferences.hasInvalidCustomTimeZone }

    private var resolvedLocale: Locale {
        languageIdentifier.isEmpty ? Locale.current : Locale(identifier: languageIdentifier)
    }

    private func cachedFormatter(
        pattern: String,
        role: DateTimeDisplayRole,
        locale: Locale,
        timeZone: TimeZone,
        configure: (DateFormatter) -> Void
    ) -> DateFormatter {
        let key = CacheKey(
            pattern: pattern,
            role: role,
            localeIdentifier: locale.identifier,
            timeZoneIdentifier: timeZone.identifier
        )
        if let cached = cache[key] {
            return cached
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        configure(formatter)
        cache[key] = formatter
        return formatter
    }

    /// Locale-provided styles used under `.followSystem`.
    private static func systemStyles(for role: DateTimeDisplayRole) -> (date: DateFormatter.Style, time: DateFormatter.Style) {
        switch role {
        case .full: (.long, .medium)
        case .dateOnly: (.medium, .none)
        case .timeOnly: (.none, .medium)
        case .compact: (.short, .short)
        }
    }
}
