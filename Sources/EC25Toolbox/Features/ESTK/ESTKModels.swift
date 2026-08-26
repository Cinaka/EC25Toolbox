import Foundation

/// Defaults shared by the eSTK UI and lpac process bridge.
enum ESTKDefaults {
    static let isdRAID = "A0000005591010FFFFFFFF8900000100"
    static let fiveBerISDRAID = "A0000005591010FFFFFFFF8900050500"
    static let esimMeISDRAID = "A0000005591010000000008900000300"
    static let xesimISDRAID = "A0000005591010FFFFFFFF8900000177"
    /// OpenEUICC's most-compatible default for removable eUICCs. Smaller ES10x
    /// APDUs avoid dropped BPP segments on modem/UICC bridges while retaining
    /// acceptable throughput.
    static let es10xMSS = 63
}

/// Modem-side APDU transport selected after probing the available AT commands.
enum ESTKAPDUBackend: String, Equatable {
    case logicalChannel = "AT+CCHO / AT+CGLA / AT+CCHC"
    case csim = "AT+CSIM"
}

/// Cached result of probing the current SIM for the ISD-R eUICC applet.
enum ESTKAvailability: Equatable {
    case unknown
    case checking
    case available
    case unavailable
}

/// One eSIM profile returned by `lpac profile list`.
struct ESTKProfile: Decodable, Equatable, Identifiable {
    var id: String { [iccid, isdpAid, profileName].joined(separator: "|") }
    var iccid: String
    var isdpAid: String
    var profileState: String
    var profileNickname: String?
    var serviceProviderName: String
    var profileName: String
    var profileClass: String
    var iconType: String
    var icon: String?

    var operationIdentifier: String {
        firstPresent(iccid) ?? isdpAid
    }

    private enum CodingKeys: String, CodingKey {
        case iccid, isdpAid, profileState, profileNickname
        case serviceProviderName, profileName, profileClass, iconType, icon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iccid = try container.decodeIfPresent(String.self, forKey: .iccid) ?? ""
        isdpAid = try container.decodeIfPresent(String.self, forKey: .isdpAid) ?? ""
        profileState = try container.decodeIfPresent(String.self, forKey: .profileState) ?? ""
        profileNickname = try container.decodeIfPresent(String.self, forKey: .profileNickname)
        serviceProviderName = try container.decodeIfPresent(String.self, forKey: .serviceProviderName) ?? ""
        profileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? ""
        profileClass = try container.decodeIfPresent(String.self, forKey: .profileClass) ?? ""
        iconType = try container.decodeIfPresent(String.self, forKey: .iconType) ?? ""
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
    }

    var displayName: String {
        firstPresent(profileNickname ?? "")
            ?? firstPresent(profileName)
            ?? firstPresent(serviceProviderName)
            ?? localized("estk.profile.unnamed")
    }

    var isEnabled: Bool {
        profileState.caseInsensitiveCompare("enabled") == .orderedSame
    }

    var stateLocalizationKey: String {
        isEnabled ? "estk.profile.state.enabled" : "estk.profile.state.disabled"
    }
}

/// One pending profile-management notification stored on the eUICC.
struct ESTKNotification: Decodable, Equatable, Identifiable {
    var id: Int { seqNumber }
    var seqNumber: Int
    var profileManagementOperation: String
    var notificationAddress: String
    var iccid: String

    private enum CodingKeys: String, CodingKey {
        case seqNumber, profileManagementOperation, notificationAddress, iccid
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seqNumber = try container.decode(Int.self, forKey: .seqNumber)
        profileManagementOperation = try container.decodeIfPresent(String.self, forKey: .profileManagementOperation) ?? ""
        notificationAddress = try container.decodeIfPresent(String.self, forKey: .notificationAddress) ?? ""
        iccid = try container.decodeIfPresent(String.self, forKey: .iccid) ?? ""
    }

    var operationLocalizationKey: String {
        switch profileManagementOperation.lowercased() {
        case "install": "estk.notification.operation.install"
        case "enable": "estk.notification.operation.enable"
        case "disable": "estk.notification.operation.disable"
        case "delete": "estk.notification.operation.delete"
        default: "estk.notification.operation.unknown"
        }
    }
}

