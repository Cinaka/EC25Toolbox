import CryptoKit
import Foundation

/// Legacy QDC507/MDM9x07 QADBKEY challenge handling.
///
/// Only the documented eight-decimal challenge form is accepted. The derived
/// response is transient: callers must send it through `sendUnlogged` and must
/// never persist it or include it in diagnostics.
enum QDC507ADBKey {
    private static let protocolSecret = Data("SH_adb_quectel".utf8)
    private static let magic = Data("$1$".utf8)
    private static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

    static func parseChallenge(_ lines: [String]) -> String? {
        let matches = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("+QADBKEY:") else { return nil }
            let value = trimmed.dropFirst("+QADBKEY:".count)
                .trimmingCharacters(in: .whitespaces)
            guard value.count == 8, value.allSatisfy(\.isNumber) else { return nil }
            return value
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func deriveResponse(challenge: String) throws -> String {
        guard challenge.count == 8, challenge.allSatisfy(\.isNumber) else {
            throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.qadbkey_challenge"))
        }
        let salt = Data(challenge.utf8)
        let encoded = md5Crypt(password: protocolSecret, salt: salt)
        guard encoded.count >= 15 else {
            throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.qadbkey_derive"))
        }
        return String(encoded.prefix(15))
    }

    private static func md5Crypt(password: Data, salt: Data) -> String {
        var initial = Data()
        initial.append(password)
        initial.append(magic)
        initial.append(salt)

        var alternate = Data()
        alternate.append(password)
        alternate.append(salt)
        alternate.append(password)
        let alternateDigest = md5(alternate)
        var remaining = password.count
        while remaining > 0 {
            initial.append(alternateDigest.prefix(min(16, remaining)))
            remaining -= 16
        }

        var count = password.count
        while count > 0 {
            initial.append(count & 1 == 1 ? Data([0]) : password.prefix(1))
            count >>= 1
        }
        var digest = md5(initial)

        for round in 0..<1_000 {
            var current = Data()
            current.append(round & 1 == 1 ? password : digest)
            if round % 3 != 0 { current.append(salt) }
            if round % 7 != 0 { current.append(password) }
            current.append(round & 1 == 1 ? digest : password)
            digest = md5(current)
        }

        var encoded = ""
        appendBase64(&encoded, digest[0], digest[6], digest[12], count: 4)
        appendBase64(&encoded, digest[1], digest[7], digest[13], count: 4)
        appendBase64(&encoded, digest[2], digest[8], digest[14], count: 4)
        appendBase64(&encoded, digest[3], digest[9], digest[15], count: 4)
        appendBase64(&encoded, digest[4], digest[10], digest[5], count: 4)
        appendBase64(&encoded, 0, 0, digest[11], count: 2)
        return encoded
    }

    private static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    private static func appendBase64(
        _ output: inout String,
        _ high: UInt8,
        _ middle: UInt8,
        _ low: UInt8,
        count: Int
    ) {
        var value = UInt32(high) << 16 | UInt32(middle) << 8 | UInt32(low)
        for _ in 0..<count {
            output.append(Character(UnicodeScalar(alphabet[Int(value & 0x3f)])))
            value >>= 6
        }
    }
}
