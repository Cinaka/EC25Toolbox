import Foundation

/// Semantic display roles every user-visible date-time must pick from.
///
/// Display boundary (R0): these roles govern *display only*. Machine formats
/// keep their own fixed conventions and are never affected by user display
/// preferences — AT/IMS/PDU protocol fields (e.g. `yy/MM/dd,hh:mm:ss±zz`),
/// Codable and remote-protocol payloads, security Unix timestamps, stable
/// record IDs, file names, and module-config backup snapshot names.
enum DateTimeDisplayRole: String, Codable, CaseIterable, Sendable {
    case full
    case dateOnly
    case timeOnly
    case compact
}

/// How the pattern for each display role is chosen.
enum DateTimePatternMode: String, Codable, CaseIterable, Sendable {
    /// Fixed app defaults; `full` is always `yyyy-MM-dd HH:mm:ssxxx`.
    case appDefault
    /// Locale-provided system styles instead of explicit LDML patterns.
    case followSystem
    /// User-provided LDML patterns per role.
    case custom
}

/// Which time zone user-visible timestamps render in.
enum DateTimeZonePolicy: String, Codable, CaseIterable, Sendable {
    /// The zone the timestamp originated from (e.g. an SMS SCTS offset);
    /// falls back to the system zone when the source offset is unknown.
    case source
    case system
    case utc
    /// A user-chosen IANA identifier from `customTimeZoneIdentifier`.
    case custom
}

/// User preferences for every user-visible date-time string (R0). Persisted
/// inside `ModemSettings.dateTimeDisplay`; `nil` means app defaults.
struct DateTimeDisplayPreferences: Codable, Equatable, Sendable {
    var mode: DateTimePatternMode = .appDefault
    var zonePolicy: DateTimeZonePolicy = .source
    var customTimeZoneIdentifier: String?
    var customFull: String?
    var customDateOnly: String?
    var customTimeOnly: String?
    var customCompact: String?

    static let `default` = DateTimeDisplayPreferences()

    /// Fixed app-default LDML patterns. The full pattern renders offsets with
    /// a sign and always shows the zone (`xxx`), e.g.
    /// `2026-07-10 09:40:48+08:00` and `2026-07-10 01:40:48+00:00` for UTC.
    static let defaultPatterns: [DateTimeDisplayRole: String] = [
        .full: "yyyy-MM-dd HH:mm:ssxxx",
        .dateOnly: "yyyy-MM-dd",
        .timeOnly: "HH:mm:ss",
        .compact: "yyyy-MM-dd HH:mm"
    ]

    init() {}