/// eUICC identity, configured servers, firmware, and memory reported by lpac.
struct ESTKChipInfo: Decodable, Equatable {
    struct ConfiguredAddresses: Decodable, Equatable {
        var defaultDPAddress: String?
        var rootDSAddress: String?

        private enum CodingKeys: String, CodingKey {
            case defaultDPAddress = "defaultDpAddress"
            case rootDSAddress = "rootDsAddress"
        }
    }

    struct ExtendedInfo: Decodable, Equatable {
        struct Resources: Decodable, Equatable {
            var installedApplication: Int?
            var freeNonVolatileMemory: Int?
            var freeVolatileMemory: Int?
        }

        struct CertificationData: Decodable, Equatable {
            var platformLabel: String?
            var discoveryBaseURL: String?
        }

        var profileVersion: String?
        var svn: String?
        var euiccFirmwareVer: String?
        var uiccCapability: [String]?
        var ts102241Version: String?
        var globalplatformVersion: String?
        var rspCapability: [String]?
        var euiccCiPKIdListForVerification: [String]?
        var euiccCiPKIdListForSigning: [String]?
        var euiccCategory: String?
        var forbiddenProfilePolicyRules: [String]?
        var ppVersion: String?
        var sasAcreditationNumber: String?
        var extCardResource: Resources?
        var certificationDataObject: CertificationData?
    }

    struct RulesAuthorisation: Decodable, Equatable {
        struct Operator: Decodable, Equatable {
            var plmn: String?
            var gid1: String?
            var gid2: String?
        }

        var pprIds: [String]?
        var allowedOperators: [Operator]?
        var pprFlags: [String]?
    }

    var eidValue: String
    var configuredAddresses: ConfiguredAddresses?
    var extendedInfo: ExtendedInfo?
    var rulesAuthorisationTable: [RulesAuthorisation]?

    private enum CodingKeys: String, CodingKey {
        case eidValue
        case configuredAddresses = "EuiccConfiguredAddresses"
        case extendedInfo = "EUICCInfo2"
        case rulesAuthorisationTable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eidValue = try container.decodeIfPresent(String.self, forKey: .eidValue) ?? ""
        configuredAddresses = try container.decodeIfPresent(ConfiguredAddresses.self, forKey: .configuredAddresses)
        extendedInfo = try container.decodeIfPresent(ExtendedInfo.self, forKey: .extendedInfo)
        rulesAuthorisationTable = try container.decodeIfPresent([RulesAuthorisation].self, forKey: .rulesAuthorisationTable)
    }
}

/// One SM-DP+ endpoint returned by ES11 discovery through an SM-DS server.
struct ESTKDiscoveryResult: Equatable, Identifiable {
    var id: String { address }
    var address: String
}

/// A redacted in-memory trace of lpac progress and completed eUICC actions.
struct ESTKLogEntry: Equatable, Identifiable {
    enum Kind: Equatable {
        case progress
        case success
        case failure
    }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var message: String
}

/// EUM metadata derived from the public EID prefix registry used by EasyLPAC.
struct ESTKManufacturer: Decodable, Equatable {
    var eum: String
    var country: String
    var manufacturer: String
}

/// Certificate-issuer metadata derived from the public CI registry used by EasyLPAC.
struct ESTKCertificateIssuer: Decodable, Equatable, Identifiable {
    var id: String { keyID }
    var keyID: String
    var country: String?
    var name: String

    private enum CodingKeys: String, CodingKey {
        case keyID = "key-id"
        case country, name
    }
}

/// Runtime state for eSTK/eUICC management.
struct ESTKState: Equatable {
    var availability: ESTKAvailability = .unknown
    var lpacVersion = "-"
    var chipInfo: ESTKChipInfo?
    var profiles: [ESTKProfile] = []
    /// Mac-local user-attached details per profile (P7-A), keyed by ICCID.
    var profileMetadata: [String: ProfileMetadata] = [:]
    var notifications: [ESTKNotification] = []
    var discoveryResults: [ESTKDiscoveryResult] = []
    var rawChipInfo = ""
    var operationLog: [ESTKLogEntry] = []
    var lastUpdated: Date?
    var lastError: String?
    var warning: String?
    var apduBackend: ESTKAPDUBackend?
    var lastAPDUOperation = "-"
    var lastAPDUStatusWord = "-"
    var lastAPDUResponseBytes = 0
}

