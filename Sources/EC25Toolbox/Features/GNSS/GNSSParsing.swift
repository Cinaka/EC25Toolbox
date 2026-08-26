import Foundation

/// Parsers for Quectel `+QGPSLOC`/`+QGPS` responses and standard NMEA
/// sentences. Everything is a pure function over response lines; unparsable
/// fields stay nil so the UI can distinguish "missing" from "zero".
enum GNSSParsing {
    // MARK: - +QGPS engine state

    /// Parses `+QGPS: <state>` from `AT+QGPS?`; true means the engine is
    /// already running (idempotent start), false means it is off.
    static func parseQGPSState(_ lines: [String]) -> Bool? {
        guard let line = lines.first(where: { $0.hasPrefix("+QGPS:") }) else { return nil }
        let value = line.dropFirst("+QGPS:".count).trimmingCharacters(in: .whitespaces)
        guard let first = value.split(separator: ",").first, let state = Int(first) else {
            return nil
        }
        return state != 0
    }

    // MARK: - +QGPSLOC

    /// Parses `+QGPSLOC: <UTC>,<lat>,<lon>,<hdop>,<alt>,<fix>,<cog>,<spkm>,<spkn>,<date>,<nsat>`.
    /// Coordinates accept both hemisphere form (`3150.7223N`) and decimal form
    /// (`31.84537` / `-117.19882`); returns nil when no position line exists.
    static func parseQGPSLOC(_ lines: [String]) -> GNSSFix? {
        guard let line = lines.first(where: { $0.hasPrefix("+QGPSLOC:") }) else { return nil }
        let fields = csvParts(String(line.dropFirst("+QGPSLOC:".count)))
        guard fields.count >= 11 else { return nil }

        let latitude = parseCoordinate(fields[safe: 1])
        let longitude = parseCoordinate(fields[safe: 2])
        return GNSSFix(
            utc: nonempty(fields[safe: 0]),
            latitude: latitude?.value,
            longitude: longitude?.value,
            latitudeRaw: latitude?.raw,
            longitudeRaw: longitude?.raw,
            hdop: fields[safe: 3].flatMap(Double.init),
            altitudeMeters: fields[safe: 4].flatMap(Double.init),
            fixType: fields[safe: 5].flatMap(Int.init),
            courseDegrees: fields[safe: 6].flatMap(Double.init),
            speedKmh: fields[safe: 7].flatMap(Double.init),
            speedKnots: fields[safe: 8].flatMap(Double.init),
            date: nonempty(fields[safe: 9]),
            satelliteCount: fields[safe: 10].flatMap(Int.init)
        )
    }

    /// Parses one coordinate field. Hemisphere form is `ddmm.mmmmH` (latitude,
    /// two degree digits) or `dddmm.mmmmH` (longitude, three); the split point
    /// is located by the leading digits before the last two of the integer
    /// part. South/west hemispheres negate the result.
    static func parseCoordinate(_ field: String?) -> (value: Double, raw: String)? {
        guard let raw = nonempty(field) else { return nil }
        if let hemisphere = raw.last, "NSEW".contains(hemisphere) {
            let digits = String(raw.dropLast())
            guard let dot = digits.firstIndex(of: "."),
                  digits.distance(from: digits.startIndex, to: dot) > 2 else {
                return nil
            }
            let minutesStart = digits.index(dot, offsetBy: -2)
            guard let degrees = Double(digits[..<minutesStart]),
                  let minutes = Double(digits[minutesStart...]) else {
                return nil
            }
            var value = degrees + minutes / 60.0
            if hemisphere == "S" || hemisphere == "W" { value = -value }
            return (value, raw)
        }
        guard let value = Double(raw) else { return nil }
        return (value, raw)
    }

    // MARK: - NMEA

    /// Extracts NMEA sentences (`$G...` lines) from an `AT+QGPSGNMEA`
    /// response. The modem may echo empty responses when the engine has no
    /// data yet; an empty result is not an error.
    static func parseQGPSGNMEASentences(_ lines: [String]) -> [String] {
        lines.filter { $0.hasPrefix("$") }
    }

