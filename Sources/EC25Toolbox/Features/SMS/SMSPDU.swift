import Foundation

/// Concatenation info from a user data header (IEI 0x00 or 0x08).
struct SMSConcatenation: Equatable, Sendable {
    var reference: UInt16
    var total: Int
    var sequence: Int
}

/// Parsed user data header. `length` counts every header octet including the
/// UDHL octet itself, which the 7-bit fill-bit calculation relies on.
struct SMSUserDataHeader: Equatable, Sendable {
    var concatenation: SMSConcatenation?
    var destinationPort: UInt16?
    var sourcePort: UInt16?
    var length: Int

    /// Header bytes for an 8-bit-reference concatenation header, UDHL first.
    static func concatenationBytes(reference: UInt8, total: Int, sequence: Int) -> [UInt8] {
        [0x05, 0x00, 0x03, reference, UInt8(total), UInt8(sequence)]
    }
}

enum SMSAlphabet: Equatable, Sendable {
    case gsm7
    case octet
    case ucs2
    case reserved
}

/// One decoded SMS-DELIVER or SMS-SUBMIT PDU.
struct DecodedSMS: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case deliver
        case submit
    }

    var direction: Direction
    var sender: String
    /// Modem-style service timestamp `yy/MM/dd,HH:mm:ss±zz`; `-` for SUBMIT.
    var date: String
    var pid: UInt8
    var dcs: UInt8
    var alphabet: SMSAlphabet
    var header: SMSUserDataHeader?
    /// Decoded text; empty for binary payloads.
    var text: String
    /// Raw 8-bit payload when the alphabet is not textual.
    var binary: Data?
}

enum SMSPDUError: Error, Equatable {
    case invalidHex
    case truncated
    case unsupportedMessageType(Int)
}

/// SMS-DELIVER/SUBMIT PDU codec for `AT+CMGF=0` listings and CMGS submits.
enum SMSPDU {
    // MARK: - Decoding

    static func decode(_ hex: String) throws -> DecodedSMS {
        let bytes = try octets(from: hex)
        var cursor = 0

        let smscLength = try byte(bytes, &cursor)
        guard smscLength == 0 || bytes.count >= 1 + Int(smscLength) else {
            throw SMSPDUError.truncated
        }
        cursor += Int(smscLength)

        let firstOctet = try byte(bytes, &cursor)
        let mti = Int(firstOctet & 0x03)
        let hasUDH = (firstOctet & 0x40) != 0

        let direction: DecodedSMS.Direction
        var sender: String
        var date = "-"
        switch mti {
        case 0:
            direction = .deliver
            sender = try decodeAddress(bytes, &cursor)
        case 1:
            direction = .submit
            _ = try byte(bytes, &cursor) // TP-MR
            sender = try decodeAddress(bytes, &cursor)
        default:
            throw SMSPDUError.unsupportedMessageType(mti)
        }

        let pid = try byte(bytes, &cursor)
        let dcs = try byte(bytes, &cursor)

        switch direction {
        case .deliver:
            date = try decodeTimestamp(bytes, &cursor)
        case .submit:
            let vpf = Int((firstOctet >> 3) & 0x03)
            let vpOctets = vpf == 0 ? 0 : (vpf == 2 ? 1 : 7)
            guard bytes.count >= cursor + vpOctets else { throw SMSPDUError.truncated }
            cursor += vpOctets
        }

        let udl = Int(try byte(bytes, &cursor))
        let userData = Array(bytes[cursor...])

        var header: SMSUserDataHeader?
        var payload = userData
        if hasUDH {
            let parsed = try parseUserDataHeader(userData)
            header = parsed
            payload = Array(userData.dropFirst(parsed.length))
        }

        let alphabet = Self.alphabet(for: dcs)
        var text = ""
        var binary: Data?
        switch alphabet {
        case .gsm7:
            let headerSeptets = header.map { ($0.length * 8 + 6) / 7 } ?? 0
            let fillBits = header.map { (7 - ($0.length * 8) % 7) % 7 } ?? 0
            let characterCount = max(0, udl - headerSeptets)
            text = GSM7Bit.unpack(payload, characterCount: characterCount, fillBits: fillBits)
        case .ucs2:
            text = decodeUCS2(payload)
        case .octet, .reserved:
            binary = Data(payload)
        }

        return DecodedSMS(
            direction: direction,
            sender: sender,
            date: date,
            pid: pid,
            dcs: dcs,
            alphabet: alphabet,
            header: header,
            text: text,
            binary: binary
        )
    }

