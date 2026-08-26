import Foundation

extension ModemStore {
    func setVoWiFiEnabled(_ enabled: Bool) {
        updateSettings { $0.vowifiEnabled = enabled ? true : nil }
        if enabled {
            state.vowifi.phase = .waitingForSIM
            ensureVoWiFiStarted(force: true)
        } else {
            vowifiTask?.cancel()
            vowifiTask = Task { @MainActor in
                await self.stopVoWiFiSession(resetPhase: .disabled)
            }
        }
    }

    func reconnectVoWiFi() {
        ensureVoWiFiStarted(force: true)
    }

    func saveVoWiFiSettings(
        autoConnect: Bool,
        epdgAddress: String,
        pcscfAddress: String,
        realm: String,
        privateIdentity: String,
        publicIdentity: String
    ) {
        updateSettings { settings in
            settings.vowifiAutoConnect = autoConnect ? nil : false
            settings.vowifiEPDGAddress = firstPresent(epdgAddress)
            settings.vowifiPCSCFAddress = firstPresent(pcscfAddress)
            settings.vowifiIMSRealm = firstPresent(realm)
            settings.vowifiPrivateIdentity = firstPresent(privateIdentity)
            settings.vowifiPublicIdentity = firstPresent(publicIdentity)
        }
        if settings.effectiveVoWiFiEnabled { ensureVoWiFiStarted(force: true) }
    }