    init(
        mode: DateTimePatternMode,
        zonePolicy: DateTimeZonePolicy = .source,
        customTimeZoneIdentifier: String? = nil,
        customFull: String? = nil,
        customDateOnly: String? = nil,
        customTimeOnly: String? = nil,
        customCompact: String? = nil
    ) {
        self.mode = mode
        self.zonePolicy = zonePolicy
        self.customTimeZoneIdentifier = customTimeZoneIdentifier
        self.customFull = customFull
        self.customDateOnly = customDateOnly
        self.customTimeOnly = customTimeOnly
        self.customCompact = customCompact
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every field is optional on disk so partially-written or forward-
        // written values decode to defaults instead of throwing.
        mode = try container.decodeIfPresent(DateTimePatternMode.self, forKey: .mode) ?? .appDefault
        zonePolicy = try container.decodeIfPresent(DateTimeZonePolicy.self, forKey: .zonePolicy) ?? .source
        customTimeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .customTimeZoneIdentifier)
        customFull = try container.decodeIfPresent(String.self, forKey: .customFull)
        customDateOnly = try container.decodeIfPresent(String.self, forKey: .customDateOnly)
        customTimeOnly = try container.decodeIfPresent(String.self, forKey: .customTimeOnly)
        customCompact = try container.decodeIfPresent(String.self, forKey: .customCompact)
    }

    /// The custom pattern stored for a role, if any.
    func customPattern(for role: DateTimeDisplayRole) -> String? {
        switch role {
        case .full: customFull
        case .dateOnly: customDateOnly
        case .timeOnly: customTimeOnly
        case .compact: customCompact
        }
    }

    /// The pattern a role actually renders with, plus the reason a custom
    /// pattern was rejected. Invalid or absent custom patterns safely fall
    /// back to the app default so a bad persisted value can never blank the
    /// UI; the issue is surfaced for the settings page to explain.
    func resolvedPattern(for role: DateTimeDisplayRole) -> (pattern: String, issue: LDMLPatternIssue.Reason?) {
        guard mode == .custom, let custom = customPattern(for: role) else {
            return (Self.defaultPatterns[role] ?? Self.defaultPatterns[.full]!, nil)
        }
        if let reason = LDMLPatternValidator.validate(custom, for: role) {
            return (Self.defaultPatterns[role] ?? Self.defaultPatterns[.full]!, reason)
        }
        return (custom, nil)
    }

    /// All rejected custom patterns, for the settings page to list.
    func validationIssues() -> [LDMLPatternIssue] {
        guard mode == .custom else { return [] }
        return DateTimeDisplayRole.allCases.compactMap { role in
            guard let custom = customPattern(for: role),
                  let reason = LDMLPatternValidator.validate(custom, for: role) else { return nil }
            return LDMLPatternIssue(role: role, reason: reason)
        }
    }

    /// True when the zone policy demands a custom IANA zone that is missing
    /// or unrecognized; rendering falls back to the system zone meanwhile.
    var hasInvalidCustomTimeZone: Bool {
        guard zonePolicy == .custom else { return false }
        guard let identifier = customTimeZoneIdentifier, !identifier.isEmpty else { return true }
        return TimeZone(identifier: identifier) == nil
    }

    /// The custom IANA zone when configured and recognized.
    var customTimeZone: TimeZone? {
        guard let identifier = customTimeZoneIdentifier, !identifier.isEmpty else { return nil }
        return TimeZone(identifier: identifier)
    }
}

/// One rejected LDML pattern, pairing the display role with the reason so
/// the settings UI can point at the exact field.
struct LDMLPatternIssue: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The pattern is empty.
        case empty
        /// The pattern exceeds the character cap (payload carries the cap).
        case tooLong(maximum: Int)
        /// A single-quoted literal was never closed.
        case unterminatedQuote
        /// A letter run Foundation/ICU does not support (payload carries it).
        case unsupportedField(letter: String)
        /// A literal `+` appears in the pattern; `x`/`X` zone fields already
        /// carry the sign, so an extra one can only double it.
        case literalPlus
        /// A 12-hour field (`h`/`K`) lacks a day-period field (`a`/`b`/`B`).
        case hour12WithoutDayPeriod
        /// The role requires at least one date field.
        case missingDateField
        /// The role requires at least one time field.
        case missingTimeField
        /// The role requires at least one date or time field.
        case missingDateOrTimeField
    }

    var role: DateTimeDisplayRole
    var reason: Reason

    var messageKey: String {
        switch reason {
        case .empty: "datetime.error.empty"
        case .tooLong: "datetime.error.too_long"
        case .unterminatedQuote: "datetime.error.unterminated_quote"
        case .unsupportedField: "datetime.error.unsupported_field"
        case .literalPlus: "datetime.error.literal_plus"
        case .hour12WithoutDayPeriod: "datetime.error.hour12_without_day_period"
        case .missingDateField: "datetime.error.missing_date_field"
        case .missingTimeField: "datetime.error.missing_time_field"
        case .missingDateOrTimeField: "datetime.error.missing_date_or_time_field"
        }
    }

    /// Localized, user-presentable explanation for the settings page.
    func localizedMessage() -> String {
        switch reason {
        case .tooLong(let maximum):
            localizedFormat(messageKey, maximum)
        case .unsupportedField(let letter):
            localizedFormat(messageKey, letter)
        default:
            localized(messageKey)
        }
    }
}

