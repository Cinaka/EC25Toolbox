import Foundation

private let messageStatus: [String: String] = [
    "0": "REC UNREAD",
    "1": "REC READ",
    "2": "STO UNSENT",
    "3": "STO SENT",
    "4": "ALL"
]

/// One modem listing entry before logical assembly. Concatenation metadata
/// is preserved so the logical layer can group segments; `rawPDU` keeps the
/// original payload for diagnostics and internal retention.
struct SMSSegment: Equatable {
    var storage: String
    var index: Int
    var status: String
    var outgoing: Bool
    var unread: Bool
    var sender: String
    /// Raw modem service timestamp `yy/MM/dd,HH:mm:ss±QQ`; never displayed.
    var date: String
    var body: String
    var binaryKind: BinarySMSKind?
    var concatenation: SMSConcatenation?
    /// PDU hex in PDU mode; nil for text-mode listings.
    var rawPDU: String?
}

/// Parses `AT+CMGL` output from a specific storage area in text mode. Each
/// entry becomes one segment; text mode exposes no concatenation header, so
/// every text-mode segment assembles as a single logical message.
func parseMessageList(_ lines: [String], storage: String) -> [SMSSegment] {
    var segments: [SMSSegment] = []
    var index = 0

    while index < lines.count {
        let line = lines[index]
        guard line.hasPrefix("+CMGL:") else {
            index += 1
            continue
        }

        let parts = csvParts(line.replacingOccurrences(of: "+CMGL:", with: ""))
        let messageIndex = Int(trimmed(parts[safe: 0] ?? "0")) ?? 0
        let statusToken = trimQuotes(parts[safe: 1] ?? "-")
        let status = messageStatus[statusToken] ?? statusToken
        let sender = UCS2.decode(trimQuotes(parts[safe: 2] ?? "-"))
        let date = trimQuotes(parts[safe: 4] ?? "-")
        var bodyLines: [String] = []

        index += 1
        while index < lines.count && !lines[index].hasPrefix("+CMGL:") {
            bodyLines.append(UCS2.decode(lines[index]))
            index += 1
        }

        let upper = status.uppercased()
        segments.append(
            SMSSegment(
                storage: storage,
                index: messageIndex,
                status: status,
                outgoing: upper.contains("STO") || upper.contains("SENT"),
                unread: upper.contains("UNREAD"),
                sender: sender,
                date: date,
                body: bodyLines.joined(separator: "\n"),
                binaryKind: nil,
                concatenation: nil,
                rawPDU: nil
            )
        )
    }

    return segments
}

/// Parses `AT+CMGL=4` output from PDU mode (`AT+CMGF=0`). Each entry is a
/// `+CMGL: <index>,<stat>,,<length>` header followed by one PDU hex line.
/// Malformed PDUs are skipped; decoded entries keep their concatenation
/// header and binary classification for the logical assembly layer.
func parsePDUMessageList(_ lines: [String], storage: String) -> [SMSSegment] {
    var segments: [SMSSegment] = []
    var index = 0

    while index < lines.count {
        let line = lines[index]
        guard line.hasPrefix("+CMGL:") else {
            index += 1
            continue
        }

        let parts = csvParts(line.replacingOccurrences(of: "+CMGL:", with: ""))
        let messageIndex = Int(trimmed(parts[safe: 0] ?? "0")) ?? 0
        let statusToken = trimQuotes(parts[safe: 1] ?? "-")
        let status = messageStatus[statusToken] ?? statusToken

        index += 1
        guard index < lines.count, !lines[index].hasPrefix("+CMGL:") else { continue }
        let pduHex = trimmed(lines[index])
        index += 1

        guard let decoded = try? SMSPDU.decode(pduHex) else { continue }
        let upper = status.uppercased()
        let binaryKind = BinarySMSClassifier.classify(decoded: decoded)
        segments.append(
            SMSSegment(
                storage: storage,
                index: messageIndex,
                status: status,
                outgoing: upper.contains("STO") || upper.contains("SENT"),
                unread: upper.contains("UNREAD"),
                sender: decoded.sender,
                date: decoded.date,
                body: binaryKind == nil ? decoded.text : "",
                binaryKind: binaryKind,
                concatenation: decoded.header?.concatenation,
                rawPDU: pduHex
            )
        )
    }

    return segments
}
