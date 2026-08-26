import Darwin
import Foundation

/// Constants for the SMAppService-based system helper that will succeed the
/// legacy `EC25IKEHelper`. The legacy constants stay untouched in
/// `EC25IKEHelperProtocol` so one-time migration code can identify old
/// installations by label and protocol version.
public enum EC25SystemHelperConstants {
    public static let label = "ing.fuyaoskyrocket.ec25toolbox.system-helper"
    public static let executableName = "EC25SystemHelper"
    public static let protocolVersion = 1
    public static let bundledPlistName = "\(label).plist"
}

// MARK: - Request payloads (IKE transport group)

/// Opens one connected UDP channel to a numeric ePDG address. Both ports must
/// be the same IKE/NAT-T port (500 or 4500), matching the legacy helper.
public struct IKEOpenChannelRequest: Codable, Equatable, Sendable {
    public var host: String
    public var remotePort: UInt16
    public var localPort: UInt16

    public init(host: String, remotePort: UInt16, localPort: UInt16) {
        self.host = host
        self.remotePort = remotePort
        self.localPort = localPort
    }
}

public struct IKESendRequest: Codable, Equatable, Sendable {
    public var channelID: UUID
    public var payload: Data

    public init(channelID: UUID, payload: Data) {
        self.channelID = channelID
        self.payload = payload
    }
}

public struct IKEReceiveRequest: Codable, Equatable, Sendable {
    public var channelID: UUID
    public var timeout: TimeInterval

    public init(channelID: UUID, timeout: TimeInterval) {
        self.channelID = channelID
        self.timeout = timeout
    }
}

public struct IKECloseRequest: Codable, Equatable, Sendable {
    public var channelID: UUID

    public init(channelID: UUID) {
        self.channelID = channelID
    }
}

// MARK: - Request payloads (network configuration group)

/// Identifies a network interface strictly by its kernel BSD name (e.g.
/// `en5`). No device paths, no user-supplied file paths.
public struct NetworkInterfaceReference: Codable, Equatable, Sendable {
    public var bsdName: String

    public init(bsdName: String) {
        self.bsdName = bsdName
    }
}

/// Creates a named IPv4-DHCP network service on one interface.
public struct NetworkServiceCreateRequest: Codable, Equatable, Sendable {
    public var interface: NetworkInterfaceReference
    public var serviceName: String

    public init(interface: NetworkInterfaceReference, serviceName: String) {
        self.interface = interface
        self.serviceName = serviceName
    }
}

/// Enables or disables an existing service by its SCNetworkService ID.
public struct NetworkServiceStateRequest: Codable, Equatable, Sendable {
    public var serviceID: UUID
    public var enabled: Bool

    public init(serviceID: UUID, enabled: Bool) {
        self.serviceID = serviceID
        self.enabled = enabled
    }
}

/// Renews DHCP on an existing service.
public struct NetworkDHCPRenewRequest: Codable, Equatable, Sendable {
    public var serviceID: UUID

    public init(serviceID: UUID) {
        self.serviceID = serviceID
    }
}

// MARK: - Typed request envelope

/// Every operation the system helper may perform, grouped by domain. The
/// helper never accepts shell fragments, command strings, or arbitrary file
/// paths; only these Codable structures cross the XPC boundary.
public enum EC25SystemHelperRequest: Equatable, Sendable {
    // IKE transport group.
    case ikeOpenChannel(IKEOpenChannelRequest)
    case ikeSend(IKESendRequest)
    case ikeReceive(IKEReceiveRequest)
    case ikeClose(IKECloseRequest)
    // Network configuration group.
    case networkCreateService(NetworkServiceCreateRequest)
    case networkSetServiceEnabled(NetworkServiceStateRequest)
    case networkRenewDHCP(NetworkDHCPRenewRequest)
    case networkForceInterfaceRefresh(NetworkInterfaceReference)

    /// Stable operation identifiers used on the wire.
    enum Operation: String, Codable, Sendable {
        case ikeOpenChannel
        case ikeSend
        case ikeReceive
        case ikeClose
        case networkCreateService
        case networkSetServiceEnabled
        case networkRenewDHCP
        case networkForceInterfaceRefresh
    }

    var operation: Operation {
        switch self {
        case .ikeOpenChannel: .ikeOpenChannel
        case .ikeSend: .ikeSend
        case .ikeReceive: .ikeReceive
        case .ikeClose: .ikeClose
        case .networkCreateService: .networkCreateService
        case .networkSetServiceEnabled: .networkSetServiceEnabled
        case .networkRenewDHCP: .networkRenewDHCP
        case .networkForceInterfaceRefresh: .networkForceInterfaceRefresh
        }
    }
}

// MARK: - Typed response envelope

