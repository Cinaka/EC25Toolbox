import EC25IKEHelperProtocol
import Foundation

/// Client and installer for the root IKE transport. The helper is deliberately
/// limited to UDP 500/4500 and authenticates this app's code-signing identifier.
///
/// Migration path (P8): the SMAppService system helper is preferred; the
/// legacy bless-installed helper remains as fallback and as the rollback
/// path. Channels are routed to the backend that opened them — mixing
/// backends mid-channel would silently drop traffic.
final class VoWiFiIKEHelperClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let systemHelper = SystemHelperClient()
    private var systemChannelIDs = Set<String>()

    deinit {
        lock.lock()
        let oldConnection = connection
        connection = nil
        lock.unlock()
        oldConnection?.invalidate()
    }

    func ensureInstalled() async throws {
        let bundled = bundledHelperURL
        guard FileManager.default.isExecutableFile(atPath: bundled.path),
              FileManager.default.fileExists(atPath: bundledPlistURL.path) else {
            throw VoWiFiError.transport(localized("vowifi.error.helper_missing"))
        }
        let installed = URL(fileURLWithPath: EC25IKEHelperConstants.installedExecutablePath)
        let matchesBundled = FileManager.default.fileExists(atPath: installed.path)
            && FileManager.default.contentsEqual(atPath: bundled.path, andPath: installed.path)
        if matchesBundled, (try? await ping()) == EC25IKEHelperConstants.protocolVersion {
            return
        }

        invalidateConnection()
        try await installBundledHelper()
        for _ in 0..<15 {
            if (try? await ping()) == EC25IKEHelperConstants.protocolVersion { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw VoWiFiError.transport(localized("vowifi.error.helper_unavailable"))
    }

    func open(host: String, port: UInt16) async throws -> String {
        if try await systemHelper.prepareIKEBackend(legacyInstalled: legacyHelperInstalled) {
            do {
                let channelID = try await systemHelper.ikeOpen(host: host, port: port)
                let key = channelID.uuidString
                recordSystemChannel(key)
                return key
            } catch let error as SystemHelperError {
                switch error {
                case .unavailable:
                    // Connection interrupted or helper disabled mid-flight:
                    // degrade to the legacy helper (plan P8 safe-degradation).
                    break
                case .approvalRequired:
                    throw VoWiFiError.transport(localized("systemhelper.error.approval_required"))
                case .registrationFailed(let detail), .helperRejected(let detail):
                    throw transportError(detail)
                case .malformedReply:
                    throw transportError(nil)
                }
            }
        }
        try await ensureInstalled()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let remote = proxy(errorHandler: { continuation.resume(throwing: $0) })
            remote.openChannel(
                host: host,
                remotePort: Int(port),
                localPort: Int(port),
                withReply: { channelID, error in
                if let channelID {
                    continuation.resume(returning: channelID)
                } else {
                    continuation.resume(throwing: self.transportError(error))
                }
            })
        }
    }

    func send(channelID: String, payload: Data) async throws {
        if let uuid = systemUUID(for: channelID) {
            try await systemHelper.ikeSend(channelID: uuid, payload: payload)
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let remote = proxy(errorHandler: { continuation.resume(throwing: $0) })
            remote.send(
                channelID: channelID,
                payload: payload,
                withReply: { error in
                if let error {
                    continuation.resume(throwing: self.transportError(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive(channelID: String, timeout: TimeInterval) async throws -> Data {
        if let uuid = systemUUID(for: channelID) {
            return try await systemHelper.ikeReceive(channelID: uuid, timeout: timeout)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let remote = proxy(errorHandler: { continuation.resume(throwing: $0) })
            remote.receive(
                channelID: channelID,
                timeout: timeout,
                withReply: { data, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: self.transportError(error))
                }
            })
        }
    }

    func close(channelID: String) async {
        if let uuid = takeSystemUUID(for: channelID) {
            await systemHelper.ikeClose(channelID: uuid)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let remote = proxy(errorHandler: { _ in continuation.resume() })
            remote.close(channelID: channelID, withReply: {
                continuation.resume()
            })
        }
    }

    /// True while the legacy bless-installed helper files are still on disk.
    private var legacyHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: EC25IKEHelperConstants.installedExecutablePath)
            || FileManager.default.fileExists(atPath: EC25IKEHelperConstants.installedPlistPath)
    }

    private func recordSystemChannel(_ channelID: String) {
        lock.lock()
        systemChannelIDs.insert(channelID)
        lock.unlock()
    }

    private func systemUUID(for channelID: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard systemChannelIDs.contains(channelID) else { return nil }
        return UUID(uuidString: channelID)
    }

    private func takeSystemUUID(for channelID: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard systemChannelIDs.remove(channelID) != nil else { return nil }
        return UUID(uuidString: channelID)
    }

    private func ping() async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let remote = proxy(errorHandler: { continuation.resume(throwing: $0) })
            remote.protocolVersion(withReply: { continuation.resume(returning: $0) })
        }
    }

    private func proxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> EC25IKEHelperXPCProtocol {
        let connection = activeConnection()
        let object = connection.remoteObjectProxyWithErrorHandler { error in
            self.invalidateConnection()
            errorHandler(VoWiFiError.transport(error.localizedDescription))
        }
        guard let proxy = object as? EC25IKEHelperXPCProtocol else {
            fatalError("Invalid EC25 IKE helper XPC interface")
        }
        return proxy
    }

    private func activeConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let newConnection = NSXPCConnection(
            machServiceName: EC25IKEHelperConstants.label,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(with: EC25IKEHelperXPCProtocol.self)
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

    private func installBundledHelper() async throws {
        let command = [
            "/bin/launchctl bootout system/\(EC25IKEHelperConstants.label) >/dev/null 2>&1 || true",
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(shellQuote(bundledHelperURL.path)) \(shellQuote(EC25IKEHelperConstants.installedExecutablePath))",
            "/usr/bin/install -o root -g wheel -m 644 \(shellQuote(bundledPlistURL.path)) \(shellQuote(EC25IKEHelperConstants.installedPlistPath))",
            "/bin/launchctl bootstrap system \(shellQuote(EC25IKEHelperConstants.installedPlistPath))",
            "/bin/launchctl enable system/\(EC25IKEHelperConstants.label)",
            "/bin/launchctl kickstart -k system/\(EC25IKEHelperConstants.label)"
        ].joined(separator: "; ")
        let script = "on run argv\n do shell script (item 1 of argv) with administrator privileges\nend run"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, command]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VoWiFiError.transport(
                detail?.isEmpty == false ? detail! : localized("vowifi.error.helper_install")
            )
        }
        invalidateConnection()
    }

    private var bundledHelperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools")
            .appendingPathComponent(EC25IKEHelperConstants.executableName)
    }

    private var bundledPlistURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent(EC25IKEHelperConstants.bundledPlistName)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func transportError(_ detail: String?) -> VoWiFiError {
        VoWiFiError.transport(detail ?? localized("vowifi.error.helper_unavailable"))
    }
}
