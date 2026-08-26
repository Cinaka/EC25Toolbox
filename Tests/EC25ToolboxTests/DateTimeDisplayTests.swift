import XCTest
@testable import EC25Toolbox

@MainActor
final class DateTimeDisplayTests: XCTestCase {
    private static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int, _ second: Int,
        timeZone: TimeZone
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = timeZone
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    /// 2026-07-10 09:40:48 +08:00 — the plan's reference instant.
    private var referenceDate: Date {
        Self.date(2026, 7, 10, 9, 40, 48, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        Self.date(year, month, day, hour, minute, second, timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private func freshFormatter() -> AppDateTimeFormatter {
        let formatter = AppDateTimeFormatter()
        formatter.apply(languageIdentifier: "en")
        return formatter
    }

    // MARK: Default patterns and reference example

    func testDefaultFullPatternRendersReferenceExample() {
        XCTAssertEqual(DateTimeDisplayPreferences.defaultPatterns[.full], "yyyy-MM-dd HH:mm:ssxxx")

        let formatter = freshFormatter()
        formatter.apply(preferences: DateTimeDisplayPreferences(
            mode: .appDefault, zonePolicy: .custom, customTimeZoneIdentifier: "Asia/Shanghai"
        ))
        XCTAssertEqual(
            formatter.string(from: referenceDate, role: .full),
            "2026-07-10 09:40:48+08:00"
        )
    }

    func testSourceOffsetPolicyRendersOriginZone() {
        let formatter = freshFormatter()
        formatter.apply(preferences: DateTimeDisplayPreferences(mode: .appDefault, zonePolicy: .source))
        XCTAssertEqual(
            formatter.string(from: referenceDate, role: .full, sourceTimeZoneOffsetSeconds: 8 * 3600),
            "2026-07-10 09:40:48+08:00"
        )
    }

    func testUTCPolicyRendersNumericZeroOffset() {
        let formatter = freshFormatter()
        formatter.apply(preferences: DateTimeDisplayPreferences(mode: .appDefault, zonePolicy: .utc))
        let instant = utcDate(2026, 7, 10, 1, 40, 48)
        XCTAssertEqual(
            formatter.string(from: instant, role: .full),
            "2026-07-10 01:40:48+00:00"
        )
    }

    func testFractionalAndNegativeOffsetZones() {
        let formatter = freshFormatter()
        formatter.apply(preferences: DateTimeDisplayPreferences(mode: .appDefault, zonePolicy: .source))
        let instant = utcDate(2026, 7, 10, 1, 40, 48)

        // +05:30 (Kolkata), +05:45 (Kathmandu), -09:30 (Marquesas), -05:00 (New York standard).
        XCTAssertTrue(
            formatter.string(from: instant, role: .full, sourceTimeZoneOffsetSeconds: 19_800)
                .hasSuffix("+05:30")
        )
        XCTAssertTrue(
            formatter.string(from: instant, role: .full, sourceTimeZoneOffsetSeconds: 20_700)
                .hasSuffix("+05:45")
        )
        XCTAssertTrue(
            formatter.string(from: instant, role: .full, sourceTimeZoneOffsetSeconds: -34_200)
                .hasSuffix("-09:30")
        )
        XCTAssertTrue(
            formatter.string(from: instant, role: .full, sourceTimeZoneOffsetSeconds: -18_000)
                .hasSuffix("-05:00")
        )
    }

    func testCustomIANAZoneFollowsDaylightSavingTime() {
        let formatter = freshFormatter()
        formatter.apply(preferences: DateTimeDisplayPreferences(
            mode: .appDefault, zonePolicy: .custom, customTimeZoneIdentifier: "America/New_York"
        ))

        let januaryRendered = formatter.string(from: utcDate(2026, 1, 15, 12, 0, 0), role: .full)
        let julyRendered = formatter.string(from: utcDate(2026, 7, 15, 12, 0, 0), role: .full)
        XCTAssertTrue(januaryRendered.hasSuffix("-05:00"), "expected EST, got \(januaryRendered)")
        XCTAssertTrue(julyRendered.hasSuffix("-04:00"), "expected EDT, got \(julyRendered)")
    }

    // MARK: LDML validation

    func testValidatorAcceptsValidPatterns() {
        let cases: [(String, DateTimeDisplayRole)] = [
            ("yyyy-MM-dd HH:mm:ssxxx", .full),
            ("yyyy-MM-dd h:mm:ss a", .full),
            ("KK:mm B", .timeOnly),
            ("yyyy 'o''clock' mm", .dateOnly),
            ("EEEE, MMMM d, y G", .dateOnly),
            ("yyyy", .compact),
            ("HH:mm zzz", .timeOnly),
            ("yyMMdd", .dateOnly),
            ("yyyy-MM-dd HH:mm:ssXXX", .full),
            ("hh:mm a b B", .timeOnly),
        ]
        for (pattern, role) in cases {
            XCTAssertNil(
                LDMLPatternValidator.validate(pattern, for: role),
                "expected \(pattern) to be valid for \(role)"
            )
        }
    }

    func testEmptyAndTooLongPatternsRejected() {
        XCTAssertEqual(LDMLPatternValidator.validate("", for: .full), .empty)
        XCTAssertEqual(
            LDMLPatternValidator.validate(
                String(repeating: "y", count: LDMLPatternValidator.maximumLength + 1), for: .full
            ),
            .tooLong(maximum: LDMLPatternValidator.maximumLength)
        )
    }

    func testUnterminatedQuoteRejected() {
        XCTAssertEqual(
            LDMLPatternValidator.validate("yyyy 'unclosed", for: .dateOnly),
            .unterminatedQuote
        )
    }

    func testUnsupportedFieldLettersRejected() {
        // Skeleton-only fields and non-field letters.
        for letter in ["j", "J", "C", "U", "r", "n", "t", "i", "p", "f"] {
            XCTAssertEqual(
                LDMLPatternValidator.validate("yyyy-MM-dd HH:mm:\(letter)\(letter)\(letter)", for: .full),
                .unsupportedField(letter: letter),
                "expected \(letter) to be rejected"
            )
        }
        // Runs longer than any supported field accepts.
        XCTAssertEqual(
            LDMLPatternValidator.validate("yyyyyyy-MM-dd HH:mm:ss", for: .full),
            .unsupportedField(letter: "y")
        )
    }

    func testLiteralPlusRejectedEverywhere() {
        XCTAssertEqual(
            LDMLPatternValidator.validate("yyyy-MM-dd HH:mm:ssxxx+08:00", for: .full),
            .literalPlus
        )
        XCTAssertEqual(
            LDMLPatternValidator.validate("yyyy+MM-dd", for: .dateOnly),
            .literalPlus
        )
        // Even a quoted plus is still a literal plus the pattern must not need.
        XCTAssertEqual(
            LDMLPatternValidator.validate("HH:mm 'UTC+8'", for: .timeOnly),
            .literalPlus
        )
    }

    func testTwelveHourFieldsRequireDayPeriod() {
        XCTAssertEqual(
            LDMLPatternValidator.validate("hh:mm:ss", for: .timeOnly),
            .hour12WithoutDayPeriod
        )
        XCTAssertEqual(
            LDMLPatternValidator.validate("KK:mm", for: .timeOnly),
            .hour12WithoutDayPeriod
        )
        XCTAssertNil(LDMLPatternValidator.validate("hh:mm:ss a", for: .timeOnly))
        XCTAssertNil(LDMLPatternValidator.validate("KK:mm b", for: .timeOnly))
        XCTAssertNil(LDMLPatternValidator.validate("KK:mm B", for: .timeOnly))
        // 24-hour fields never require a period.
        XCTAssertNil(LDMLPatternValidator.validate("HH:mm:ss", for: .timeOnly))
    }

    func testRoleMinimumFieldRequirements() {
        XCTAssertEqual(
            LDMLPatternValidator.validate("HH:mm:ss", for: .dateOnly),
            .missingDateField
        )
        XCTAssertEqual(
            LDMLPatternValidator.validate("yyyy-MM-dd", for: .timeOnly),
            .missingTimeField
        )
        XCTAssertEqual(
            LDMLPatternValidator.validate("yyyy-MM-dd", for: .full),
            .missingTimeField
        )
        XCTAssertEqual(
            LDMLPatternValidator.validate("HH:mm:ssxxx", for: .full),
            .missingDateField
        )
        XCTAssertEqual(
            LDMLPatternValidator.validate("Z", for: .compact),
            .missingDateOrTimeField
        )
        XCTAssertNil(LDMLPatternValidator.validate("yyyy", for: .compact))
        XCTAssertNil(LDMLPatternValidator.validate("HH", for: .compact))
    }

    func testQuotedLiteralsEscapeCorrectly() {
        let formatter = freshFormatter()
        formatter.apply(preferences: DateTimeDisplayPreferences(
            mode: .custom, zonePolicy: .utc, customFull: "yyyy 'o''clock' HH:mm:ss"
        ))
        XCTAssertEqual(
            formatter.string(from: utcDate(2026, 7, 10, 9, 40, 48), role: .full),
            "2026 o'clock 09:40:48"
        )
    }

    // MARK: Fallback and persistence

    func testInvalidPersistedPatternFallsBackWithIssue() {
        let preferences = DateTimeDisplayPreferences(mode: .custom, customFull: "hh:mm:ss")
        let (pattern, issue) = preferences.resolvedPattern(for: .full)
        XCTAssertEqual(pattern, "yyyy-MM-dd HH:mm:ssxxx")
        XCTAssertEqual(issue, .hour12WithoutDayPeriod)
        XCTAssertEqual(preferences.validationIssues().count, 1)
        XCTAssertEqual(preferences.validationIssues().first?.role, .full)

        // Absent custom patterns fall back without inventing an issue.
        let (dateOnlyPattern, dateOnlyIssue) = preferences.resolvedPattern(for: .dateOnly)
        XCTAssertEqual(dateOnlyPattern, "yyyy-MM-dd")
        XCTAssertNil(dateOnlyIssue)

        // The formatter renders with the safe default, never the bad value.
        let formatter = freshFormatter()
        formatter.apply(preferences: preferences)
        formatter.apply(preferences: DateTimeDisplayPreferences(
            mode: .custom, customFull: "yyyy-MM-dd HH:mm:ss+08:00"
        ))
        XCTAssertEqual(
            formatter.string(from: utcDate(2026, 7, 10, 1, 40, 48), role: .full, sourceTimeZoneOffsetSeconds: 28_800),
            "2026-07-10 09:40:48+08:00"
        )
    }

    func testInvalidCustomTimeZoneDetectedAndFallsBack() {
        var preferences = DateTimeDisplayPreferences(
            mode: .appDefault, zonePolicy: .custom, customTimeZoneIdentifier: "Not/AZone"
        )
        XCTAssertTrue(preferences.hasInvalidCustomTimeZone)
        XCTAssertNil(preferences.customTimeZone)

        preferences.customTimeZoneIdentifier = "Asia/Shanghai"
        XCTAssertFalse(preferences.hasInvalidCustomTimeZone)
        XCTAssertEqual(preferences.customTimeZone?.identifier, "Asia/Shanghai")

        // A missing identifier under the custom policy is also invalid.
        preferences.customTimeZoneIdentifier = nil
        XCTAssertTrue(preferences.hasInvalidCustomTimeZone)

        // Non-custom policies never report a custom-zone issue.
        let source = DateTimeDisplayPreferences(mode: .appDefault, zonePolicy: .source)
        XCTAssertFalse(source.hasInvalidCustomTimeZone)
    }

    func testPreferencesDecodeWithMissingKeys() throws {
        let empty = try JSONDecoder().decode(DateTimeDisplayPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, .default)

        let partial = try JSONDecoder().decode(
            DateTimeDisplayPreferences.self,
            from: Data(#"{"mode":"custom","customFull":"yyyy-MM-dd HH:mm:ss"}"#.utf8)
        )
        XCTAssertEqual(partial.mode, .custom)
        XCTAssertEqual(partial.customFull, "yyyy-MM-dd HH:mm:ss")
        XCTAssertEqual(partial.zonePolicy, .source)

        let roundtrip = try JSONDecoder().decode(
            DateTimeDisplayPreferences.self,
            from: JSONEncoder().encode(DateTimeDisplayPreferences(
                mode: .custom, zonePolicy: .custom, customTimeZoneIdentifier: "UTC",
                customCompact: "MM-dd HH:mm"
            ))
        )
        XCTAssertEqual(roundtrip.customTimeZoneIdentifier, "UTC")
        XCTAssertEqual(roundtrip.customCompact, "MM-dd HH:mm")
    }

    // MARK: Locale and cache behavior

    func testLocaleSwitchChangesLocalizedFields() {
        let formatter = freshFormatter()
        formatter.apply(preferences: DateTimeDisplayPreferences(mode: .custom, customCompact: "yyyy MMM"))

        formatter.apply(languageIdentifier: "en")
        let english = formatter.string(from: utcDate(2026, 7, 10, 1, 40, 48), role: .compact)
        XCTAssertEqual(english, "2026 Jul")

        formatter.apply(languageIdentifier: "zh-Hans")
        let chinese = formatter.string(from: utcDate(2026, 7, 10, 1, 40, 48), role: .compact)
        XCTAssertEqual(chinese, "2026 7月")
        XCTAssertNotEqual(english, chinese)
    }

    func testCacheReusesFormattersAndInvalidatesOnPreferenceChange() {
        let formatter = freshFormatter()
        formatter.apply(preferences: DateTimeDisplayPreferences(mode: .appDefault, zonePolicy: .utc))

        _ = formatter.string(from: referenceDate, role: .full)
        _ = formatter.string(from: referenceDate, role: .full)
        _ = formatter.string(from: referenceDate, role: .compact)
        XCTAssertEqual(formatter.cacheEntryCount, 2, "identical keys must reuse cached formatters")

        // A new preference set drops the cache; rendering picks up the change.
        formatter.apply(preferences: DateTimeDisplayPreferences(mode: .custom, zonePolicy: .utc, customFull: "yy/MM/dd HH:mm"))
        XCTAssertEqual(formatter.cacheEntryCount, 0)
        XCTAssertEqual(formatter.string(from: utcDate(2026, 7, 10, 1, 40, 48), role: .full), "26/07/10 01:40")

        // Re-applying identical preferences must not thrash the cache.
        let count = formatter.cacheEntryCount
        formatter.apply(preferences: DateTimeDisplayPreferences(mode: .custom, zonePolicy: .utc, customFull: "yy/MM/dd HH:mm"))
        XCTAssertEqual(formatter.cacheEntryCount, count)
    }

    func testFollowSystemModeUsesLocaleStyles() {
        let formatter = freshFormatter()
        formatter.apply(preferences: DateTimeDisplayPreferences(mode: .followSystem, zonePolicy: .utc))

        let rendered = formatter.string(from: utcDate(2026, 7, 10, 1, 40, 48), role: .full)
        XCTAssertFalse(rendered.isEmpty)
        XCTAssertTrue(rendered.contains("2026"), "system styles must include the year, got \(rendered)")

        let timeOnly = formatter.string(from: utcDate(2026, 7, 10, 1, 40, 48), role: .timeOnly)
        XCTAssertTrue(timeOnly.contains("40"), "system time style must include minutes, got \(timeOnly)")
    }

    func testMachineFormatsUnaffectedByDisplayPreferences() {
        // The display preferences must never leak into machine formats:
        // protocol strings, ISO-8601 Codable dates, and Unix timestamps stay
        // fixed regardless of the mode, patterns, or zone policy.
        let machine = ISO8601DateFormatter()
        machine.formatOptions = [.withInternetDateTime]
        let instant = utcDate(2026, 7, 10, 1, 40, 48)
        let before = machine.string(from: instant)
        XCTAssertEqual(instant.timeIntervalSince1970, 1_783_647_648)

        let formatter = freshFormatter()
        formatter.apply(preferences: DateTimeDisplayPreferences(
            mode: .custom, zonePolicy: .custom, customTimeZoneIdentifier: "America/New_York",
            customFull: "yy/MM/dd"
        ))
        XCTAssertEqual(machine.string(from: instant), before)
    }
}
