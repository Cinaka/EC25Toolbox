import XCTest
@testable import EC25Toolbox

final class PhoneNumberMatcherTests: XCTestCase {
    func testDigitsStripsSeparatorsAndMapsFullWidth() {
        XCTAssertEqual(PhoneNumberMatcher.digits("+86 138-0013 (8000)"), "8613800138000")
        XCTAssertEqual(PhoneNumberMatcher.digits("１３８００１３８０００"), "13800138000")
        XCTAssertEqual(PhoneNumberMatcher.digits("10086CALL"), "10086")
        XCTAssertEqual(PhoneNumberMatcher.digits("--"), "")
    }

    func testEqualDigitStringsMatchRegardlessOfSeparators() {
        XCTAssertTrue(PhoneNumberMatcher.matches("138 0013 8000", "13800138000"))
        XCTAssertTrue(PhoneNumberMatcher.matches("10086", "10086"))
    }

    func testCountryCodeAndTrunkPrefixDifferencesMatch() {
        XCTAssertTrue(PhoneNumberMatcher.matches("+8613800138000", "13800138000"))
        XCTAssertTrue(PhoneNumberMatcher.matches("+1 (555) 123-4567", "5551234567"))
        XCTAssertTrue(PhoneNumberMatcher.matches("013800138000", "+86 138 0013 8000"))
    }

    func testShortServiceNumbersDoNotFuzzyMatch() {
        XCTAssertFalse(PhoneNumberMatcher.matches("10086", "100861"))
        XCTAssertFalse(PhoneNumberMatcher.matches("10086", "955510086"))
    }

    func testEmptyNumbersNeverMatch() {
        XCTAssertFalse(PhoneNumberMatcher.matches("", "13800138000"))
        XCTAssertFalse(PhoneNumberMatcher.matches("----", "13800138000"))
        XCTAssertFalse(PhoneNumberMatcher.matches("", ""))
    }

    func testQueryMatchesDigitsSubstringOrRawValue() {
        XCTAssertTrue(PhoneNumberMatcher.number("13800138000", matchesQuery: "380"))
        XCTAssertTrue(PhoneNumberMatcher.number("+8613800138000", matchesQuery: "138 0013"))
        XCTAssertFalse(PhoneNumberMatcher.number("13800138000", matchesQuery: "999"))
        XCTAssertFalse(PhoneNumberMatcher.number("13800138000", matchesQuery: "  "))
        XCTAssertTrue(PhoneNumberMatcher.number("400-188-1234", matchesQuery: "188"))
    }
}

final class DialPadInputTests: XCTestCase {
    func testLongPressZeroAddsInternationalPrefix() {
        XCTAssertEqual(DialPadInput.addingInternationalPrefix(to: ""), "+")
        XCTAssertEqual(DialPadInput.addingInternationalPrefix(to: "8613800138000"), "+8613800138000")
    }

    func testInternationalPrefixIsIdempotentAndNeverEmbedded() {
        XCTAssertEqual(DialPadInput.addingInternationalPrefix(to: "+86"), "+86")
        XCTAssertEqual(DialPadInput.addingInternationalPrefix(to: "86+10"), "+8610")
    }
}
