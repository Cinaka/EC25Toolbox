import EC25SystemHelperProtocol
import Foundation
import ServiceManagement

/// Registration/approval state of the SMAppService daemon, mapped off the
/// ServiceManagement enum so the decision logic stays unit-testable.
enum SystemHelperAvailability: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case plistMissing
    case registrationFailed

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .plistMissing
        @unknown default: self = .registrationFailed
        }
    }
}

/// What the app should do about the privileged IKE/network backend.
enum SystemHelperMigrationAction: Equatable, Sendable {
    /// New daemon is enabled — use it (its janitor removes the legacy helper).
    case useSystemHelper
    /// macOS requires explicit user approval in System Settings.
    case promptApproval
    /// Daemon has never been registered in this session.
    case register
    /// New daemon unavailable but the legacy helper is still installed.
    case useLegacyFallback
    /// Neither backend can run.
    case unavailable
}

/// Pure migration decision, kept separate from SMAppService so every branch
/// is covered by unit tests without touching the system.
enum SystemHelperMigrationPlan {
    static func action(
        system availability: SystemHelperAvailability,
        legacyInstalled: Bool
    ) -> SystemHelperMigrationAction {
        switch availability {
        case .enabled:
            .useSystemHelper
        case .requiresApproval:
            .promptApproval
        case .notRegistered:
            .register
        case .plistMissing, .registrationFailed:
            legacyInstalled ? .useLegacyFallback : .unavailable
        }
    }
}

enum SystemHelperError: Error, Equatable, Sendable {
    case approvalRequired
    case registrationFailed(String)
    case unavailable(String)
    case helperRejected(String)
    case malformedReply
}

extension SystemHelperError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .approvalRequired:
            localized("systemhelper.error.approval_required")
        case let .registrationFailed(detail):
            localizedFormat("systemhelper.error.registration_failed", detail)
        case let .unavailable(detail):
            detail.isEmpty ? localized("systemhelper.error.unavailable") : detail
        case .helperRejected(let detail):
            detail
        case .malformedReply:
            localized("systemhelper.error.malformed_reply")
        }
    }
}