public enum EC25SystemHelperResponse: Equatable, Sendable {
    case ikeChannelOpened(channelID: UUID)
    case ikeSent
    case ikeReceived(payload: Data)
    case ikeClosed
    case networkOperationCompleted
    /// Structured rejection: validation or execution failure message.
    case failure(message: String)
}

// MARK: - Coding

/// Errors produced when an XPC envelope cannot be decoded at all.
public enum EC25SystemHelperEnvelopeError: Error, Equatable, Sendable {
    case malformedEnvelope
}

private enum EnvelopeCoding {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    private struct RequestBox: Codable {
        var operation: String
        var payload: Data
    }

    private struct ResponseBox: Codable {
        var operation: String
        var payload: Data
    }

    static func encode(_ request: EC25SystemHelperRequest) throws -> Data {
        let payload: Data
        switch request {
        case .ikeOpenChannel(let value): payload = try encoder.encode(value)
        case .ikeSend(let value): payload = try encoder.encode(value)
        case .ikeReceive(let value): payload = try encoder.encode(value)
        case .ikeClose(let value): payload = try encoder.encode(value)
        case .networkCreateService(let value): payload = try encoder.encode(value)
        case .networkSetServiceEnabled(let value): payload = try encoder.encode(value)
        case .networkRenewDHCP(let value): payload = try encoder.encode(value)
        case .networkForceInterfaceRefresh(let value): payload = try encoder.encode(value)
        }
        return try encoder.encode(RequestBox(operation: request.operation.rawValue, payload: payload))
    }

    static func decodeRequest(_ data: Data) throws -> EC25SystemHelperRequest {
        let box = try decoder.decode(RequestBox.self, from: data)
        guard let operation = EC25SystemHelperRequest.Operation(rawValue: box.operation) else {
            throw EC25SystemHelperEnvelopeError.malformedEnvelope
        }
        switch operation {
        case .ikeOpenChannel:
            return .ikeOpenChannel(try decoder.decode(IKEOpenChannelRequest.self, from: box.payload))
        case .ikeSend:
            return .ikeSend(try decoder.decode(IKESendRequest.self, from: box.payload))
        case .ikeReceive:
            return .ikeReceive(try decoder.decode(IKEReceiveRequest.self, from: box.payload))
        case .ikeClose:
            return .ikeClose(try decoder.decode(IKECloseRequest.self, from: box.payload))
        case .networkCreateService:
            return .networkCreateService(try decoder.decode(NetworkServiceCreateRequest.self, from: box.payload))
        case .networkSetServiceEnabled:
            return .networkSetServiceEnabled(try decoder.decode(NetworkServiceStateRequest.self, from: box.payload))
        case .networkRenewDHCP:
            return .networkRenewDHCP(try decoder.decode(NetworkDHCPRenewRequest.self, from: box.payload))
        case .networkForceInterfaceRefresh:
            return .networkForceInterfaceRefresh(try decoder.decode(NetworkInterfaceReference.self, from: box.payload))
        }
    }

    static func encode(_ response: EC25SystemHelperResponse) throws -> Data {
        let operation: String
        let payload: Data
        switch response {
        case .ikeChannelOpened(let channelID):
            operation = "ikeChannelOpened"
            payload = try encoder.encode(channelID)
        case .ikeSent:
            operation = "ikeSent"
            payload = Data()
        case .ikeReceived(let bytes):
            operation = "ikeReceived"
            payload = bytes
        case .ikeClosed:
            operation = "ikeClosed"
            payload = Data()
        case .networkOperationCompleted:
            operation = "networkOperationCompleted"
            payload = Data()
        case .failure(let message):
            operation = "failure"
            payload = try encoder.encode(message)
        }
        return try encoder.encode(ResponseBox(operation: operation, payload: payload))
    }

    static func decodeResponse(_ data: Data) throws -> EC25SystemHelperResponse {
        let box = try decoder.decode(ResponseBox.self, from: data)
        switch box.operation {
        case "ikeChannelOpened":
            return .ikeChannelOpened(channelID: try decoder.decode(UUID.self, from: box.payload))
        case "ikeSent":
            return .ikeSent
        case "ikeReceived":
            return .ikeReceived(payload: box.payload)
        case "ikeClosed":
            return .ikeClosed
        case "networkOperationCompleted":
            return .networkOperationCompleted
        case "failure":
            return .failure(message: try decoder.decode(String.self, from: box.payload))
        default:
            throw EC25SystemHelperEnvelopeError.malformedEnvelope
        }
    }
}

/// Public coding entry points used by both the app-side client and the helper.
public enum EC25SystemHelperCoding {
    public static func encodeRequest(_ request: EC25SystemHelperRequest) throws -> Data {
        try EnvelopeCoding.encode(request)
    }

