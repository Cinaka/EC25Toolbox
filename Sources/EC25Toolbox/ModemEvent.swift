import Foundation

/// Domain events surfaced by modem transports, derived from unsolicited AT
/// output and transport lifecycle changes.
enum ModemEvent: Equatable, Codable, Sendable {
    /// A RING, with caller identification from `+CLIP` when available.
    case incomingCall(number: String?)
    /// `+CLIP` arrived but carried no usable number: the network explicitly
    /// withheld the caller identity (distinct from a bare RING, which simply
    /// precedes CLIP). R12.
    case clipWithoutNumber
    /// A call-related state change, e.g. `+CLCC`, `NO CARRIER`, `BUSY`.
    case callState(String)
    /// A new SMS stored on the module (`+CMTI`).
    case smsArrived(storage: String, index: Int)
    /// A SIM status indication, e.g. `+SIM`, `+QSIMSTAT`, `+CIEV`.
    case simStatus(String)
    /// The transport session ended; carries the reason when known.
    case disconnected(reason: String?)
    /// The module restarted or reported a boot banner.
    case moduleRestarted
    /// One sentence read from the host Mac's independent USB NMEA endpoint
    /// and relayed to a paired remote client.
    case gnssNMEA(String)

    /// Maps one unsolicited AT line to an event, or `nil` for lines that
    /// carry no domain meaning yet.
    static func fromURC(_ line: String) -> ModemEvent? {
        if line == "RING" {
            return .incomingCall(number: nil)
        }
        if line.hasPrefix("+CLIP:") {
            // An empty/unquoted number field means the caller withheld their
            // identity — a different meaning than a bare RING still merging.
            guard let number = firstQuotedField(in: line) else {
                return .clipWithoutNumber
            }
            return .incomingCall(number: number)
        }
        if line.hasPrefix("+CMTI:") {
            // +CMTI: "ME",7 — the storage is quoted in the first field and
            // the index follows as the second comma-separated part.
            let fields = csvParts(line)
            guard fields.count > 1,
                  let storage = firstQuotedField(in: line),
                  let index = Int(trimmed(fields[1])) else {
                return nil
            }
            return .smsArrived(storage: storage, index: index)
        }
        if line == "NO CARRIER" || line == "BUSY" || line == "NO ANSWER"
            || line.hasPrefix("+CLCC:") || line.hasPrefix("+CCWA:") {
            return .callState(line)
        }
        if line.hasPrefix("+SIM:") || line.hasPrefix("+QSIMSTAT:")
            || line.hasPrefix("+QSIMDET:") || line.hasPrefix("+CIEV:") {
            return .simStatus(line)
        }
        if line == "POWERED DOWN" || line.hasPrefix("^RESET:") || line == "RDY"
            || line == "SMS READY" || line == "CALL READY" {
            return .moduleRestarted
        }
        return nil
    }

    /// Returns the contents of the first double-quoted field, or `nil` when
    /// the line has no non-empty quoted field.
    private static func firstQuotedField(in line: String) -> String? {
        guard let start = line.firstIndex(of: "\"") else { return nil }
        let remainder = line[line.index(after: start)...]
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        let value = String(remainder[..<end])
        return value.isEmpty ? nil : value
    }
}