/// App-side client for the SMAppService system helper. Envelope coding and
/// validation come from `EC25SystemHelperProtocol`; connection interruptions
/// and a disabled helper degrade safely — the caller decides whether the
/// legacy helper fallback applies.
final class SystemHelperClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    deinit {
        lock.lock()
        let oldConnection = connection
        connection = nil
        lock.unlock()
        oldConnection?.invalidate()
    }

    // MARK: - Registration and status

    var availability: SystemHelperAvailability {
        SystemHelperAvailability(Self.daemon.status)
    }

    func register() throws {
        do {
            try Self.daemon.register()
        } catch {
            throw SystemHelperError.registrationFailed(error.localizedDescription)
        }
    }

    func unregister() async throws {
        try await Self.daemon.unregister()
        invalidateConnection()
    }

    /// Opens System Settings at Login Items & Extensions so the user can
    /// approve the daemon. Only invoked on an explicit user action.
    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Prepares the IKE backend. Returns true when the new daemon is ready;
    /// false means the caller should use the legacy helper. Throws only when
    /// user action (approval) or an unrecoverable state blocks both paths.
    func prepareIKEBackend(legacyInstalled: Bool) async throws -> Bool {
        try await prepareBackend(legacyInstalled: legacyInstalled)
    }

    /// Ensures the daemon is registered and responding before a network
    /// configuration request. Unlike the IKE group there is no legacy helper
    /// for network configuration, so an unavailable backend always surfaces
    /// as an error instead of a fallback.
    @discardableResult
    func prepareNetworkBackend() async throws -> Bool {
        try await prepareBackend(legacyInstalled: false)
    }

    private func prepareBackend(legacyInstalled: Bool) async throws -> Bool {
        switch SystemHelperMigrationPlan.action(system: availability, legacyInstalled: legacyInstalled) {
        case .useSystemHelper:
            return (try? await protocolVersion()) == EC25SystemHelperConstants.protocolVersion
        case .promptApproval:
            throw SystemHelperError.approvalRequired
        case .register:
            try register()
            switch availability {
            case .enabled:
                return (try? await protocolVersion()) == EC25SystemHelperConstants.protocolVersion
            case .requiresApproval:
                throw SystemHelperError.approvalRequired
            case .notRegistered, .plistMissing, .registrationFailed:
                if legacyInstalled { return false }
                throw SystemHelperError.unavailable("registration did not complete")
            }
        case .useLegacyFallback:
            return false
        case .unavailable:
            throw SystemHelperError.unavailable("no privileged helper available")
        }
    }

    // MARK: - IKE transport group

    func ikeOpen(host: String, port: UInt16) async throws -> UUID {
        let request = EC25SystemHelperRequest.ikeOpenChannel(
            IKEOpenChannelRequest(host: host, remotePort: port, localPort: port)
        )
        let response = try await performIKE(request)
        guard case .ikeChannelOpened(let channelID) = response else {
            throw SystemHelperError.malformedReply
        }
        return channelID
    }

    func ikeSend(channelID: UUID, payload: Data) async throws {
        let response = try await performIKE(.ikeSend(IKESendRequest(channelID: channelID, payload: payload)))
        guard case .ikeSent = response else { throw SystemHelperError.malformedReply }
    }

    func ikeReceive(channelID: UUID, timeout: TimeInterval) async throws -> Data {
        let response = try await performIKE(.ikeReceive(IKEReceiveRequest(channelID: channelID, timeout: timeout)))
        guard case .ikeReceived(let payload) = response else { throw SystemHelperError.malformedReply }
        return payload
    }

    func ikeClose(channelID: UUID) async {
        _ = try? await performIKE(.ikeClose(IKECloseRequest(channelID: channelID)))
    }

    // MARK: - Network configuration group

    func networkCreateService(bsdName: String, serviceName: String) async throws {
        try await prepareNetworkBackend()
        let response = try await performNetwork(.networkCreateService(
            NetworkServiceCreateRequest(
                interface: NetworkInterfaceReference(bsdName: bsdName),
                serviceName: serviceName
            )
        ))
        try expectCompletion(response)
    }

    func networkSetServiceEnabled(serviceID: UUID, enabled: Bool) async throws {
        try await prepareNetworkBackend()
        let response = try await performNetwork(.networkSetServiceEnabled(
            NetworkServiceStateRequest(serviceID: serviceID, enabled: enabled)
        ))
        try expectCompletion(response)
    }

    func networkRenewDHCP(serviceID: UUID) async throws {
        try await prepareNetworkBackend()
        let response = try await performNetwork(.networkRenewDHCP(
            NetworkDHCPRenewRequest(serviceID: serviceID)
        ))
        try expectCompletion(response)
    }

    func networkForceInterfaceRefresh(bsdName: String) async throws {
        try await prepareNetworkBackend()
        let response = try await performNetwork(.networkForceInterfaceRefresh(
            NetworkInterfaceReference(bsdName: bsdName)
        ))
        try expectCompletion(response)
    }

    // MARK: - Plumbing

    private static var daemon: SMAppService {
        SMAppService.daemon(plistName: EC25SystemHelperConstants.bundledPlistName)
    }

    private func protocolVersion() async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let remote = proxy(errorHandler: { continuation.resume(throwing: $0) })
            remote.protocolVersion(withReply: { continuation.resume(returning: $0) })
        }
    }

    private func performIKE(_ request: EC25SystemHelperRequest) async throws -> EC25SystemHelperResponse {
        let data = try encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let remote = proxy(errorHandler: { continuation.resume(throwing: $0) })
            remote.performIKEOperation(data) { replyData in
                continuation.resume(with: Self.decodeReply(replyData))
            }
        }
    }

    private func performNetwork(_ request: EC25SystemHelperRequest) async throws -> EC25SystemHelperResponse {
        let data = try encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let remote = proxy(errorHandler: { continuation.resume(throwing: $0) })
            remote.performNetworkConfiguration(data) { replyData in
                continuation.resume(with: Self.decodeReply(replyData))
            }
        }
    }

    private func encode(_ request: EC25SystemHelperRequest) throws -> Data {
        do {
            _ = try EC25SystemHelperValidator.validated(request)
        } catch {
            throw SystemHelperError.helperRejected("validation: \(error)")
        }
        return try EC25SystemHelperCoding.encodeRequest(request)
    }

    private static func decodeReply(_ data: Data?) -> Result<EC25SystemHelperResponse, Error> {
        guard let data,
              let response = try? EC25SystemHelperCoding.decodeResponse(data) else {
            return .failure(SystemHelperError.malformedReply)
        }
        if case .failure(let message) = response {
            return .failure(SystemHelperError.helperRejected(message))
        }
        return .success(response)
    }

    private func expectCompletion(_ response: EC25SystemHelperResponse) throws {
        guard case .networkOperationCompleted = response else {
            throw SystemHelperError.malformedReply
        }
    }

    private func proxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> EC25SystemHelperXPCProtocol {
        let connection = activeConnection()
        let object = connection.remoteObjectProxyWithErrorHandler { error in
            self.invalidateConnection()
            errorHandler(SystemHelperError.unavailable(error.localizedDescription))
        }
        guard let proxy = object as? EC25SystemHelperXPCProtocol else {
            fatalError("Invalid EC25 system helper XPC interface")
        }
        return proxy
    }

    private func activeConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let newConnection = NSXPCConnection(
            machServiceName: EC25SystemHelperConstants.label,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(with: EC25SystemHelperXPCProtocol.self)
        newConnection.invalidationHandler = { [weak self] in self?.invalidateConnection() }
        newConnection.interruptionHandler = { [weak self] in self?.invalidateConnection() }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func invalidateConnection() {
        lock.lock()
        let oldConnection = connection
        connection = nil
        lock.unlock()
        oldConnection?.invalidate()
    }
}
