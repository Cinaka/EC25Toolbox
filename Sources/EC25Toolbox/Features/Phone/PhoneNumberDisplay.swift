import Foundation

/// Presentation-only normalization for Chinese phone numbers. Dialing and
/// contact matching keep the modem's original value; only user-facing text
/// and copy actions gain an international prefix when it can be inferred
/// safely from an 11-digit mainland mobile number.
enum PhoneNumberDisplay {
    static func internationalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = IncomingCallerIdentity.normalized(raw)
        guard !normalized.isEmpty else { return nil }
        if normalized.hasPrefix("+") { return normalized }
        if normalized.hasPrefix("00"), normalized.count > 2 {
            return "+" + normalized.dropFirst(2)
        }
        if normalized.count == 11, normalized.first == "1" {
            return "+86" + normalized
        }
        return normalized
    }
}
