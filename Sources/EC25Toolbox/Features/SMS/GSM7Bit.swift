import Foundation

/// GSM 03.38 default alphabet codec. SMS user data packs 7-bit characters
/// into octets; the codec also handles the escape-based extension table and
/// the fill-bit shift used when a user data header precedes the text.
enum GSM7Bit {
    private static let escapeCharacter: Character = "\u{1B}"

    // Indexed by septet value 0x00...0x7F. Position 0x1B is the extension
    // escape and never emitted directly.
    private static let defaultAlphabet: [Character] = [
        "@", "£", "$", "¥", "è", "é", "ù", "ì", "ò", "Ç", "\n", "Ø", "ø", "\r", "Å", "å",
        "Δ", "_", "Φ", "Γ", "Λ", "Ω", "Π", "Ψ", "Σ", "Θ", "Ξ", escapeCharacter, "Æ", "æ", "ß", "É",
        " ", "!", "\"", "#", "¤", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
        "¡", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
        "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "Ä", "Ö", "Ñ", "Ü", "§",
        "¿", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
        "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "ä", "ö", "ñ", "ü", "à",
    ]

    // Extension table, indexed by the septet that follows 0x1B.
    private static let extensionAlphabet: [UInt8: Character] = [
        0x0A: "\u{0C}", 0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\",
        0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|", 0x65: "€",
    ]

    private static let encodeTable: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (value, character) in defaultAlphabet.enumerated() where character != escapeCharacter {
            table[character] = UInt8(value)
        }
        return table
    }()

    /// True when every character fits the default alphabet or its extension.
    static func canEncode(_ text: String) -> Bool {
        text.allSatisfy { septetCost(of: $0) != nil }
    }

    /// Septets consumed by one character: 1 for the default alphabet, 2 for
    /// escape-based extension characters, nil when unrepresentable.
    static func septetCost(of character: Character) -> Int? {
        if encodeTable[character] != nil { return 1 }
        if extensionAlphabet.values.contains(character) { return 2 }
        return nil
    }

    /// Packs characters into septets, least-significant character first.
    /// Returns nil when a character has no GSM 7-bit representation.
    static func pack(_ text: String) -> (octets: [UInt8], characterCount: Int)? {
        var septets: [UInt8] = []
        for character in text {
            if let value = encodeTable[character] {
                septets.append(value)
            } else if let value = extensionAlphabet.first(where: { $0.value == character })?.key {
                septets.append(0x1B)
                septets.append(value)
            } else {
                return nil
            }
        }
        return (packSeptets(septets), septets.count)
    }

    /// Unpacks `characterCount` septets, skipping `fillBits` bits of padding
    /// that follow a user data header. The count covers every septet read,
    /// including escape prefixes, matching the PDU's TP-UDL semantics.
    static func unpack(_ octets: [UInt8], characterCount: Int, fillBits: Int = 0) -> String {
        guard characterCount > 0, !octets.isEmpty else { return "" }
        var characters: [Character] = []
        var bitCursor = fillBits
        var septetsRead = 0
        var escaped = false
        while septetsRead < characterCount {
            let byteIndex = bitCursor / 8
            guard byteIndex < octets.count else { break }
            let shift = bitCursor % 8
            var value = UInt16(octets[byteIndex]) >> shift
            if byteIndex + 1 < octets.count, shift > 1 {
                value |= UInt16(octets[byteIndex + 1]) << (8 - shift)
            }
            let septet = UInt8(value & 0x7F)
            bitCursor += 7
            septetsRead += 1

            if escaped {
                if let character = extensionAlphabet[septet] {
                    characters.append(character)
                } else {
                    // Lone escape: render as a space per 03.38 guidance.
                    characters.append(" ")
                }
                escaped = false
            } else if septet == 0x1B {
                escaped = true
            } else {
                characters.append(defaultAlphabet[Int(septet)])
            }
        }
        return String(characters)
    }

    private static func packSeptets(_ septets: [UInt8]) -> [UInt8] {
        var octets: [UInt8] = []
        var buffer = 0
        var bitCount = 0
        for septet in septets {
            buffer |= Int(septet) << bitCount
            bitCount += 7
            while bitCount >= 8 {
                octets.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                bitCount -= 8
            }
        }
        if bitCount > 0 {
            octets.append(UInt8(buffer & 0xFF))
        }
        return octets
    }
}