    /// Combines RMC (position/course/speed, validity) and GGA (satellites,
    /// HDOP, altitude) sentences into one fix. Returns nil unless an RMC with
    /// a valid status or a GGA with a quality fix provides coordinates.
    static func fixFromNMEA(_ sentences: [String]) -> GNSSFix? {
        var rmcFix: RMCFix?
        var ggaFix: GGAFix?
        for sentence in sentences {
            if rmcFix == nil, let rmc = parseRMC(sentence) { rmcFix = rmc }
            if ggaFix == nil, let gga = parseGGA(sentence) { ggaFix = gga }
        }
        guard let rmc = rmcFix, rmc.valid else {
            // A GGA with a real quality flag alone can still carry position.
            guard let gga = ggaFix, (gga.quality ?? 0) > 0, gga.latitude != nil, gga.longitude != nil else {
                return nil
            }
            return GNSSFix(
                utc: gga.utc,
                latitude: gga.latitude?.value,
                longitude: gga.longitude?.value,
                latitudeRaw: gga.latitude?.raw,
                longitudeRaw: gga.longitude?.raw,
                hdop: gga.hdop,
                altitudeMeters: gga.altitudeMeters,
                satelliteCount: gga.satelliteCount
            )
        }
        guard rmc.latitude != nil, rmc.longitude != nil else { return nil }
        let knots = rmc.speedKnots
        return GNSSFix(
            utc: rmc.utc,
            latitude: rmc.latitude?.value,
            longitude: rmc.longitude?.value,
            latitudeRaw: rmc.latitude?.raw,
            longitudeRaw: rmc.longitude?.raw,
            hdop: ggaFix?.hdop,
            altitudeMeters: ggaFix?.altitudeMeters,
            courseDegrees: rmc.courseDegrees,
            speedKmh: knots.map { $0 * 1.852 },
            speedKnots: knots,
            date: rmc.date,
            satelliteCount: ggaFix?.satelliteCount
        )
    }

