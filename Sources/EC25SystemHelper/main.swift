import Darwin
import EC25SystemHelperProtocol
import Foundation
import Security
import SystemConfiguration

// The SMAppService-registered privileged daemon. It exposes exactly two
// operation groups over XPC — IKE transport and network configuration — and
// every request crosses a decode → validate → execute pipeline before
// touching the system. No shell, no command strings, no client-supplied
// paths are accepted anywhere in this binary.

private enum HelperLog {
    static func info(_ message: String) {
        NSLog("[EC25SystemHelper] %@", message)
    }
}

// MARK: - One-time legacy helper migration

/// Removes the legacy bless-installed IKE helper once this daemon is
/// running. Idempotent: after the first successful pass nothing remains.
/// Rollback stays possible because the app bundle still ships the legacy
/// binary and the legacy client can reinstall it (until packaging removes it
/// after migration acceptance).
private enum LegacyHelperJanitor {
    private static let legacyLabel = "ing.fuyaoskyrocket.ec25toolbox.ike-helper"
    private static let legacyToolPath = "/Library/PrivilegedHelperTools/\(legacyLabel)"
    private static let legacyPlistPath = "/Library/LaunchDaemons/\(legacyLabel).plist"

    static func removeIfPresent() {
        let manager = FileManager.default
        let toolPresent = manager.fileExists(atPath: legacyToolPath)
        let plistPresent = manager.fileExists(atPath: legacyPlistPath)
        guard toolPresent || plistPresent else { return }

        // launchctl bootout with fixed argv — no shell interpretation.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "system/\(legacyLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        do {
            if toolPresent { try manager.removeItem(atPath: legacyToolPath) }
            if plistPresent { try manager.removeItem(atPath: legacyPlistPath) }
            HelperLog.info("Removed legacy IKE helper \(legacyLabel).")
        } catch {
            HelperLog.info("Legacy helper removal incomplete: \(error.localizedDescription)")
        }
    }
}

// MARK: - IKE transport group

