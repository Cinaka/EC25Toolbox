import Foundation

/// Extracts 4–8 digit verification codes from message bodies. A code only
/// qualifies when a known keyword appears within a small window around it,
/// which keeps phone numbers, dates, amounts, and order IDs out of the result.
enum VerificationCodeExtractor {
    /// Chinese and English keywords that reliably announce a copyable code.
    /// Deliberately conservative: bare English "code" is too ambiguous.
    private static let keywords = [
        "验证码",
        "校验码",
        "动态码",
        "动态口令",
        "提取码",
        "取件码",
        "安全码",
        "verification code",
        "security code",
        "confirmation code",
        "passcode",
        "one-time password",
        "one time password",
        "login code",
        "access code",
        "otp",
    ]

    /// How far around a keyword a code may appear, in characters.
    private static let windowRadius = 24
    /// Never return more codes than a user could plausibly act on.
    private static let maximumResults = 3

    /// High-confidence codes found in the body, in order of appearance.
    static func extract(from body: String) -> [String] {
        guard !body.isEmpty else { return [] }
        let lowered = body.lowercased()
        var results: [String] = []
        for keyword in keywords {
            var searchStart = lowered.startIndex
            while searchStart < lowered.endIndex,
                  let keywordRange = lowered.range(of: keyword, range: searchStart..<lowered.endIndex) {
                collectCodes(around: keywordRange, in: body, into: &results)
                searchStart = keywordRange.upperBound
                if results.count >= maximumResults {
                    return Array(results.prefix(maximumResults))
                }
            }
        }
        return results
    }

    private static func collectCodes(
        around keywordRange: Range<String.Index>,
        in body: String,
        into results: inout [String]
    ) {
        let windowStart = body.index(keywordRange.lowerBound, offsetBy: -windowRadius, limitedBy: body.startIndex) ?? body.startIndex
        let windowEnd = body.index(keywordRange.upperBound, offsetBy: windowRadius, limitedBy: body.endIndex) ?? body.endIndex
        let pattern = #"\d{4,8}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let window = body[windowStart..<windowEnd]
        let nsRange = NSRange(window.startIndex..<window.endIndex, in: body)
        for match in regex.matches(in: body, range: nsRange) {
            guard let range = Range(match.range, in: body) else { continue }
            guard isDigitBoundary(before: range.lowerBound, in: body),
                  isDigitBoundary(after: range.upperBound, in: body),
                  isPlausibleCode(body[range], at: range, in: body) else { continue }
            let code = String(body[range])
            if !results.contains(code) {
                results.append(code)
            }
            if results.count >= maximumResults { return }
        }
    }

    /// The neighbor of a candidate must not be another digit (that would make
    /// it a fragment of a longer number) nor the integer part of a decimal or
    /// thousands-separated amount.
    private static func isDigitBoundary(
        before index: String.Index,
        in body: String
    ) -> Bool {
        guard index > body.startIndex else { return true }
        let previous = body[body.index(before: index)]
        return !previous.isNumber && !"．.，,￥$€£".contains(previous)
    }

    private static func isDigitBoundary(
        after index: String.Index,
        in body: String
    ) -> Bool {
        guard index < body.endIndex else { return true }
        let next = body[index]
        if next.isNumber || next == "%" { return false }
        if next == "." || next == "．" {
            // Decimal point ("1234.56") makes the candidate a fragment; a
            // sentence-ending period does not.
            let following = body.index(after: index)
            guard following < body.endIndex else { return true }
            return !body[following].isNumber
        }
        if next == "," || next == "，" {
            // Thousands group: exactly three digits then a non-digit or end
            // ("1234,567"). "123456，5分钟内" is a real code instead.
            var cursor = index
            var digitCount = 0
            while cursor < body.endIndex, body[cursor].isNumber {
                digitCount += 1
                cursor = body.index(after: cursor)
            }
            let thousandsGroup = digitCount == 3 && (cursor == body.endIndex || !body[cursor].isNumber)
            return !thousandsGroup
        }
        return true
    }

    /// A bare year in a validity sentence ("验证码有效期至2026年") is not a
    /// code: drop four-digit 19xx/20xx values directly followed by 年.
    private static func isPlausibleCode(
        _ code: Substring,
        at range: Range<String.Index>,
        in body: String
    ) -> Bool {
        guard code.count == 4,
              let value = Int(code),
              (1900...2099).contains(value),
              range.upperBound < body.endIndex else { return true }
        return body[range.upperBound] != "年"
    }
}