    /// Extracts the numeric `+CME ERROR: <n>` code; nil for verbose text
    /// (`AT+CMEE=2`) and non-CME errors.
    static func cmeErrorCode(in message: String) -> Int? {
        guard let range = message.range(of: "+CME ERROR:") else { return nil }
        let tail = message[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let first = tail.split(separator: " ").first, let code = Int(first) else {
            return nil
        }
        return code
    }

    /// True when the error means "engine running, no position yet" — CME 516
    /// in numeric mode or its verbose `AT+CMEE=2` phrasing. Never a source
    /// or operational failure.
    static func isNoPositionError(_ message: String) -> Bool {
        if cmeErrorCode(in: message) == 516 { return true }
        return message.contains("not fixed now") || message.contains("gps not fixed now")
    }

    /// Verifies the `*HH` XOR checksum of one NMEA sentence. Sentences
    /// without a checksum are accepted (some modules emit them raw).
    static func checksumValid(_ sentence: String) -> Bool {
        let trimmed = trimmed(sentence)
        guard trimmed.hasPrefix("$"), let star = trimmed.lastIndex(of: "*") else {
            return trimmed.hasPrefix("$")
        }
        let body = trimmed[trimmed.index(after: trimmed.startIndex)..<star]
        let expected = trimmed[trimmed.index(after: star)...]
        guard expected.count >= 2,
              let expectedValue = UInt8(expected.prefix(2), radix: 16) else { return false }
        var checksum: UInt8 = 0
        for byte in body.utf8 { checksum ^= byte }
        return checksum == expectedValue
    }

    struct RMCFix: Equatable, Sendable {
        var utc: String?
        var valid: Bool
        var latitude: (value: Double, raw: String)?
        var longitude: (value: Double, raw: String)?
        var speedKnots: Double?
        var courseDegrees: Double?
        var date: String?

        static func == (lhs: RMCFix, rhs: RMCFix) -> Bool {
            lhs.utc == rhs.utc && lhs.valid == rhs.valid
                && lhs.latitude?.value == rhs.latitude?.value
                && lhs.longitude?.value == rhs.longitude?.value
                && lhs.speedKnots == rhs.speedKnots
                && lhs.courseDegrees == rhs.courseDegrees
                && lhs.date == rhs.date
        }
    }

    /// Parses `$--RMC,time,status,lat,NS,lon,EW,speed,course,date,...`.
    static func parseRMC(_ sentence: String) -> RMCFix? {
        let fields = nmeaFields(sentence, type: "RMC")
        guard fields.count >= 9 else { return nil }
        let latitude = combineHemisphere(fields[safe: 2], fields[safe: 3])
        let longitude = combineHemisphere(fields[safe: 4], fields[safe: 5])
        return RMCFix(
            utc: nonempty(fields[safe: 0]),
            valid: fields[safe: 1] == "A",
            latitude: latitude,
            longitude: longitude,
            speedKnots: fields[safe: 6].flatMap(Double.init),
            courseDegrees: fields[safe: 7].flatMap(Double.init),
            date: nonempty(fields[safe: 8])
        )
    }

    struct GGAFix: Equatable, Sendable {
        var utc: String?
        var latitude: (value: Double, raw: String)?
        var longitude: (value: Double, raw: String)?
        var quality: Int?
        var satelliteCount: Int?
        var hdop: Double?
        var altitudeMeters: Double?

        static func == (lhs: GGAFix, rhs: GGAFix) -> Bool {
            lhs.utc == rhs.utc
                && lhs.latitude?.value == rhs.latitude?.value
                && lhs.longitude?.value == rhs.longitude?.value
                && lhs.quality == rhs.quality
                && lhs.satelliteCount == rhs.satelliteCount
                && lhs.hdop == rhs.hdop
                && lhs.altitudeMeters == rhs.altitudeMeters
        }
    }

    /// Parses `$--GGA,time,lat,NS,lon,EW,quality,nsat,hdop,alt,M,...`.
    static func parseGGA(_ sentence: String) -> GGAFix? {
        let fields = nmeaFields(sentence, type: "GGA")
        guard fields.count >= 10 else { return nil }
        return GGAFix(
            utc: nonempty(fields[safe: 0]),
            latitude: combineHemisphere(fields[safe: 1], fields[safe: 2]),
            longitude: combineHemisphere(fields[safe: 3], fields[safe: 4]),
            quality: fields[safe: 5].flatMap(Int.init),
            satelliteCount: fields[safe: 6].flatMap(Int.init),
            hdop: fields[safe: 7].flatMap(Double.init),
            altitudeMeters: fields[safe: 8].flatMap(Double.init)
        )
    }

    struct GSVSummary: Equatable, Sendable {
        var satellitesInView: Int
        /// Mean SNR across all satellites listed in this sentence group.
        var averageSNR: Double?
    }

    /// Parses one or more `$--GSV` sentences of the same group into a view
    /// summary. SNR fields are the 7th, 11th, 15th, 19th positions of each
    /// sentence (after the talker token).
    static func parseGSV(_ sentences: [String]) -> GSVSummary? {
        var inView: Int?
        var snrValues: [Double] = []
        for sentence in sentences {
            let fields = nmeaFields(sentence, type: "GSV")
            guard fields.count >= 3 else { continue }
            if inView == nil { inView = Int(fields[2]) }
            var index = 6
            while index < fields.count {
                if let snr = Double(fields[index]) { snrValues.append(snr) }
                index += 4
            }
        }
        guard let inView else { return nil }
        return GSVSummary(
            satellitesInView: inView,
            averageSNR: snrValues.isEmpty ? nil : snrValues.reduce(0, +) / Double(snrValues.count)
        )
    }

    // MARK: - Helpers

    /// Splits one NMEA sentence into fields after the talker+type token,
    /// verifying the checksum and matching the sentence type.
    private static func nmeaFields(_ sentence: String, type: String) -> [String] {
        let trimmed = trimmed(sentence)
        guard checksumValid(trimmed), trimmed.hasPrefix("$") else { return [] }
        var body = String(trimmed.dropFirst())
        if let star = body.lastIndex(of: "*") {
            body = String(body[..<star])
        }
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first, head.hasSuffix(type) else { return [] }
        return Array(parts.dropFirst())
    }

    /// NMEA splits coordinate and hemisphere into two CSV fields; rejoin them
    /// for the shared coordinate parser.
    private static func combineHemisphere(_ digits: String?, _ hemisphere: String?) -> (value: Double, raw: String)? {
        guard let digits = nonempty(digits), let hemisphere = nonempty(hemisphere) else { return nil }
        return parseCoordinate(digits + hemisphere)
    }

    private static func nonempty(_ field: String?) -> String? {
        guard let field else { return nil }
        let clean = trimmed(field)
        return clean.isEmpty ? nil : clean
    }
}