/// Connected-UDP channel table. Socket logic mirrors the legacy helper:
/// numeric public ePDG addresses only, matching local/remote IKE ports.
private final class IKEChannelService: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [UUID: Int32] = [:]

    func open(_ request: IKEOpenChannelRequest) -> EC25SystemHelperResponse {
        do {
            let descriptor = try makeConnectedSocket(
                host: request.host,
                remotePort: request.remotePort,
                localPort: request.localPort
            )
            let channelID = UUID()
            lock.lock()
            sockets[channelID] = descriptor
            lock.unlock()
            return .ikeChannelOpened(channelID: channelID)
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    func send(_ request: IKESendRequest) -> EC25SystemHelperResponse {
        guard let descriptor = socket(for: request.channelID) else {
            return .failure(message: "IKE channel is closed.")
        }
        let sent = request.payload.withUnsafeBytes { buffer in
            Darwin.send(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard sent == request.payload.count else {
            return .failure(message: posixError("send"))
        }
        return .ikeSent
    }

    func receive(_ request: IKEReceiveRequest) -> EC25SystemHelperResponse {
        guard let descriptor = socket(for: request.channelID) else {
            return .failure(message: "IKE channel is closed.")
        }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let timeoutMilliseconds = Int32(max(1, min(request.timeout, 300)) * 1_000)
        let pollResult = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
        guard pollResult > 0 else {
            return .failure(message: pollResult == 0 ? "IKE receive timed out." : posixError("poll"))
        }
        var bytes = [UInt8](repeating: 0, count: 65_535)
        let received = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        guard received > 0 else {
            return .failure(message: received == 0 ? "ePDG returned an empty datagram." : posixError("recv"))
        }
        return .ikeReceived(payload: Data(bytes.prefix(received)))
    }

    func close(_ request: IKECloseRequest) -> EC25SystemHelperResponse {
        lock.lock()
        let descriptor = sockets.removeValue(forKey: request.channelID)
        lock.unlock()
        if let descriptor { Darwin.close(descriptor) }
        return .ikeClosed
    }

    func closeAll() {
        lock.lock()
        let descriptors = Array(sockets.values)
        sockets.removeAll()
        lock.unlock()
        for descriptor in descriptors { Darwin.close(descriptor) }
    }

    private func socket(for channelID: UUID) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return sockets[channelID]
    }

    private func makeConnectedSocket(
        host: String,
        remotePort: UInt16,
        localPort: UInt16
    ) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: Int32(IPPROTO_UDP),
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var results: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(remotePort), &hints, &results)
        guard status == 0, let first = results else {
            throw HelperExecutionError.message("Invalid numeric ePDG address.")
        }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let entry = current {
            defer { current = entry.pointee.ai_next }
            guard isPublicRemoteAddress(entry.pointee.ai_addr) else { continue }
            let descriptor = Darwin.socket(
                entry.pointee.ai_family,
                entry.pointee.ai_socktype,
                entry.pointee.ai_protocol
            )
            guard descriptor >= 0 else { continue }
            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            guard bindLocal(descriptor, family: entry.pointee.ai_family, port: localPort),
                  Darwin.connect(descriptor, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0 else {
                Darwin.close(descriptor)
                continue
            }
            return descriptor
        }
        throw HelperExecutionError.message(posixError("bind/connect UDP \(localPort)"))
    }

    private func bindLocal(_ descriptor: Int32, family: Int32, port: UInt16) -> Bool {
        if family == AF_INET {
            var address = sockaddr_in(
                sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                sin_family: sa_family_t(AF_INET),
                sin_port: port.bigEndian,
                sin_addr: in_addr(s_addr: INADDR_ANY),
                sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
            )
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
        if family == AF_INET6 {
            var address = sockaddr_in6(
                sin6_len: UInt8(MemoryLayout<sockaddr_in6>.size),
                sin6_family: sa_family_t(AF_INET6),
                sin6_port: port.bigEndian,
                sin6_flowinfo: 0,
                sin6_addr: in6addr_any,
                sin6_scope_id: 0
            )
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }
        return false
    }

    private func isPublicRemoteAddress(_ address: UnsafePointer<sockaddr>?) -> Bool {
        guard let address else { return false }
        if Int32(address.pointee.sa_family) == AF_INET {
            let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            let value = UInt32(bigEndian: ipv4.sin_addr.s_addr)
            return value != 0 && value >> 24 != 127
        }
        if Int32(address.pointee.sa_family) == AF_INET6 {
            let ipv6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            return !bytes.allSatisfy { $0 == 0 }
                && !(bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
        }
        return false
    }

    private func posixError(_ operation: String) -> String {
        "\(operation): \(String(cString: strerror(errno)))"
    }
}

private enum HelperExecutionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self { return message }
        return nil
    }
}

// MARK: - Network configuration group

/// SystemConfiguration-backed implementation. Every mutation runs inside a
/// locked SCPreferences session with commit + apply, and services are
/// matched strictly by their SCNetworkService UUID — never by free text.
private enum NetworkConfigurationService {
    static func createService(_ request: NetworkServiceCreateRequest) -> EC25SystemHelperResponse {
        withLockedPreferences { preferences in
            guard let interface = findInterface(bsdName: request.interface.bsdName) else {
                return "Network interface \(request.interface.bsdName) not found."
            }
            guard let service = SCNetworkServiceCreate(preferences, interface) else {
                return "SCNetworkServiceCreate failed."
            }
            guard SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeIPv4),
                  SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeIPv6) else {
                _ = SCNetworkServiceRemove(service)
                return "Adding protocol types failed."
            }
            guard let ipv4 = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4) else {
                _ = SCNetworkServiceRemove(service)
                return "IPv4 protocol unavailable."
            }
            let configuration = [kSCPropNetIPv4ConfigMethod: kSCValNetIPv4ConfigMethodDHCP] as CFDictionary
            guard SCNetworkProtocolSetConfiguration(ipv4, configuration) else {
                _ = SCNetworkServiceRemove(service)
                return "Applying DHCP configuration failed."
            }
            guard SCNetworkServiceSetName(service, request.serviceName as CFString) else {
                _ = SCNetworkServiceRemove(service)
                return "Setting service name failed."
            }
            guard SCNetworkServiceSetEnabled(service, true) else {
                _ = SCNetworkServiceRemove(service)
                return "Enabling service failed."
            }
            return nil
        }
    }

    static func setServiceEnabled(_ request: NetworkServiceStateRequest) -> EC25SystemHelperResponse {
        withLockedPreferences { preferences in
            guard let service = findService(preferences, id: request.serviceID) else {
                return "Network service \(request.serviceID.uuidString) not found."
            }
            guard SCNetworkServiceSetEnabled(service, request.enabled) else {
                return "Changing service state failed."
            }
            return nil
        }
    }

    /// DHCP has no public renew API. Flipping the method to BOOTP and back to
    /// DHCP with an apply in between forces configd to renegotiate the lease
    /// without spawning any external tool.
    static func renewDHCP(_ request: NetworkDHCPRenewRequest) -> EC25SystemHelperResponse {
        let flip: (CFString) -> String? = { method in
            withLockedPreferencesRaw { preferences in
                guard let service = findService(preferences, id: request.serviceID) else {
                    return "Network service \(request.serviceID.uuidString) not found."
                }
                guard let ipv4 = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4) else {
                    return "IPv4 protocol unavailable."
                }
                let configuration = [kSCPropNetIPv4ConfigMethod: method] as CFDictionary
                guard SCNetworkProtocolSetConfiguration(ipv4, configuration) else {
                    return "Applying configuration failed."
                }
                return nil
            }
        }
        if let error = flip(kSCValNetIPv4ConfigMethodBOOTP) { return .failure(message: error) }
        if let error = flip(kSCValNetIPv4ConfigMethodDHCP) { return .failure(message: error) }
        return .networkOperationCompleted
    }

    static func forceInterfaceRefresh(_ request: NetworkInterfaceReference) -> EC25SystemHelperResponse {
        guard let interface = findInterface(bsdName: request.bsdName) else {
            return .failure(message: "Network interface \(request.bsdName) not found.")
        }
        guard SCNetworkInterfaceForceConfigurationRefresh(interface) else {
            return .failure(message: "SCNetworkInterfaceForceConfigurationRefresh failed.")
        }
        return .networkOperationCompleted
    }

    private static func withLockedPreferences(
        _ body: (SCPreferences) -> String?
    ) -> EC25SystemHelperResponse {
        if let error = withLockedPreferencesRaw(body) {
            return .failure(message: error)
        }
        return .networkOperationCompleted
    }

    private static func withLockedPreferencesRaw(_ body: (SCPreferences) -> String?) -> String? {
        guard let preferences = SCPreferencesCreate(
            nil,
            "ing.fuyaoskyrocket.ec25toolbox.system-helper" as CFString,
            nil
        ) else {
            return "SCPreferencesCreate failed."
        }
        guard SCPreferencesLock(preferences, true) else {
            return "SCPreferencesLock failed."
        }
        defer { SCPreferencesUnlock(preferences) }
        if let error = body(preferences) { return error }
        guard SCPreferencesCommitChanges(preferences) else {
            return "SCPreferencesCommitChanges failed."
        }
        guard SCPreferencesApplyChanges(preferences) else {
            return "SCPreferencesApplyChanges failed."
        }
        return nil
    }

    private static func findInterface(bsdName: String) -> SCNetworkInterface? {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        return interfaces.first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
    }

    private static func findService(_ preferences: SCPreferences, id: UUID) -> SCNetworkService? {
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else { return nil }
        return services.first {
            (SCNetworkServiceGetServiceID($0) as String?)?.caseInsensitiveCompare(id.uuidString) == .orderedSame
        }
    }
}

