import Foundation

/// Classification of one framed AT line relative to a pending command.
enum ATLineClass: Equatable, Sendable {
    /// Successful final response (`OK`).
    case finalOK
    /// Failed final response carrying the raw error line.
    case finalError(String)
    /// Unsolicited result code that belongs to no command response.
    case urc
    /// The modem echoing the pending command back.
    case echo
    /// Ordinary response data line belonging to the pending command.
    case info
}

/// Classifies framed AT lines into final responses, URCs, command echo, and
/// response data. A pending command claims lines that answer it directly
/// (`AT+CREG?` owns `+CREG:`), so solicited responses are never misrouted as
/// URCs.
enum ATLineClassifier {
    /// Line prefixes the EC25 emits unsolicited.
    static let urcPrefixes: Set<String> = [
        "+CMTI:", "+CMT:", "+CDS:", "+CBM:", "+CLIP:", "+COLP:", "+CCWA:",
        "+CREG:", "+CGREG:", "+CEREG:", "+CTZV:", "+CTZE:", "+CTZR:",
        "+CIEV:", "+CLCC:", "+CCVM:", "+CCWE:", "+CSSI:", "+CSCON:",
        "+QIND:", "+QSIMSTAT:", "+QSIMDET:", "+SIM:", "+CFUN:", "^MODE:",
        "^RESET:", "^DSD:", "^BOOT:", "^DOWNLOAD:",
    ]

    /// Whole-line unsolicited tokens without a `+CMD:` prefix.
    static let urcTokens: Set<String> = [
        "RING", "NO CARRIER", "BUSY", "NO ANSWER", "DELAYED", "BLACKLISTED",
        "RDY", "SMS READY", "CALL READY", "POWERED DOWN",
    ]

    /// Tokens that are final result codes while a dial command is pending
    /// (TS 27.007 `ATD`) but unsolicited otherwise.
    private static let dialFailureTokens: Set<String> = [
        "NO CARRIER", "BUSY", "NO ANSWER", "DELAYED", "BLACKLISTED",
    ]

    /// Classifies one framed line. `pendingCommand` is the command awaiting a
    /// final response, or `nil` when no command is in flight.
    static func classify(line: String, pendingCommand: String?) -> ATLineClass {
        if line == "OK" { return .finalOK }
        if line == "ERROR"
            || line.hasPrefix("+CME ERROR:")
            || line.hasPrefix("+CMS ERROR:") {
            return .finalError(line)
        }

        if let pendingCommand {
            if line == pendingCommand { return .echo }

            if isDialCommand(pendingCommand), dialFailureTokens.contains(line) {
                return .finalError(line)
            }

            if let prefix = expectedResponsePrefix(for: pendingCommand), line.hasPrefix(prefix) {
                return .info
            }
        }

        if urcTokens.contains(line) || urcPrefixes.contains(where: line.hasPrefix) {
            return .urc
        }

        return .info
    }

    /// Derives the response prefix a command solicits: `AT+CREG?` and
    /// `AT+CMGL="ALL"` both own `+CREG:` / `+CMGL:` response lines. Basic
    /// commands (`AT`, `ATI`, `ATD...`) answer with plain text or finals only
    /// and return `nil`.
    static func expectedResponsePrefix(for command: String) -> String? {
        let normalized = command.trimmingCharacters(in: .whitespaces).uppercased()
        guard normalized.hasPrefix("AT"), normalized.count > 2 else { return nil }

        let body = normalized.dropFirst(2)
        guard let first = body.first, "+!%/^~&".contains(first) else { return nil }

        let separators: Set<Character> = ["=", "?"]
        let name = body.prefix { !separators.contains($0) }
        guard !name.isEmpty else { return nil }
        return name + ":"
    }

    private static func isDialCommand(_ command: String) -> Bool {
        command.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("ATD")
    }
}