/// Accepts both QR/LPA strings and EasyLPAC-style manual SM-DP+ downloads.
struct ESTKDownloadRequest: Equatable {
    var activationCode: String
    var smdpAddress: String
    var matchingID: String
    var confirmationCode: String
}

func validatedESTKDownloadArguments(_ request: ESTKDownloadRequest, imei: String?) throws -> [String] {
    var arguments = ["profile", "download"]
    if let activationCode = firstPresent(request.activationCode) {
        arguments.append(contentsOf: ["-a", try normalizedESTKActivationCode(activationCode)])
    } else {
        guard let smdp = firstPresent(request.smdpAddress),
              let matchingID = firstPresent(request.matchingID),
              matchingID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw ESTKError.invalidDownloadParameters
        }
        arguments.append(contentsOf: ["-s", smdp, "-m", matchingID])
    }
    if let confirmation = firstPresent(request.confirmationCode) {
        arguments.append(contentsOf: ["-c", confirmation])
    }
    if let imei = firstPresent(imei ?? "") {
        arguments.append(contentsOf: ["-i", imei])
    }
    return arguments
}

/// Extracts the ISO 7816 logical channel encoded in an APDU class byte.
func estkLogicalChannel(fromAPDU value: String) throws -> UInt8 {
    let hex = trimmed(value).uppercased()
    guard hex.count >= 2, let cla = UInt8(hex.prefix(2), radix: 16) else {
        throw ESTKError.malformedAPDURequest
    }
    return cla & 0x40 == 0 ? cla & 0x03 : (cla & 0x0F) + 4
}

/// Parses the channel identifier returned by `AT+CCHO` across common modem formats.
func parseESTKCCHOChannel(_ lines: [String]) throws -> UInt8 {
    for line in lines {
        let payload: Substring
        if let colon = line.firstIndex(of: ":") {
            payload = line[line.index(after: colon)...]
        } else {
            payload = line[...]
        }
        let token = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .first
        if let token, let channel = UInt8(token), (1...19).contains(channel) {
            return channel
        }
    }
    throw ESTKError.malformedLogicalChannelResponse
}

/// Parses a length-prefixed hexadecimal response from `AT+CGLA` or `AT+CSIM`.
func parseESTKAPDUResponse(_ lines: [String], prefix: String) throws -> String {
    guard let line = lines.first(where: { $0.uppercased().hasPrefix(prefix.uppercased()) }),
          let colon = line.firstIndex(of: ":") else {
        throw ESTKError.malformedAPDUResponse(prefix)
    }

    let payload = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let comma = payload.firstIndex(of: ","),
          let declaredLength = Int(payload[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw ESTKError.malformedAPDUResponse(prefix)
    }

    var response = payload[payload.index(after: comma)...].trimmingCharacters(in: .whitespacesAndNewlines)
    if response.hasPrefix("\"") && response.hasSuffix("\"") {
        response.removeFirst()
        response.removeLast()
    }
    response = response.uppercased()
    guard response.count == declaredLength,
          response.count.isMultiple(of: 2),
          response.allSatisfy(\.isHexDigit) else {
        throw ESTKError.malformedAPDUResponse(prefix)
    }
    return response
}

/// Normalizes the activation-code forms accepted by EasyLPAC into an LPA URI.
func normalizedESTKActivationCode(_ input: String) throws -> String {
    var code = trimmed(input)
    if code.hasPrefix("1$") {
        code = "LPA:" + code
    } else if code.hasPrefix("$") {
        code = "LPA:1" + code
    }

    guard code.lowercased().hasPrefix("lpa:1$") else {
        throw ESTKError.invalidActivationCode
    }

    let suffix = code.dropFirst(4)
    let fields = suffix.split(separator: "$", omittingEmptySubsequences: false)
    guard fields.count >= 2, fields[0] == "1", !fields[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ESTKError.invalidActivationCode
    }
    return "LPA:" + suffix
}