// MARK: - XPC service

private final class EC25SystemHelperService: NSObject, EC25SystemHelperXPCProtocol, @unchecked Sendable {
    private let ikeChannels = IKEChannelService()

    func protocolVersion(withReply reply: @escaping (Int) -> Void) {
        reply(EC25SystemHelperConstants.protocolVersion)
    }

    func performIKEOperation(_ requestData: Data, withReply reply: @escaping (Data?) -> Void) {
        reply(perform(requestData, group: .ike))
    }

    func performNetworkConfiguration(_ requestData: Data, withReply reply: @escaping (Data?) -> Void) {
        reply(perform(requestData, group: .network))
    }

    private enum Group {
        case ike
        case network
    }

    /// Decode → validate → execute. Malformed envelopes, unknown operations,
    /// cross-group requests, and validation failures are all rejected here
    /// before any system call happens.
    private func perform(_ requestData: Data, group: Group) -> Data? {
        let request: EC25SystemHelperRequest
        do {
            request = try EC25SystemHelperCoding.decodeRequest(requestData)
            _ = try EC25SystemHelperValidator.validated(request)
        } catch {
            return try? EC25SystemHelperCoding.encodeResponse(.failure(message: "Request rejected."))
        }

        let response: EC25SystemHelperResponse
        switch (group, request) {
        case (.ike, .ikeOpenChannel(let value)):
            response = ikeChannels.open(value)
        case (.ike, .ikeSend(let value)):
            response = ikeChannels.send(value)
        case (.ike, .ikeReceive(let value)):
            response = ikeChannels.receive(value)
        case (.ike, .ikeClose(let value)):
            response = ikeChannels.close(value)
        case (.network, .networkCreateService(let value)):
            response = NetworkConfigurationService.createService(value)
        case (.network, .networkSetServiceEnabled(let value)):
            response = NetworkConfigurationService.setServiceEnabled(value)
        case (.network, .networkRenewDHCP(let value)):
            response = NetworkConfigurationService.renewDHCP(value)
        case (.network, .networkForceInterfaceRefresh(let value)):
            response = NetworkConfigurationService.forceInterfaceRefresh(value)
        default:
            response = .failure(message: "Request rejected.")
        }
        return try? EC25SystemHelperCoding.encodeResponse(response)
    }

    func closeAllChannels() {
        ikeChannels.closeAll()
    }
}

private final class EC25SystemHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isAuthorizedClient(connection) else { return false }
        let service = EC25SystemHelperService()
        connection.exportedInterface = NSXPCInterface(with: EC25SystemHelperXPCProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.closeAllChannels() }
        connection.resume()
        return true
    }

    /// Same anchoring policy as the legacy helper: the client's code-signing
    /// identifier must match this app. Ad hoc local builds pass because the
    /// identifier is stable across signing identities.
    private func isAuthorizedClient(_ connection: NSXPCConnection) -> Bool {
        let attributes = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode else { return false }
        var requirement: SecRequirement?
        let expression = "identifier \"ing.fuyaoskyrocket.ec25toolbox\"" as CFString
        guard SecRequirementCreateWithString(expression, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(guestCode, [], requirement) == errSecSuccess
    }
}

LegacyHelperJanitor.removeIfPresent()

private let delegate = EC25SystemHelperListenerDelegate()
private let listener = NSXPCListener(machServiceName: EC25SystemHelperConstants.label)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
