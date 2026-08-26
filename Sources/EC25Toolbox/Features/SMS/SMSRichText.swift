import Foundation

/// One interactive range inside an SMS body. Ordinary detected links open in
/// the system handler; verification codes use an internal URL that the message
/// bubble translates into a pasteboard copy action.
struct SMSRichTextTarget: Equatable {
    enum Action: Equatable {
        case open(URL)
        case copyCode(String)
    }

    var range: NSRange
    var action: Action

    var url: URL {
        switch action {
        case let .open(url):
            url
        case let .copyCode(code):
            SMSRichTextDetector.copyURL(for: code)
        }
    }
}

/// Builds the attributed content used by Messages-style bubbles. Detection is
/// intentionally presentation-only; it never changes the archived SMS body.
enum SMSRichTextDetector {
    static let copyCodeScheme = "ec25toolbox-copy-code"

    static func targets(in body: String) -> [SMSRichTextTarget] {
        let codeTargets = verificationCodeTargets(in: body)
        let detectedTargets = dataTargets(in: body).filter { candidate in
            !codeTargets.contains { codeTarget in
                NSIntersectionRange(candidate.range, codeTarget.range).length > 0
            }
        }

        return (detectedTargets + codeTargets).sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length > $1.range.length
        }
    }

    static func attributedString(for body: String) -> AttributedString {
        var result = AttributedString(body)
        for target in targets(in: body) {
            guard let sourceRange = Range(target.range, in: body),
                  let attributedRange = Range(sourceRange, in: result)
            else { continue }
            result[attributedRange].link = target.url
        }
        return result
    }

    static func copiedCode(from url: URL) -> String? {
        guard url.scheme == copyCodeScheme, url.host == "copy" else { return nil }
        let code = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return code.isEmpty ? nil : code
    }

    fileprivate static func copyURL(for code: String) -> URL {
        var components = URLComponents()
        components.scheme = copyCodeScheme
        components.host = "copy"
        components.path = "/\(code)"
        return components.url!
    }

    private static func dataTargets(in body: String) -> [SMSRichTextTarget] {
        let checkingTypes = NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
        guard let detector = try? NSDataDetector(types: checkingTypes) else { return [] }
        let range = NSRange(body.startIndex..., in: body)

        return detector.matches(in: body, range: range).compactMap { match in
            if let url = match.url {
                return SMSRichTextTarget(range: match.range, action: .open(url))
            }
            if let phoneNumber = match.phoneNumber {
                let normalized = phoneNumber.filter { $0 == "+" || $0.isNumber }
                guard !normalized.isEmpty, let url = URL(string: "tel:\(normalized)") else {
                    return nil
                }
                return SMSRichTextTarget(range: match.range, action: .open(url))
            }
            return nil
        }
    }

    private static func verificationCodeTargets(in body: String) -> [SMSRichTextTarget] {
        VerificationCodeExtractor.extract(from: body).flatMap { code in
            var matches: [SMSRichTextTarget] = []
            var searchStart = body.startIndex
            while searchStart < body.endIndex,
                  let range = body.range(of: code, range: searchStart..<body.endIndex) {
                matches.append(SMSRichTextTarget(
                    range: NSRange(range, in: body),
                    action: .copyCode(code)
                ))
                searchStart = range.upperBound
            }
            return matches
        }
    }
}
