import Foundation

private let usbNetworkMode: [String: String] = [
    "0": "QMI",
    "1": "ECM",
    "2": "MBIM",
    "3": "RNDIS"
]

/// Aggregated temperature values parsed from `AT+QTEMP`.
struct TemperatureParse {
    var all: String
    var average: String
}

/// Parses ICCID from Quectel `AT+QCCID` output or a plain fallback line.
func parseICCID(_ lines: [String]) -> String {
    if let prefixed = firstLine(lines, containing: "+QCCID:") {
        return trimQuotes(prefixed.replacingOccurrences(of: "+QCCID:", with: ""))
    }
    return firstNonCommandLine(lines) ?? "-"
}

/// Extracts a simple value from a prefixed AT response line.
func parsePrefixed(_ lines: [String], prefix: String) -> String {
    guard let line = firstLine(lines, containing: prefix) else { return "-" }
    return trimQuotes(line.replacingOccurrences(of: prefix, with: ""))
}

/// Parses own-number storage from `AT+CNUM`.
func parseOwnNumber(_ lines: [String]) -> String {
    guard let line = firstLine(lines, containing: "+CNUM:") else { return "-" }
    let parts = csvParts(line.replacingOccurrences(of: "+CNUM:", with: ""))
    return normalizedOwnNumber(parts[safe: 1])
}

/// Parses the own-number phonebook (`AT+CPBR`) when `AT+CNUM` is blank.
func parseOwnNumberPhonebook(_ lines: [String]) -> String {
    for line in lines where line.contains("+CPBR:") {
        let parts = csvParts(line.replacingOccurrences(of: "+CPBR:", with: ""))
        let number = normalizedOwnNumber(parts[safe: 1])
        if number != "-" {
            return number
        }
    }
    return "-"
}

/// Extracts the supported phonebook index range from `AT+CPBR=?`.
func parsePhonebookIndexRange(_ lines: [String]) -> ClosedRange<Int>? {
    guard let line = firstLine(lines, containing: "+CPBR:"),
          let open = line.firstIndex(of: "("),
          let close = line[open...].firstIndex(of: ")") else { return nil }

    let rangeText = line[line.index(after: open)..<close]
    let bounds = rangeText.split(separator: "-", maxSplits: 1).compactMap {
        Int(trimmed(String($0)))
    }
    guard bounds.count == 2, bounds[0] <= bounds[1] else { return nil }
    return bounds[0]...bounds[1]
}

/// Parses the phonebook storage list advertised by `AT+CPBS=?`.
func parsePhonebookStorages(_ lines: [String]) -> [String] {
    guard let line = firstLine(lines, containing: "+CPBS:"),
          let open = line.firstIndex(of: "("),
          let close = line[open...].firstIndex(of: ")") else { return [] }
    return csvParts(String(line[line.index(after: open)..<close]))
        .map { trimQuotes($0) }
        .filter { !$0.isEmpty }
}

/// Parses the currently selected phonebook storage and fill level from
/// `AT+CPBS?`. Some firmwares omit the slot counters, so they stay optional.
func parsePhonebookSelection(_ lines: [String]) -> (storage: String, used: Int?, total: Int?)? {
    guard let line = firstLine(lines, containing: "+CPBS:") else { return nil }
    let parts = csvParts(line.replacingOccurrences(of: "+CPBS:", with: ""))
    let storage = trimQuotes(parts[safe: 0])
    guard !storage.isEmpty else { return nil }
    return (storage, Int(trimmed(parts[safe: 1])), Int(trimmed(parts[safe: 2])))
}

/// Parses the maximum number and name lengths that follow the record range in
/// `AT+CPBR=?` (e.g. `+CPBR: (1-250),40,14`). The tail starts with a comma,
/// so empty leading fields are dropped before reading the limits.
func parsePhonebookRecordLimits(_ lines: [String]) -> (numberLength: Int?, nameLength: Int?)? {
    guard let line = firstLine(lines, containing: "+CPBR:"),
          let close = line.firstIndex(of: ")") else { return nil }
    let fields = csvParts(String(line[line.index(after: close)...]))
        .drop(while: { trimmed($0).isEmpty })
        .prefix(2)
        .map { Int(trimmed($0)) }
    guard fields.contains(where: { $0 != nil }) else { return nil }
    return (fields[safe: 0] ?? nil, fields[safe: 1] ?? nil)
}