    public static func decodeRequest(_ data: Data) throws -> EC25SystemHelperRequest {
        try EnvelopeCoding.decodeRequest(data)
    }

    public static func encodeResponse(_ response: EC25SystemHelperResponse) throws -> Data {
        try EnvelopeCoding.encode(response)
    }

    public static func decodeResponse(_ data: Data) throws -> EC25SystemHelperResponse {
        try EnvelopeCoding.decodeResponse(data)
    }
}

// MARK: - Validation

/// Every structural rejection the validator can raise. No message strings —
/// the helper maps cases to generic replies so client-supplied text is never
/// reflected back across the privilege boundary.
public enum EC25SystemHelperValidationError: Error, Equatable, Sendable {
    case invalidHost
    case nonPublicHost
    case unsupportedPort
    case mismatchedPorts
    case invalidPayloadLength
    case invalidTimeout
    case invalidInterfaceName
    case invalidServiceName
}

/// Pure structural validation for every request that may cross into the
/// privileged helper. The helper validates again after decoding; the client
/// may validate early for better error reporting. Rules intentionally mirror
/// the legacy helper's hard limits (numeric public host, IKE ports only).
public enum EC25SystemHelperValidator {
    /// Returns the request unchanged when valid, throws otherwise.
    public static func validated(
        _ request: EC25SystemHelperRequest
    ) throws(EC25SystemHelperValidationError) -> EC25SystemHelperRequest {
        switch request {
        case .ikeOpenChannel(let value): try validate(value)
        case .ikeSend(let value): try validate(value)
        case .ikeReceive(let value): try validate(value)
        case .ikeClose: break
        case .networkCreateService(let value): try validate(value)
        case .networkSetServiceEnabled: break
        case .networkRenewDHCP: break
        case .networkForceInterfaceRefresh(let value): try validate(value)
        }
        return request
    }

    static func validate(_ request: IKEOpenChannelRequest) throws(EC25SystemHelperValidationError) {
        guard [500, 4_500].contains(request.remotePort) else { throw .unsupportedPort }
        guard request.remotePort == request.localPort else { throw .mismatchedPorts }
        guard let family = numericAddressFamily(request.host) else { throw .invalidHost }
        guard isPublicAddress(request.host, family: family) else { throw .nonPublicHost }
    }

    static func validate(_ request: IKESendRequest) throws(EC25SystemHelperValidationError) {
        guard !request.payload.isEmpty, request.payload.count <= 65_535 else {
            throw .invalidPayloadLength
        }
    }

    static func validate(_ request: IKEReceiveRequest) throws(EC25SystemHelperValidationError) {
        guard request.timeout > 0, request.timeout <= 300 else { throw .invalidTimeout }
    }

    static func validate(_ request: NetworkServiceCreateRequest) throws(EC25SystemHelperValidationError) {
        try validate(request.interface)
        let name = request.serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name == request.serviceName, name.count <= 128 else {
            throw .invalidServiceName
        }
        guard name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw .invalidServiceName
        }
    }

    static func validate(_ interface: NetworkInterfaceReference) throws(EC25SystemHelperValidationError) {
        // IFNAMSIZ bounds kernel interface names to 16 bytes including NUL.
        let name = interface.bsdName
        guard !name.isEmpty, name.count <= 15,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw .invalidInterfaceName
        }
    }

    /// Numeric IP literals only — never DNS names, so a compromised or buggy
    /// client cannot turn the helper into a resolver or SSRF pivot.
    private static func numericAddressFamily(_ host: String) -> Int32? {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return AF_INET }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return AF_INET6 }
        return nil
    }

    /// Mirrors the legacy helper: reject 0.0.0.0, 127.0.0.0/8, ::, and ::1.
    private static func isPublicAddress(_ host: String, family: Int32) -> Bool {
        if family == AF_INET {
            var address = in_addr()
            guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return false }
            let value = UInt32(bigEndian: address.s_addr)
            return value != 0 && value >> 24 != 127
        }
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        return !bytes.allSatisfy { $0 == 0 }
            && !(bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
    }
}

// MARK: - XPC surface

/// The privileged helper's XPC interface. Operations are split into the IKE
/// transport group and the network configuration group; both accept only
/// encoded `EC25SystemHelperRequest` envelopes that the helper decodes,
/// validates with `EC25SystemHelperValidator`, and executes — anything else
/// is rejected before touching the system.
@objc(EC25SystemHelperXPCProtocol)
public protocol EC25SystemHelperXPCProtocol {
    func protocolVersion(withReply reply: @escaping (Int) -> Void)
    func performIKEOperation(_ requestData: Data, withReply reply: @escaping (Data?) -> Void)
    func performNetworkConfiguration(_ requestData: Data, withReply reply: @escaping (Data?) -> Void)
}