    static func alphabet(for dcs: UInt8) -> SMSAlphabet {
        let group = dcs >> 4
        if group == 0xF {
            return (dcs & 0x04) != 0 ? .octet : .gsm7
        }
        if group == 0xC || group == 0xD {
            return .gsm7 // message-waiting indicator groups are 7-bit
        }
        if group == 0xE {
            return .ucs2
        }
        switch (dcs >> 2) & 0x03 {
        case 0: return .gsm7
        case 1: return .octet
        case 2: return .ucs2
        default: return .reserved
        }
    }

    // MARK: - Encoding (SMS-SUBMIT)

    /// Encodes a single SMS-SUBMIT PDU. Returns the hex string and the octet
    /// length `AT+CMGS=<length>` expects (everything after the SMSC octet).
    /// Returns nil when the text fits neither GSM 7-bit nor UCS2.
    static func encodeSubmit(
        destination: String,
        text: String,
        messageReference: UInt8,
        headerOctets: [UInt8] = []
    ) -> (pdu: String, length: Int)? {
        var bytes: [UInt8] = [0x00] // default SMSC
        bytes.append(headerOctets.isEmpty ? 0x11 : 0x11 | 0x40)
        bytes.append(messageReference)
        bytes.append(contentsOf: encodeAddress(destination))
        bytes.append(0x00) // TP-PID

        let dcs: UInt8
        let userData: [UInt8]
        let udl: Int
        if let packed = GSM7Bit.pack(text) {
            dcs = 0x00
            if headerOctets.isEmpty {
                userData = packed.octets
                udl = packed.characterCount
            } else {
                let headerLength = headerOctets.count // includes UDHL octet
                let fillBits = (7 - (headerLength * 8) % 7) % 7
                userData = headerOctets + shift(packed.octets, by: fillBits)
                udl = ((headerLength * 8) + 6) / 7 + packed.characterCount
            }
        } else {
            dcs = 0x08
            let encoded = Array(text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
            userData = headerOctets + encoded
            udl = userData.count
        }

        guard udl <= 255, userData.count <= 140 else { return nil }
        bytes.append(dcs)
        bytes.append(0xA7) // TP-VP relative, four days
        bytes.append(UInt8(udl))
        bytes.append(contentsOf: userData)

        return (bytes.map { String(format: "%02X", $0) }.joined(), bytes.count - 1)
    }

    /// Splits `text` into submit PDUs, adding a concatenation UDH when more
    /// than one PDU is required.
    static func encodeConcatSubmit(
        destination: String,
        text: String,
        referenceSeed: UInt8
    ) -> [(pdu: String, length: Int)] {
        let isGSM = GSM7Bit.canEncode(text)
        let singleLimit = isGSM ? 160 : 70
        if text.count <= singleLimit, let single = encodeSubmit(
            destination: destination,
            text: text,
            messageReference: referenceSeed
        ) {
            return [single]
        }

        let chunkBudget = isGSM ? 153 : 67
        var chunks: [String] = []
        var current = ""
        var currentCost = 0
        for character in text {
            // GSM extension characters cost two septets; UTF-16 supplementary
            // characters cost two units. Both must fit one chunk.
            let cost = isGSM ? (GSM7Bit.septetCost(of: character) ?? 2) : (character.utf16.count)
            if currentCost + cost > chunkBudget, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentCost = 0
            }
            current.append(character)
            currentCost += cost
        }
        if !current.isEmpty { chunks.append(current) }
        guard chunks.count <= 255 else { return [] }

        return chunks.enumerated().compactMap { position, chunk in
            encodeSubmit(
                destination: destination,
                text: chunk,
                messageReference: referenceSeed &+ UInt8(position),
                headerOctets: SMSUserDataHeader.concatenationBytes(
                    reference: referenceSeed,
                    total: chunks.count,
                    sequence: position + 1
                )
            )
        }
    }

    // MARK: - Field helpers