private func normalizedOwnNumber(_ value: String?) -> String {
    // The number field in CNUM/CPBR remains a dial string even when CSCS is
    // UCS2. Decoding an all-digit number as hexadecimal can corrupt valid
    // 8/12/16-digit values, so only trim the quoted AT field here.
    let number = trimQuotes(value)
    return number.isEmpty ? "-" : number
}

/// Parses module temperature readings and calculates a simple average.
func parseTemperatures(_ lines: [String]) -> TemperatureParse {
    guard let line = firstLine(lines, containing: "+QTEMP:") else {
        return TemperatureParse(all: "-", average: "-")
    }
    let numbers = csvParts(line.replacingOccurrences(of: "+QTEMP:", with: ""))
        .map { trimQuotes($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .compactMap(Int.init)
        .filter { $0 > -50 && $0 < 200 }
    guard !numbers.isEmpty else { return TemperatureParse(all: "-", average: "-") }
    let average = Int(round(Double(numbers.reduce(0, +)) / Double(numbers.count)))
    return TemperatureParse(all: numbers.map(String.init).joined(separator: " / ") + " °C", average: "\(average) °C")
}

/// Parses Quectel `usbnet` configuration into the displayed network mode.
func parseUSBNetworkMode(_ lines: [String]) -> String {
    guard let line = firstLine(lines, containing: "+QCFG:") else { return "-" }
    let parts = csvParts(line.replacingOccurrences(of: "+QCFG:", with: ""))
    let mode = trimmed(parts.last)
    return "\(localized(usbNetworkMode[mode] ?? "common.unknown")) (\(mode))"
}

/// Parses configured PDP/APN profiles from `AT+CGDCONT?`.
func parseAPNProfiles(_ lines: [String]) -> [APNProfile] {
    lines
        .filter { $0.contains("+CGDCONT:") }
        .map { line in
            let parts = csvParts(line.replacingOccurrences(of: "+CGDCONT:", with: ""))
            return APNProfile(
                cid: trimmed(parts[safe: 0] ?? "-"),
                type: trimQuotes(parts[safe: 1] ?? "-"),
                apn: trimQuotes(parts[safe: 2] ?? "-")
            )
        }
}

/// Chooses the primary APN profile displayed in the settings pane.
func currentAPN(_ profiles: [APNProfile]) -> String {
    let profile = profiles.first { $0.cid == "1" } ?? profiles.first
    guard let profile, profile.apn != "-" && !profile.apn.isEmpty else { return "-" }
    return "\(profile.apn) (\(profile.type))"
}

/// Joins matching prefixed response lines into a compact multiline display value.
func compactLines(_ lines: [String], prefix: String) -> String {
    let matched = lines.filter { $0.contains(prefix) }
    guard !matched.isEmpty else { return "-" }
    return matched.map { trimmed($0.replacingOccurrences(of: prefix, with: "")) }.joined(separator: "\n")
}

/// Formats the current date in the modem/SMS-style timestamp used by sent-message logs.
func modemDateNow() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yy/MM/dd,HH:mm:ss"
    return formatter.string(from: Date())
}

/// Sanitizes a dialable number or service code before sending it to the modem.
func sanitizedDialNumber(_ value: String) -> String {
    value.filter { character in
        character.isNumber || character == "+" || character == "*" || character == "#"
    }
}

/// Parses the module auto-answer configuration from an `ATS0?` response
/// (`+S0: <rings>`). Returns nil when the modem did not report a value (R8).
func parseAutoAnswerRings(_ lines: [String]) -> Int? {
    for line in lines where line.hasPrefix("+S0:") {
        let raw = line.dropFirst("+S0:".count).trimmingCharacters(in: .whitespaces)
        if let rings = Int(raw) { return rings }
    }
    return nil
}
