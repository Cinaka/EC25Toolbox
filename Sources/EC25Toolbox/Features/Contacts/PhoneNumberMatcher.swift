import Foundation

/// Phone-number normalization and matching shared by caller ID, call history,
/// and contact search. Local conventions only: separator characters, `+`,
/// country-code (`86`) and trunk-prefix differences must not break a match.
enum PhoneNumberMatcher {
    /// ASCII digits of a raw number; full-width digits fold to ASCII and
    /// everything else (spaces, dashes, parentheses, letters) is dropped.
    static func digits(_ raw: String) -> String {
        raw.reduce(into: "") { result, character in
            switch character {
            case "0"..."9":
                result.append(character)
            case "０"..."９":
                guard let scalar = character.unicodeScalars.first,
                      let ascii = UnicodeScalar(scalar.value - 0xFF10 + 0x30) else { break }
                result.unicodeScalars.append(ascii)
            default:
                break
            }
        }
    }

    /// True when both raw numbers very likely address the same subscriber.
    /// Equal digit strings match; otherwise the shorter length becomes a
    /// suffix-compare budget, but only when it has at least 7 digits so short
    /// service numbers like `10086` never fuzzy-match longer ones. A single
    /// trunk `0` on either side is dropped first so `010-…` matches `+8610…`.
    static func matches(_ rawA: String, _ rawB: String) -> Bool {
        let a = digits(rawA)
        let b = digits(rawB)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        if suffixMatches(a, b) { return true }
        let trimmedA = a.hasPrefix("0") ? String(a.dropFirst()) : a
        let trimmedB = b.hasPrefix("0") ? String(b.dropFirst()) : b
        if trimmedA.count != a.count || trimmedB.count != b.count {
            return suffixMatches(trimmedA, trimmedB)
        }
        return false
    }

    private static func suffixMatches(_ a: String, _ b: String) -> Bool {
        let budget = min(a.count, b.count)
        guard budget >= 7 else { return false }
        return String(a.suffix(budget)) == String(b.suffix(budget))
    }

    /// True when a typed query plausibly refers to the number: its digits are
    /// a substring of the number's digits, or the raw value contains the raw
    /// query (for letters stored inside numbers).
    static func number(_ raw: String, matchesQuery query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let queryDigits = digits(trimmed)
        if !queryDigits.isEmpty, digits(raw).contains(queryDigits) { return true }
        return raw.localizedCaseInsensitiveContains(trimmed)
    }
}