    private static func octets(from hex: String) throws -> [UInt8] {
        let cleaned = trimmed(hex)
        guard cleaned.count.isMultiple(of: 2), !cleaned.isEmpty,
              cleaned.allSatisfy(\.isHexDigit) else {
            throw SMSPDUError.invalidHex
        }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let value = UInt8(cleaned[index..<next], radix: 16) else {
                throw SMSPDUError.invalidHex
            }
            bytes.append(value)
            index = next
        }
        return bytes
    }

    private static func byte(_ bytes: [UInt8], _ cursor: inout Int) throws -> UInt8 {
        guard cursor < bytes.count else { throw SMSPDUError.truncated }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    private static func decodeAddress(_ bytes: [UInt8], _ cursor: inout Int) throws -> String {
        let digitCount = Int(try byte(bytes, &cursor))
        let tonNpi = try byte(bytes, &cursor)
        let typeOfNumber = tonNpi & 0x70
        // Alphanumeric addresses pack septets, not semi-octet digits.
        let octetCount = typeOfNumber == 0x50 ? (digitCount * 7 + 7) / 8 : (digitCount + 1) / 2
        guard bytes.count >= cursor + octetCount else { throw SMSPDUError.truncated }
        let raw = Array(bytes[cursor..<cursor + octetCount])
        cursor += octetCount

        if typeOfNumber == 0x50 {
            return GSM7Bit.unpack(raw, characterCount: digitCount)
        }
        var digits = ""
        for octet in raw {
            digits.append(String(format: "%X", octet & 0x0F))
            digits.append(String(format: "%X", octet >> 4))
        }
        digits = String(digits.prefix(digitCount))
        if digits.hasSuffix("F") { digits.removeLast() }
        return typeOfNumber == 0x10 ? "+" + digits : digits
    }

    private static func decodeTimestamp(_ bytes: [UInt8], _ cursor: inout Int) throws -> String {
        guard bytes.count >= cursor + 7 else { throw SMSPDUError.truncated }
        func bcd(_ octet: UInt8) -> Int { Int(octet & 0x0F) * 10 + Int(octet >> 4) }
        let year = bcd(bytes[cursor])
        let month = bcd(bytes[cursor + 1])
        let day = bcd(bytes[cursor + 2])
        let hour = bcd(bytes[cursor + 3])
        let minute = bcd(bytes[cursor + 4])
        let second = bcd(bytes[cursor + 5])
        let zoneOctet = bytes[cursor + 6]
        let quarters = bcd(zoneOctet & 0xF7)
        let sign = (zoneOctet & 0x08) != 0 ? "-" : "+"
        cursor += 7
        return String(
            format: "%02d/%02d/%02d,%02d:%02d:%02d%@%02d",
            year, month, day, hour, minute, second, sign, quarters
        )
    }

    private static func parseUserDataHeader(_ userData: [UInt8]) throws -> SMSUserDataHeader {
        guard let udhl = userData.first, userData.count >= Int(udhl) + 1 else {
            throw SMSPDUError.truncated
        }
        var header = SMSUserDataHeader(length: Int(udhl) + 1)
        var cursor = 1
        let end = Int(udhl) + 1
        while cursor + 2 <= end {
            let iei = userData[cursor]
            let length = Int(userData[cursor + 1])
            guard cursor + 2 + length <= end else { break }
            let data = userData[(cursor + 2)..<(cursor + 2 + length)]
            switch (iei, length) {
            case (0x00, 3):
                header.concatenation = SMSConcatenation(
                    reference: UInt16(data[data.startIndex]),
                    total: Int(data[data.startIndex + 1]),
                    sequence: Int(data[data.startIndex + 2])
                )
            case (0x08, 4):
                header.concatenation = SMSConcatenation(
                    reference: UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1]),
                    total: Int(data[data.startIndex + 2]),
                    sequence: Int(data[data.startIndex + 3])
                )
            case (0x04, 2):
                header.destinationPort = UInt16(data[data.startIndex])
                header.sourcePort = UInt16(data[data.startIndex + 1])
            case (0x05, 4):
                header.destinationPort = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
                header.sourcePort = UInt16(data[data.startIndex + 2]) << 8 | UInt16(data[data.startIndex + 3])
            default:
                break // unknown IEI: read-only, skip
            }
            cursor += 2 + length
        }
        return header
    }

    private static func decodeUCS2(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        var units: [UInt16] = []
        var index = 0
        while index + 1 < bytes.count {
            units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Shifts packed septets right by `fillBits` so the UDH ends on a septet
    /// boundary, as required for 7-bit user data with a header.
    private static func shift(_ octets: [UInt8], by fillBits: Int) -> [UInt8] {
        guard fillBits > 0 else { return octets }
        var shifted: [UInt8] = []
        var carry = 0
        for octet in octets {
            shifted.append(UInt8((carry | Int(octet) << fillBits) & 0xFF))
            carry = Int(octet) >> (8 - fillBits)
        }
        if carry > 0 {
            shifted.append(UInt8(carry))
        }
        return shifted
    }

    private static func encodeAddress(_ destination: String) -> [UInt8] {
        let international = destination.hasPrefix("+")
        let digits = destination.filter(\.isNumber)
        var bytes: [UInt8] = [UInt8(digits.count), international ? 0x91 : 0x81]
        var padded = digits
        if padded.count % 2 != 0 { padded.append("F") }
        var index = padded.startIndex
        while index < padded.endIndex {
            let next = padded.index(index, offsetBy: 2)
            let pair = padded[index..<next]
            let low = UInt8(String(pair.last!), radix: 16) ?? 0xF
            let high = UInt8(String(pair.first!), radix: 16) ?? 0xF
            bytes.append(low << 4 | high)
            index = next
        }
        return bytes
    }
}
