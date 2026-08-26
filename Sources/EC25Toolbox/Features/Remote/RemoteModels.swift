import Darwin
import Foundation

enum ManagementMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct
    case remote

    var id: String { rawValue }
    var localizationKey: String {
        switch self {
        case .direct: "remote.mode.direct"
        case .remote: "remote.mode.remote"
        }
    }
}

enum RemoteDefaults {
    static let lanPort = 48_525
    static let tailscalePort = 48_526
    /// v2 adds remote GNSS-NMEA relay and duplex call-audio frames.
    static let protocolVersion = 2
    static let maximumFrameBytes = 2 * 1_024 * 1_024
    static let requestLifetimeSeconds: Int64 = 60
}

struct RemoteManagementState: Equatable, Sendable {
    var mode: ManagementMode = .direct
    var sharingActive = false
    var listeningEndpoints: [String] = []
    var pairingKey = ""
    var connectedEndpoint = ""
    var lastError: String?
}

enum RemoteRequestKind: String, Codable, Sendable {
    case probe
    case at
    case nmeaStart
    case nmeaStop
    case audioExchange
}

struct RemoteRequest: Codable, Equatable, Sendable {
    var version = RemoteDefaults.protocolVersion
    var requestID = UUID()
    var timestamp = Int64(Date().timeIntervalSince1970)
    var kind: RemoteRequestKind
    var command: String?
    var payload: String?
    var timeoutMs: Int32?
    var audioSamples: [Float]?
    var audioSampleRate: Double?
    var requestedAudioFrames: Int?
    /// A reconnecting client may ask the host to repair a USB session that
    /// disappeared during a confirmed module reboot. Older v2 peers ignore
    /// the absent optional field.
    var repairUSBSession: Bool?
}

struct RemoteResponse: Codable, Equatable, Sendable {
    var version = RemoteDefaults.protocolVersion
    var requestID: UUID
    var timestamp = Int64(Date().timeIntervalSince1970)
    var success: Bool
    var lines: [String]?
    var description: String?
    var error: String?
    /// Events accumulated server-side since the previous response; absent on
    /// servers or requests without event support.
    var events: [ModemEvent]?
    var audioSamples: [Float]?
    var audioSampleRate: Double?
}

enum RemoteManagementError: LocalizedError, Equatable, Sendable {
    case invalidHost
    case invalidPort
    case invalidPairingKey
    case missingPairingKey
    case keychain(OSStatus)
    case connectionFailed(String)
    case protocolFailure
    case authenticationFailed
    case requestExpired
    case replayedRequest
    case remoteFailure(String)
    case serverUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidHost: localized("remote.error.invalid_host")
        case .invalidPort: localized("remote.error.invalid_port")
        case .invalidPairingKey: localized("remote.error.invalid_pairing_key")
        case .missingPairingKey: localized("remote.error.missing_pairing_key")
        case let .keychain(status): localizedFormat("remote.error.keychain", status)
        case let .connectionFailed(detail): localizedFormat("remote.error.connection", detail)
        case .protocolFailure: localized("remote.error.protocol")
        case .authenticationFailed: localized("remote.error.authentication")
        case .requestExpired: localized("remote.error.expired")
        case .replayedRequest: localized("remote.error.replayed")
        case let .remoteFailure(detail): localizedFormat("remote.error.remote", detail)
        case .serverUnavailable: localized("remote.error.server_unavailable")
        }
    }
}

struct RemoteBindAddress: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case lan
        case tailscale
    }

    var host: String
    var kind: Kind
}

func remoteBindAddresses() -> [RemoteBindAddress] {
    var addresses: Set<RemoteBindAddress> = []
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
    defer { freeifaddrs(first) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let current = cursor {
        defer { cursor = current.pointee.ifa_next }
        guard let address = current.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET),
              current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
              current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        let interfaceName = String(cString: current.pointee.ifa_name)

        var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &socketAddress.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        let ip = buffer.prefix { $0 != 0 }.withUnsafeBufferPointer { pointer in
            String(decoding: pointer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        if isTailscaleIPv4(ip), interfaceName.hasPrefix("utun") {
            addresses.insert(RemoteBindAddress(host: ip, kind: .tailscale))
        } else if isPrivateLANIPv4(ip), !ip.hasPrefix("192.168.225.") {
            addresses.insert(RemoteBindAddress(host: ip, kind: .lan))
        }
    }
    return addresses.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
}

func isTailscaleIPv4(_ value: String) -> Bool {
    let octets = value.split(separator: ".").compactMap { UInt8($0) }
    return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
}

func isPrivateLANIPv4(_ value: String) -> Bool {
    let octets = value.split(separator: ".").compactMap { UInt8($0) }
    guard octets.count == 4 else { return false }
    return octets[0] == 10
        || (octets[0] == 172 && (16...31).contains(octets[1]))
        || (octets[0] == 192 && octets[1] == 168)
}
