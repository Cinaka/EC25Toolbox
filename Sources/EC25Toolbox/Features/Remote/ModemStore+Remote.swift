import Foundation

extension ModemStore {
    func configureTransportFromSettings() {
        // A descriptor-scoped store must never fall back to another local
        // module or turn into a duplicate remote session when app-wide remote
        // preferences change. The coordinator exposes remote access through
        // its descriptor-less session.
        if moduleDescriptor != nil {
            state.remoteManagement.mode = .direct
            state.remoteManagement.connectedEndpoint = ""
            state.remoteManagement.lastError = nil
            transport = localTransport
            return
        }
        let mode = settings.effectiveManagementMode
        state.remoteManagement.mode = mode
        state.remoteManagement.connectedEndpoint = ""
        state.remoteManagement.lastError = nil

        guard mode == .remote else {
            transport = localTransport
            return
        }
        let host = trimmed(settings.remoteHost ?? "")
        let port = settings.effectiveRemotePort
        guard !host.isEmpty else {
            let error = RemoteManagementError.invalidHost
            transport = UnavailableRemoteTransport(error: error)
            state.remoteManagement.lastError = error.localizedDescription
            return
        }
        do {
            guard let secret = try RemoteAccessKeychain.clientSecret(host: host, port: port) else {
                throw RemoteManagementError.missingPairingKey
            }
            transport = RemoteModemTransport(host: host, port: port, secret: secret)
            state.remoteManagement.connectedEndpoint = "\(host):\(port)"
        } catch {
            let remoteError = error as? RemoteManagementError ?? .connectionFailed(error.localizedDescription)
            transport = UnavailableRemoteTransport(error: remoteError)
            state.remoteManagement.lastError = error.localizedDescription
        }
    }

    func configureDirectMode(lanPort: Int, tailscalePort: Int, sharingEnabled: Bool) {
        run {
            try self.validateRemotePort(lanPort)
            try self.validateRemotePort(tailscalePort)
            let switchingFromRemote = self.settings.effectiveManagementMode == .remote
            if switchingFromRemote {
                await self.transport.disconnect()
            }
            self.updateSettings {
                $0.managementMode = nil
                $0.remoteLANPort = lanPort == RemoteDefaults.lanPort ? nil : lanPort
                $0.remoteTailscalePort = tailscalePort == RemoteDefaults.tailscalePort ? nil : tailscalePort
                $0.remoteSharingEnabled = sharingEnabled ? nil : false
            }
            // Under the multi-session coordinator, the descriptor-less store
            // represents remote mode only. Discovery selects/starts a
            // hardware-scoped direct store, avoiding a second unscoped USB
            // claimant racing the module sessions.
            if self.moduleDescriptor == nil, self.settingsDidChange != nil {
                self.transport = self.localTransport
                self.state.remoteManagement.mode = .direct
                self.state.remoteManagement.connectedEndpoint = ""
                await self.markDisconnected(logRemoval: false)
                return
            }
            self.transport = self.localTransport
            self.state.remoteManagement.mode = .direct
            self.state.remoteManagement.connectedEndpoint = ""
            self.startRemoteSharingIfNeeded()
            if switchingFromRemote || !self.state.connected {
                try await self.connectImpl(prefix: localized("log.reconnected"))
            }
        }
    }