    func ensureVoWiFiStarted(force: Bool = false) {
        guard settings.effectiveVoWiFiEnabled else {
            state.vowifi.phase = .disabled
            return
        }
        guard state.connected, state.simSecurity.isReady else {
            state.vowifi.phase = .waitingForSIM
            return
        }
        let iccid = trimmed(state.info.iccid)
        guard !iccid.isEmpty, iccid != "-" else {
            state.vowifi.phase = .waitingForSIM
            return
        }
        if !force, vowifiTask != nil, vowifiSessionICCID == iccid { return }

        vowifiTask?.cancel()
        vowifiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopVoWiFiSession(resetPhase: .waitingForSIM, cancelTask: false)
            self.vowifiSessionICCID = iccid
            var attempt = 0
            repeat {
                if Task.isCancelled { return }
                do {
                    try await self.startVoWiFiSession()
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if let ims = self.vowifiIMSClient { await ims.stop() }
                    if let plane = self.vowifiDataPlane { await plane.stop() }
                    self.vowifiIMSClient = nil
                    self.vowifiDataPlane = nil
                    self.state.vowifi.lastError = error.localizedDescription
                    self.appendVoWiFiLog(error.localizedDescription, kind: .failure)
                    guard self.settings.effectiveVoWiFiAutoConnect,
                          self.settings.effectiveVoWiFiEnabled,
                          self.state.connected else {
                        self.state.vowifi.phase = .failed
                        return
                    }
                    attempt += 1
                    self.state.vowifi.phase = .reconnecting
                    self.state.vowifi.reconnectAttempt = attempt
                    let delay = min(60, 2 << min(attempt, 5))
                    try? await Task.sleep(for: .seconds(delay))
                }
            } while !Task.isCancelled
        }
    }

    func stopVoWiFiSession(
        resetPhase: VoWiFiPhase,
        cancelTask: Bool = true
    ) async {
        if cancelTask { vowifiTask?.cancel() }
        if let ims = vowifiIMSClient { await ims.stop() }
        if let plane = vowifiDataPlane { await plane.stop() }
        vowifiIMSClient = nil
        vowifiDataPlane = nil
        vowifiSessionICCID = nil
        state.vowifi.phase = resetPhase
        state.vowifi.tunnel = VoWiFiTunnelSnapshot()
        if resetPhase == .disabled { state.vowifi.identity = nil }
        if cancelTask { vowifiTask = nil }
    }

    private func startVoWiFiSession() async throws {
        guard state.connected else { throw VoWiFiError.modemUnavailable }
        guard state.simSecurity.isReady else { throw VoWiFiError.simNotReady }
        state.vowifi.lastError = nil
        state.vowifi.phase = .readingIdentity
        appendVoWiFiLog(localized("vowifi.log.reading_identity"), kind: .info)

        let imsi = trimmed(state.info.imsi)
        let simAccess = VoWiFiSIMAccess(store: self)
        let mncLength = try? await simAccess.readMNCLength()
        var configuration = try VoWiFiCarrierConfiguration.derived(
            imsi: imsi,
            mncLength: mncLength,
            epdgOverride: settings.vowifiEPDGAddress,
            pcscfOverride: settings.vowifiPCSCFAddress,
            realmOverride: settings.vowifiIMSRealm,
            privateIdentityOverride: settings.vowifiPrivateIdentity,
            publicIdentityOverride: settings.vowifiPublicIdentity
        )
        var identity: VoWiFiIdentity
        do {
            identity = try await simAccess.readISIMIdentity()
            identity.imsi = imsi
            identity.mcc = configuration.mcc
            identity.mnc = configuration.mnc
            if identity.impi.isEmpty { identity.impi = configuration.privateIdentity }
            if identity.impu.isEmpty { identity.impu = configuration.publicIdentity }
            if identity.realm.isEmpty { identity.realm = configuration.realm }
        } catch {
            identity = VoWiFiIdentity(
                imsi: imsi, mcc: configuration.mcc, mnc: configuration.mnc,
                impi: configuration.privateIdentity, impu: configuration.publicIdentity,
                realm: configuration.realm,
                source: settings.vowifiPrivateIdentity != nil || settings.vowifiPublicIdentity != nil
                    ? .manual : .derivedUSIM
            )
            appendVoWiFiLog(localizedFormat("vowifi.log.isim_fallback", error.localizedDescription), kind: .warning)
        }

        state.vowifi.phase = .discoveringEPDG
        appendVoWiFiLog(localizedFormat("vowifi.log.resolving_epdg", configuration.epdgAddress), kind: .info)
        let resolver = VoWiFiEPDGResolver()
        let addresses: [String]
        do {
            addresses = try await resolver.resolve(configuration: configuration)
        } catch {
            // EF_AD is not readable on every removable eUICC/modem bridge.
            // If its MNC length is unavailable, try the two-digit home MNC
            // before reporting failure. 3GPP domains still pad it to 3 digits.
            guard mncLength == nil,
                  firstPresent(settings.vowifiEPDGAddress ?? "") == nil else {
                throw error
            }
            let twoDigitConfiguration = try VoWiFiCarrierConfiguration.derived(
                imsi: imsi,
                mncLength: 2,
                epdgOverride: settings.vowifiEPDGAddress,
                pcscfOverride: settings.vowifiPCSCFAddress,
                realmOverride: settings.vowifiIMSRealm,
                privateIdentityOverride: settings.vowifiPrivateIdentity,
                publicIdentityOverride: settings.vowifiPublicIdentity
            )
            guard twoDigitConfiguration.epdgAddress != configuration.epdgAddress else {
                throw error
            }
            appendVoWiFiLog(
                localizedFormat("vowifi.log.resolving_epdg", twoDigitConfiguration.epdgAddress),
                kind: .warning
            )
            addresses = try await resolver.resolve(configuration: twoDigitConfiguration)
            configuration = twoDigitConfiguration
        }
        guard !addresses.isEmpty else {
            throw VoWiFiError.epdgResolutionFailed(configuration.epdgAddress)
        }

        identity.imsi = imsi
        identity.mcc = configuration.mcc
        identity.mnc = configuration.mnc
        if identity.source != .isim {
            identity.impi = configuration.privateIdentity
            identity.impu = configuration.publicIdentity
            identity.realm = configuration.realm
        } else {
            if identity.impi.isEmpty { identity.impi = configuration.privateIdentity }
            if identity.impu.isEmpty { identity.impu = configuration.publicIdentity }
            if identity.realm.isEmpty { identity.realm = configuration.realm }
        }
        guard identity.isComplete else { throw VoWiFiError.incompleteIdentity }
        state.vowifi.identity = identity
        state.vowifi.tunnel.epdgAddress = configuration.epdgAddress

        let ike = VoWiFiIKEClient(simAccess: simAccess)
        var establishedSession: VoWiFiIKESession?
        var lastIKEError: (any Error)?
        for (index, remoteAddress) in addresses.enumerated() {
            state.vowifi.tunnel.resolvedAddress = remoteAddress
            appendVoWiFiLog(
                localizedFormat(
                    "vowifi.log.epdg_attempt",
                    remoteAddress, index + 1, addresses.count
                ),
                kind: .info
            )
            do {
                establishedSession = try await ike.connect(
                    remoteAddress: remoteAddress,
                    identity: identity
                ) { phase, message in
                    self.state.vowifi.phase = phase
                    self.appendVoWiFiLog(message, kind: .info)
                }
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastIKEError = error
                appendVoWiFiLog(
                    localizedFormat(
                        "vowifi.log.epdg_attempt_failed",
                        remoteAddress, error.localizedDescription
                    ),
                    kind: .warning
                )
            }
        }
        guard let session = establishedSession else {
            throw lastIKEError ?? VoWiFiError.epdgResolutionFailed(configuration.epdgAddress)
        }
        state.vowifi.tunnel.innerAddress = session.innerAddress
        state.vowifi.tunnel.ikeSPI = String(format: "%016llX", session.initiatorSPI)
        state.vowifi.tunnel.childSPI = String(format: "%08X", session.childSA.localSPI)
        state.vowifi.tunnel.natDetected = session.natDetected
        state.vowifi.tunnel.establishedAt = session.establishedAt

        let pcscfHost = firstPresent(settings.vowifiPCSCFAddress ?? "")
            ?? session.pcscfAddresses.first
        guard let pcscfHost, !pcscfHost.isEmpty else {
            throw VoWiFiError.missingTunnelConfiguration
        }

        let plane = VoWiFiDataPlane(session: session)
        vowifiDataPlane = plane
        await plane.start { error in
            await MainActor.run {
                self.state.vowifi.lastError = error.localizedDescription
                self.appendVoWiFiLog(error.localizedDescription, kind: .failure)
                if self.settings.effectiveVoWiFiAutoConnect { self.ensureVoWiFiStarted(force: true) }
            }
        }
        let pcscf: String
        if VoWiFiIPv4.isAddress(pcscfHost) {
            pcscf = pcscfHost
        } else {
            guard let dns = session.dnsAddresses.first else {
                throw VoWiFiError.missingTunnelConfiguration
            }
            pcscf = try await VoWiFiDNSResolver(dataPlane: plane).resolveIPv4(
                host: pcscfHost, server: dns
            )
        }
        state.vowifi.tunnel.pcscfAddress = pcscf
        state.vowifi.phase = .registeringIMS
        let ims = IMSClient(
            dataPlane: plane, simAccess: simAccess, identity: identity,
            pcscfAddress: pcscf, innerAddress: session.innerAddress,
            localPort: 5060,
            smsHandler: { sms in
                await MainActor.run { self.archiveVoWiFiSMS(sms) }
            },
            logHandler: { message in
                await MainActor.run { self.appendVoWiFiLog(message, kind: .info) }
            },
            failureHandler: { error in
                await MainActor.run {
                    self.state.vowifi.lastError = error.localizedDescription
                    self.appendVoWiFiLog(error.localizedDescription, kind: .failure)
                    if self.settings.effectiveVoWiFiAutoConnect {
                        self.ensureVoWiFiStarted(force: true)
                    }
                }
            }
        )
        vowifiIMSClient = ims
        _ = try await ims.start()
        state.vowifi.phase = .registered
        state.vowifi.lastConnectedAt = Date()
        state.vowifi.reconnectAttempt = 0
        appendVoWiFiLog(localized("vowifi.log.ready"), kind: .success)
    }

    private func archiveVoWiFiSMS(_ sms: IMSDecodedSMS) {
        let scope = currentSIMMessageScopeForVoWiFi()
        guard scope.isIdentified else {
            state.vowifi.lastError = VoWiFiError.incompleteIdentity.localizedDescription
            return
        }
        do {
            try smsArchiveForVoWiFi().addReceived(
                from: sms.sender, body: sms.body,
                receivedAt: sms.timestamp, scope: scope,
                moduleID: moduleIdentifier
            )
            state.messages = smsArchiveForVoWiFi().messages(in: scope.id)
            state.smsBackup = smsArchiveForVoWiFi().state
            state.unreadCount = state.messages.filter(\.unread).count
            state.vowifi.receivedSMSCount += 1
            appendVoWiFiLog(localizedFormat("vowifi.log.sms_received", sms.sender), kind: .success)
        } catch {
            state.vowifi.lastError = error.localizedDescription
        }
    }

    private func appendVoWiFiLog(_ message: String, kind: VoWiFiLogEntry.Kind) {
        state.vowifi.logs.append(VoWiFiLogEntry(kind: kind, message: message))
        if state.vowifi.logs.count > 300 {
            state.vowifi.logs.removeFirst(state.vowifi.logs.count - 300)
        }
    }

    // Narrow accessors keep the archive and scope private to ModemStore while
    // allowing this feature extension to preserve the existing storage rules.
    private func currentSIMMessageScopeForVoWiFi() -> SIMMessageScope {
        SIMMessageScope(eid: state.estk.chipInfo?.eidValue, iccid: state.info.iccid)
    }

    private func smsArchiveForVoWiFi() -> SMSArchiveStore { smsArchive }
}