/// Pure LDML pattern validation for custom date-time patterns (Unicode
/// LDML Part 4: Dates). Structural checks run before Foundation ever sees
/// the pattern; anything rejected here renders with the app default instead.
enum LDMLPatternValidator {
    static let maximumLength = 64
    /// Longest letter run any supported field accepts.
    static let maximumFieldRepeat = 6

    /// Pattern letters Foundation/ICU accept in a `dateFormat`. Skeleton-only
    /// fields (`j`, `J`, `C`), cyclic-year fields (`U`), and related-year
    /// fields (`r`) are deliberately excluded because they render
    /// locale-dependent placeholders instead of useful values.
    static let supportedFieldLetters: Set<Character> = [
        "G", "y", "Y", "u", "Q", "q", "M", "L", "w", "W", "d", "D", "F", "g",
        "E", "e", "c", "a", "b", "B", "h", "H", "K", "k", "m", "s", "S", "A",
        "z", "Z", "O", "v", "V", "X", "x"
    ]
    static let dateFieldLetters: Set<Character> = [
        "G", "y", "Y", "u", "Q", "q", "M", "L", "w", "W", "d", "D", "F", "g",
        "E", "e", "c"
    ]
    static let timeFieldLetters: Set<Character> = ["h", "H", "K", "k", "m", "s", "S", "A"]
    /// Day-period fields that disambiguate a 12-hour clock.
    static let dayPeriodFieldLetters: Set<Character> = ["a", "b", "B"]
    /// 12-hour clock hour fields.
    static let hour12FieldLetters: Set<Character> = ["h", "K"]

    /// Returns nil when the pattern is valid for the role, otherwise the
    /// first reason it was rejected.
    static func validate(_ pattern: String, for role: DateTimeDisplayRole) -> LDMLPatternIssue.Reason? {
        if pattern.isEmpty { return .empty }
        if pattern.count > maximumLength { return .tooLong(maximum: maximumLength) }

        var letters = Set<Character>()
        var inQuote = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]

            // `xxx`/`XXX` zone fields carry their own sign; a literal `+`
            // (quoted or bare) can only double it. Dates never need one.
            if character == "+" { return .literalPlus }

            if character == "'" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "'" {
                    // `''` is a literal apostrophe everywhere.
                    index = pattern.index(after: next)
                    continue
                }
                inQuote.toggle()
                index = pattern.index(after: index)
                continue
            }

            if !inQuote, character.isLetter {
                var run = 1
                var peek = pattern.index(after: index)
                while peek < pattern.endIndex, pattern[peek] == character {
                    run += 1
                    peek = pattern.index(after: peek)
                }
                guard supportedFieldLetters.contains(character) else {
                    return .unsupportedField(letter: String(character))
                }
                guard run <= maximumFieldRepeat else {
                    return .unsupportedField(letter: String(character))
                }
                letters.insert(character)
                index = peek
                continue
            }

            index = pattern.index(after: index)
        }

        if inQuote { return .unterminatedQuote }

        let hasDate = !letters.isDisjoint(with: dateFieldLetters)
        let hasTime = !letters.isDisjoint(with: timeFieldLetters)

        if !letters.isDisjoint(with: hour12FieldLetters),
           letters.isDisjoint(with: dayPeriodFieldLetters) {
            return .hour12WithoutDayPeriod
        }

        switch role {
        case .full:
            if !hasDate { return .missingDateField }
            if !hasTime { return .missingTimeField }
        case .dateOnly:
            if !hasDate { return .missingDateField }
        case .timeOnly:
            if !hasTime { return .missingTimeField }
        case .compact:
            if !hasDate && !hasTime { return .missingDateOrTimeField }
        }
        return nil
    }
}