    func configureRemoteMode(host: String, port: Int, pairingKey: String) {
        run {
            let host = trimmed(host)
            guard !host.isEmpty, host.count <= 255 else { throw RemoteManagementError.invalidHost }
            try self.validateRemotePort(port)

            let secret: Data
            if let suppliedKey = firstPresent(pairingKey) {
                secret = try RemoteAccessKeychain.decodedPairingKey(suppliedKey)
                try RemoteAccessKeychain.saveClientSecret(secret, host: host, port: port)
            } else if let stored = try RemoteAccessKeychain.clientSecret(host: host, port: port) {
                secret = stored
            } else {
                throw RemoteManagementError.missingPairingKey
            }

            // A hardware-scoped store stays attached to its physical module.
            // Persist the app-wide remote preferences and let the coordinator
            // activate its descriptor-less remote session.
            if self.moduleDescriptor != nil, self.settingsDidChange != nil {
                self.updateSettings {
                    $0.managementMode = .remote
                    $0.remoteHost = host
                    $0.remotePort = port == RemoteDefaults.lanPort ? nil : port
                }
                return
            }

            await self.transport.disconnect()
            self.stopRemoteSharing()
            self.updateSettings {
                $0.managementMode = .remote
                $0.remoteHost = host
                $0.remotePort = port == RemoteDefaults.lanPort ? nil : port
            }
            self.transport = RemoteModemTransport(host: host, port: port, secret: secret)
            self.state.remoteManagement.mode = .remote
            self.state.remoteManagement.connectedEndpoint = "\(host):\(port)"
            self.state.remoteManagement.lastError = nil
            try await self.connectImpl(prefix: localized("remote.log.connected"))
        }
    }

    func restartRemoteSharing() {
        guard settings.effectiveManagementMode == .direct else { return }
        startRemoteSharingIfNeeded()
    }

    func rotateRemotePairingKey() {
        guard settings.effectiveManagementMode == .direct else { return }
        do {
            _ = try RemoteAccessKeychain.rotateServerSecret()
            startRemoteSharingIfNeeded()
        } catch {
            state.remoteManagement.lastError = error.localizedDescription
        }
    }

    func startRemoteSharingIfNeeded() {
        stopRemoteSharing()
        guard ownsGlobalServices else { return }
        state.remoteManagement.mode = settings.effectiveManagementMode
        guard settings.effectiveManagementMode == .direct,
              settings.effectiveRemoteSharingEnabled else { return }
        do {
            let secret = try RemoteAccessKeychain.serverSecret()
            let server = RemoteManagementServer(
                transport: localTransport,
                audioService: callAudioService,
                usbSessionRepairHandler: { [weak self] in
                    guard let self else { throw RemoteManagementError.serverUnavailable }
                    return try await self.repairLocalUSBSessionForRemoteClient()
                }
            )
            let endpoints = try server.start(
                lanPort: settings.effectiveRemoteLANPort,
                tailscalePort: settings.effectiveRemoteTailscalePort,
                secret: secret
            ) { [weak self] detail in
                Task { @MainActor in
                    self?.state.remoteManagement.lastError = localizedFormat("remote.error.listener", detail)
                }
            }
            remoteServer = server
            state.remoteManagement.sharingActive = true
            state.remoteManagement.listeningEndpoints = endpoints
            state.remoteManagement.pairingKey = RemoteAccessKeychain.encodedPairingKey(secret)
            state.remoteManagement.lastError = nil
        } catch {
            state.remoteManagement.sharingActive = false
            state.remoteManagement.listeningEndpoints = []
            state.remoteManagement.pairingKey = ""
            state.remoteManagement.lastError = error.localizedDescription
        }
    }

    func stopRemoteSharing() {
        remoteServer?.stop()
        remoteServer = nil
        state.remoteManagement.sharingActive = false
        state.remoteManagement.listeningEndpoints = []
        state.remoteManagement.pairingKey = ""
    }

    /// Restores the host application's complete direct-mode session after a
    /// remote, confirmed module-configuration change re-enumerates USB. This
    /// keeps host UI state, pollers, and unsolicited-event subscriptions in
    /// sync with the repaired server transport before the remote client
    /// continues its own initialization.
    private func repairLocalUSBSessionForRemoteClient() async throws -> String {
        guard settings.effectiveManagementMode == .direct else {
            throw RemoteManagementError.serverUnavailable
        }
        try await connectImpl(prefix: localized("moduleconfig.log.reconnected"))
        return state.usbDescription
    }

    private func validateRemotePort(_ port: Int) throws {
        guard (1...65_535).contains(port) else { throw RemoteManagementError.invalidPort }
    }
}
