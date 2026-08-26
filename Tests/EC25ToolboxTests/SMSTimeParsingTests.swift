import XCTest
@testable import EC25Toolbox

final class SMSTimeParsingTests: XCTestCase {
    /// Fixed reference so century resolution is deterministic.
    private let resolvedAt = {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 22
        components.hour = 12
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private func utcComponents(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    // MARK: - TP-SCTS quarter-hour zone

    func testPositiveQuarterHourZoneParsesAsOffset() {
        // 32 quarters = 8 hours; the wall time is in the +08:00 zone.
        let timestamp = SMSTimeParsing.parse(raw: "26/07/10,09:40:48+32", resolvedAt: resolvedAt)
        XCTAssertNotNil(timestamp)
        XCTAssertEqual(timestamp?.sourceTimeZoneOffsetSeconds, 8 * 3_600)
        let parts = utcComponents(timestamp!.instant)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 7)
        XCTAssertEqual(parts.day, 10)
        XCTAssertEqual(parts.hour, 1)
        XCTAssertEqual(parts.minute, 40)
        XCTAssertEqual(parts.second, 48)
        XCTAssertEqual(timestamp?.raw, "26/07/10,09:40:48+32")
    }

    func testNegativeQuarterHourZoneParsesAsOffset() {
        // 16 quarters = 4 hours west.
        let timestamp = SMSTimeParsing.parse(raw: "26/01/15,23:59:59-16", resolvedAt: resolvedAt)
        XCTAssertEqual(timestamp?.sourceTimeZoneOffsetSeconds, -4 * 3_600)
        let parts = utcComponents(timestamp!.instant)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 1)
        XCTAssertEqual(parts.day, 16)
        XCTAssertEqual(parts.hour, 3)
        XCTAssertEqual(parts.minute, 59)
        XCTAssertEqual(parts.second, 59)
    }

    func testZeroZoneParses() {
        let timestamp = SMSTimeParsing.parse(raw: "26/03/01,00:00:00+00", resolvedAt: resolvedAt)
        XCTAssertEqual(timestamp?.sourceTimeZoneOffsetSeconds, 0)
        XCTAssertEqual(utcComponents(timestamp!.instant).hour, 0)
    }

    func testHalfHourAndFortyFiveMinuteZonesParse() {
        // 26 quarters = +06:30 (e.g. India-adjacent SCs); 27 = +06:45.
        let halfHour = SMSTimeParsing.parse(raw: "26/07/10,09:40:48+26", resolvedAt: resolvedAt)
        XCTAssertEqual(halfHour?.sourceTimeZoneOffsetSeconds, 6 * 3_600 + 1_800)
        XCTAssertEqual(utcComponents(halfHour!.instant).hour, 3)
        XCTAssertEqual(utcComponents(halfHour!.instant).minute, 10)

        let fortyFive = SMSTimeParsing.parse(raw: "26/07/10,09:40:48+27", resolvedAt: resolvedAt)
        XCTAssertEqual(fortyFive?.sourceTimeZoneOffsetSeconds, 6 * 3_600 + 2_700)
        XCTAssertEqual(utcComponents(fortyFive!.instant).minute, 55)
    }

    func testZoneBeyondFiftySixQuartersIsRejected() {
        // TS 23.040 caps the SCTS zone at ±14 hours (56 quarters).
        XCTAssertNil(SMSTimeParsing.parse(raw: "26/07/10,09:40:48+57", resolvedAt: resolvedAt))
        XCTAssertNil(SMSTimeParsing.parse(raw: "26/07/10,09:40:48-99", resolvedAt: resolvedAt))
    }

    // MARK: - Field validation

    func testMalformedTimestampsAreRejected() {
        XCTAssertNil(SMSTimeParsing.parse(raw: "26/13/01,09:40:48+32", resolvedAt: resolvedAt), "month 13")
        XCTAssertNil(SMSTimeParsing.parse(raw: "26/07/00,09:40:48+32", resolvedAt: resolvedAt), "day 0")
        XCTAssertNil(SMSTimeParsing.parse(raw: "26/07/10,24:40:48+32", resolvedAt: resolvedAt), "hour 24")
        XCTAssertNil(SMSTimeParsing.parse(raw: "26/07/10,09:60:48+32", resolvedAt: resolvedAt), "minute 60")
        XCTAssertNil(SMSTimeParsing.parse(raw: "not a timestamp", resolvedAt: resolvedAt))
        XCTAssertNil(SMSTimeParsing.parse(raw: "", resolvedAt: resolvedAt))
        XCTAssertNil(SMSTimeParsing.parse(raw: "2026/07/10,09:40:48+32", resolvedAt: resolvedAt), "four-digit year")
        XCTAssertNil(SMSTimeParsing.parse(raw: "26/07/10,09:40:48", resolvedAt: resolvedAt), "missing zone")
    }

    // MARK: - Century resolution

    func testTwoDigitYearResolvesOnceAgainstReference() {
        XCTAssertEqual(SMSTimeParsing.resolveCentury(twoDigitYear: 26, resolvedAt: resolvedAt), 2026)
        XCTAssertEqual(SMSTimeParsing.resolveCentury(twoDigitYear: 27, resolvedAt: resolvedAt), 2027, "currentYear + 1 stays in this century")
        XCTAssertEqual(SMSTimeParsing.resolveCentury(twoDigitYear: 28, resolvedAt: resolvedAt), 1928, "beyond currentYear + 1 rolls back a century")
        XCTAssertEqual(SMSTimeParsing.resolveCentury(twoDigitYear: 99, resolvedAt: resolvedAt), 1999)
        XCTAssertEqual(SMSTimeParsing.resolveCentury(twoDigitYear: 00, resolvedAt: resolvedAt), 2000)
    }

    func testCenturyAnchorDoesNotDriftWithLaterReferenceDates() {
        let first = SMSTimeParsing.parse(raw: "26/07/10,09:40:48+32", resolvedAt: resolvedAt)!
        // The same raw string parsed a decade later resolves differently, which
        // is exactly why callers must parse once and persist the instant.
        let yearsLater = resolvedAt.addingTimeInterval(10 * 365 * 24 * 3_600)
        let second = SMSTimeParsing.parse(raw: "26/07/10,09:40:48+32", resolvedAt: yearsLater)!
        XCTAssertEqual(first.instant, second.instant, "26 stays in this century for both references")
    }
}
