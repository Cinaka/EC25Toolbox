import Foundation

private enum ESTKProbeResult: Equatable {
    case available
    case unavailable
    case indeterminate
}

/// Profile switching can reset the active UICC session after lpac has already
/// reported success. Wait for a new eUICC session to become usable instead of
/// treating the first transient `euicc_init` failure as a failed switch.
@MainActor
func retryESTKProfileRefresh(
    attempts: Int = 6,
    delay: Duration = .seconds(2),
    _ refresh: () async throws -> Bool
) async throws {
    precondition(attempts > 0)
    var lastError: Error?

    for attempt in 0..<attempts {
        if attempt > 0 {
            try await Task.sleep(for: delay)
        }
        do {
            if try await refresh() {
                return
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
        }
    }

    throw lastError ?? ESTKError.profileStateRefreshPending
}

/// eSTK/eUICC actions backed by lpac and bridged to the existing native USB transport.
extension ModemStore {
    /// Probes the current ICCID once and exposes eSTK only when the ISD-R
    /// application can be selected on that SIM.
    func refreshESTKAvailabilityIfNeeded() async {
        let iccid = trimmed(state.info.iccid)
        guard state.simSecurity.isReady, !iccid.isEmpty, iccid != "-" else {
            // Keep a previously confirmed card type through transient modem
            // disconnects and PIN-locked states. The next readable ICCID is
            // compared with estkDetectionICCID and re-probed if it changed.
            return
        }
        let needsProbe = estkDetectionICCID != iccid || state.estk.availability == .unknown
        var probeResult: ESTKProbeResult?
        if needsProbe {
            estkDetectionICCID = iccid
            state.estk.availability = .checking
            let result = await probeESTKISDR()
            probeResult = result
            switch result {
            case .available:
                state.estk.availability = .available
            case .unavailable:
                state.estk.availability = .unavailable
            case .indeterminate:
                state.estk.availability = state.estk.chipInfo == nil ? .unknown : .available
            }
        }

        guard state.estk.availability == .available,
              state.estk.chipInfo == nil,
              probeResult != .indeterminate else { return }
        do {
            try await refreshESTKImpl(refreshMessages: false)
        } catch {
            state.estk.lastError = error.localizedDescription
        }
    }

    func refreshESTK() {
        runESTK(operation: "refresh", refreshing: true) {
            try await self.refreshESTKImpl()
        }
    }

    func downloadESTKProfile(activationCode: String, confirmationCode: String) {
        downloadESTKProfile(ESTKDownloadRequest(
            activationCode: activationCode,
            smdpAddress: "",
            matchingID: "",
            confirmationCode: confirmationCode
        ))
    }

    func downloadESTKProfile(_ request: ESTKDownloadRequest) {
        runESTK(operation: "profile.download") {
            let client = try self.makeLPACClient()
            let previousNotifications = Set(self.state.estk.notifications.map(\.seqNumber))
            let arguments = try validatedESTKDownloadArguments(request, imei: self.state.info.imei)

            do {
                try await client.runVoid(arguments)
            } catch {
                let downloadError = error
                if self.settings.effectiveESTKNotifyDownloads {
                    await self.processNewESTKNotifications(
                        after: previousNotifications,
                        operations: ["install"],
                        client: client
                    )
                }
                do {
                    try await self.refreshESTKImpl(client: client, refreshMessages: false)
                } catch {
                    self.appendESTKLog(error.localizedDescription, kind: .failure)
                }
                throw downloadError
            }
            if self.settings.effectiveESTKNotifyDownloads {
                await self.processNewESTKNotifications(
                    after: previousNotifications,
                    operations: ["install"],
                    client: client
                )
            }
            try await self.refreshESTKImpl(client: client)
        }
    }

    func discoverESTKProfiles(smdsAddress: String) {
        runESTK(operation: "profile.discovery") {
            let client = try self.makeLPACClient()
            var arguments = ["profile", "discovery"]
            if let smds = firstPresent(smdsAddress) {
                arguments.append(contentsOf: ["-s", smds])
            }
            if let imei = firstPresent(self.state.info.imei) {
                arguments.append(contentsOf: ["-i", imei])
            }
            let addresses = try await client.run(arguments, decoding: [String].self)
            self.state.estk.discoveryResults = addresses
                .compactMap(firstPresent)
                .map { ESTKDiscoveryResult(address: $0) }
        }
    }

    func setESTKDefaultSMDP(address: String) {
        runESTK(operation: "chip.defaultsmdp") {
            guard let address = firstPresent(address) else {
                throw ESTKError.invalidDownloadParameters
            }
            let client = try self.makeLPACClient()
            try await client.runVoid(["chip", "defaultsmdp", address])
            try await self.refreshESTKImpl(client: client, refreshMessages: false)
        }
    }

    func setESTKProfileEnabled(_ profile: ESTKProfile, enabled: Bool) {
        runESTK(operation: enabled ? "profile.enable" : "profile.disable") {
            let client = try self.makeLPACClient()
            let command = enabled ? "enable" : "disable"
            let profileIdentifier = profile.operationIdentifier
            let previousNotifications = Set(self.state.estk.notifications.map(\.seqNumber))
            try await client.runVoid(["profile", command, profileIdentifier])

            do {
                try await retryESTKProfileRefresh {
                    let profiles = try await client.run(
                        ["profile", "list"],
                        decoding: [ESTKProfile].self
                    )
                    guard profiles.contains(where: {
                        $0.operationIdentifier.caseInsensitiveCompare(profileIdentifier) == .orderedSame
                            && $0.isEnabled == enabled
                    }) else {
                        return false
                    }
                    try await self.refreshESTKImpl(client: client)
                    return true
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The mutation already succeeded. Keep it as a successful
                // operation and expose only the remaining state-sync issue.
                self.state.estk.warning = localized("estk.warning.profile_refresh_pending")
                self.appendESTKLog(error.localizedDescription, kind: .failure)
            }

            if self.settings.effectiveESTKNotifySwitches {
                await self.processNewESTKNotifications(
                    after: previousNotifications,
                    operations: [command],
                    client: client
                )
            }
        }
    }

    func renameESTKProfile(_ profile: ESTKProfile, nickname: String) {
        runESTK(operation: "profile.nickname") {
            let cleanNickname = trimmed(nickname)
            guard !cleanNickname.isEmpty else {
                throw ESTKError.lpacFailure(localized("estk.error.nickname_empty"))
            }
            let client = try self.makeLPACClient()
            try await client.runVoid(["profile", "nickname", profile.operationIdentifier, cleanNickname])
            try await self.refreshESTKImpl(client: client)
        }
    }

    func deleteESTKProfile(_ profile: ESTKProfile) {
        runESTK(operation: "profile.delete") {
            let client = try self.makeLPACClient()
            let previousNotifications = Set(self.state.estk.notifications.map(\.seqNumber))
            try await client.runVoid(["profile", "delete", profile.operationIdentifier])
            if self.settings.effectiveESTKNotifyDeletions {
                await self.processNewESTKNotifications(
                    after: previousNotifications,
                    operations: ["delete"],
                    client: client
                )
            }
            try await self.refreshESTKImpl(client: client)
        }
    }

    func processESTKNotification(_ notification: ESTKNotification, removeAfter: Bool = true) {
        runESTK(operation: "notification.process") {
            let client = try self.makeLPACClient()
            var arguments = ["notification", "process"]
            if removeAfter { arguments.append("-r") }
            arguments.append(String(notification.seqNumber))
            try await client.runVoid(arguments)
            try await self.refreshESTKImpl(client: client)
        }
    }

    func deleteESTKNotification(_ notification: ESTKNotification) {
        runESTK(operation: "notification.remove") {
            let client = try self.makeLPACClient()
            try await client.runVoid([
                "notification", "remove", String(notification.seqNumber)
            ])
            try await self.refreshESTKImpl(client: client)
        }
    }

    func processAllESTKNotifications() {
        runESTK(operation: "notification.process_all") {
            let client = try self.makeLPACClient()
            let notifications = try await client.run(
                ["notification", "list"],
                decoding: [ESTKNotification].self
            )
            var failures: [String] = []
            for notification in notifications.sorted(by: { $0.seqNumber < $1.seqNumber }) {
                do {
                    try await client.runVoid([
                        "notification", "process", "-r", String(notification.seqNumber)
                    ])
                } catch {
                    let address = firstPresent(notification.notificationAddress) ?? "-"
                    failures.append(
                        "#\(notification.seqNumber) \(address): \(error.localizedDescription)"
                    )
                }
            }
            if failures.isEmpty {
                try await self.refreshESTKImpl(client: client)
            } else {
                let failureCount = failures.count
                do {
                    try await self.refreshESTKImpl(client: client)
                } catch {
                    failures.append(error.localizedDescription)
                }
                throw ESTKError.notificationBatchFailure(
                    failureCount,
                    failures.joined(separator: "\n")
                )
            }
        }
    }

    func deleteAllESTKNotifications() {
        runESTK(operation: "notification.remove_all") {
            let client = try self.makeLPACClient()
            try await client.runVoid(["notification", "remove", "-a"])
            try await self.refreshESTKImpl(client: client)
        }
    }

    func deleteESTKNotifications(operation: String) {
        runESTK(operation: "notification.remove_batch") {
            let sequenceNumbers = self.state.estk.notifications
                .filter { $0.profileManagementOperation.caseInsensitiveCompare(operation) == .orderedSame }
                .map { String($0.seqNumber) }
            guard !sequenceNumbers.isEmpty else { return }
            let client = try self.makeLPACClient()
            try await client.runVoid(["notification", "remove"] + sequenceNumbers)
            try await self.refreshESTKImpl(client: client)
        }
    }

    func purgeESTKMemory() {
        runESTK(operation: "chip.purge") {
            let client = try self.makeLPACClient()
            try await client.runVoid(["chip", "purge", "yes"])
            self.state.estk.chipInfo = nil
            self.state.estk.profiles = []
            self.state.estk.profileMetadata = [:]
            self.state.estk.notifications = []
            self.state.estk.rawChipInfo = ""
            self.state.estk.discoveryResults = []
            try await self.refreshESTKImpl(client: client)
        }
    }

    func saveESTKSettings(
        isdRAID: String,
        es10xMSS: Int,
        notifyDownloads: Bool,
        notifyDeletions: Bool,
        notifySwitches: Bool,
        httpProxy: String,
        ignoreTLSCertificate: Bool
    ) {
        let cleanAID = trimmed(isdRAID).uppercased()
        updateSettings { settings in
            settings.estkISDRAID = cleanAID == ESTKDefaults.isdRAID ? nil : cleanAID
            settings.estkES10xMSS = es10xMSS == ESTKDefaults.es10xMSS ? nil : es10xMSS
            settings.estkNotifyDownloads = notifyDownloads == true ? nil : false
            settings.estkNotifyDeletions = notifyDeletions == true ? nil : false
            settings.estkNotifySwitches = notifySwitches == false ? nil : true
            settings.estkHTTPProxy = firstPresent(httpProxy)
            settings.estkIgnoreTLSCertificate = ignoreTLSCertificate ? true : nil
        }
        state.estk = ESTKState()
        estkAPDUBackend = nil
        refreshESTK()
    }

    func saveESTKSettings(isdRAID: String, es10xMSS: Int) {
        saveESTKSettings(
            isdRAID: isdRAID,
            es10xMSS: es10xMSS,
            notifyDownloads: settings.effectiveESTKNotifyDownloads,
            notifyDeletions: settings.effectiveESTKNotifyDeletions,
            notifySwitches: settings.effectiveESTKNotifySwitches,
            httpProxy: settings.estkHTTPProxy ?? "",
            ignoreTLSCertificate: settings.estkIgnoreTLSCertificate ?? false
        )
    }

    private func runESTK(
        operation name: String,
        refreshing: Bool = false,
        _ operation: @escaping () async throws -> Void
    ) {
        guard state.connected else {
            state.estk.lastError = localized("estk.disconnected.description")
            return
        }
        let wrappedOperation = {
            self.state.estk.lastError = nil
            self.state.estk.warning = nil
            self.appendESTKLog(name, kind: .progress)
            do {
                try await operation()
                self.appendESTKLog(name, kind: .success)
            } catch {
                self.state.estk.lastError = error.localizedDescription
                self.appendESTKLog("\(name): \(error.localizedDescription)", kind: .failure)
                throw error
            }
        }
        if refreshing {
            runRefresh(wrappedOperation)
        } else {
            run(wrappedOperation)
        }
    }

    private func refreshESTKImpl(client: LPACClient? = nil, refreshMessages: Bool = true) async throws {
        let client = try client ?? makeLPACClient()
        let version = try await client.run(["version"], decoding: String.self)
        let chipResult = try await client.runWithRaw(["chip", "info"], decoding: ESTKChipInfo.self)
        let profiles = try await client.run(["profile", "list"], decoding: [ESTKProfile].self)
        let notifications = try await client.run(
            ["notification", "list"],
            decoding: [ESTKNotification].self
        )

        state.estk.lpacVersion = version
        state.estk.chipInfo = chipResult.value
        state.estk.rawChipInfo = chipResult.rawJSON
        state.estk.profiles = profiles.filter { !trimmed($0.operationIdentifier).isEmpty }
        state.estk.notifications = notifications.sorted { $0.seqNumber > $1.seqNumber }
        syncProfileMetadata(pruneToCurrentProfiles: true)
        state.estk.availability = .available
        state.estk.lastUpdated = Date()
        state.estk.lastError = nil
        if refreshMessages, state.simSecurity.isReady {
            try? await refreshMessagesImpl()
        }
    }

    /// Reloads Mac-local profile metadata into the eSTK state. After every
    /// profile-list refresh, records whose ICCID disappeared (deleted or
    /// re-downloaded profile) are pruned so stale details never attach to a
    /// future profile with the same slot.
    private func syncProfileMetadata(pruneToCurrentProfiles: Bool) {
        let eid = trimmed(state.estk.chipInfo?.eidValue)
        let records: [ProfileMetadata]
        if pruneToCurrentProfiles, !eid.isEmpty {
            records = profileMetadataStore.prune(
                eid: eid,
                keepingICCIDs: state.estk.profiles.map(\.iccid)
            )
        } else {
            records = eid.isEmpty ? [] : profileMetadataStore.records(eid: eid)
        }
        state.estk.profileMetadata = Dictionary(
            records.map { ($0.iccid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Saves (or, when emptied, removes) Mac-local details for one profile.
    func saveProfileMetadata(_ record: ProfileMetadata) {
        profileMetadataStore.upsert(record)
        syncProfileMetadata(pruneToCurrentProfiles: false)
    }

    func removeProfileMetadata(eid: String, iccid: String) {
        profileMetadataStore.remove(eid: eid, iccid: iccid)
        syncProfileMetadata(pruneToCurrentProfiles: false)
    }

    private func makeLPACClient() throws -> LPACClient {
        let aid = firstPresent(settings.estkISDRAID ?? "") ?? ESTKDefaults.isdRAID
        let mss = settings.estkES10xMSS ?? ESTKDefaults.es10xMSS
        let client = try LPACClient(
            executablePath: nil,
            isdRAID: aid,
            es10xMSS: mss,
            httpProxy: settings.estkHTTPProxy,
            ignoreTLSCertificate: settings.estkIgnoreTLSCertificate ?? false,
            trustedRootKeyIDs: state.estk.chipInfo?.extendedInfo?.euiccCiPKIdListForVerification ?? [],
            progressHandler: { message in
                self.appendESTKLog(message, kind: .progress)
            }
        ) { request in
            await self.handleESTKAPDU(request)
        }
        return client
    }

    private func processNewESTKNotifications(
        after previousNotifications: Set<Int>,
        operations: Set<String>,
        client: LPACClient
    ) async {
        do {
            let notifications = try await client.run(
                ["notification", "list"],
                decoding: [ESTKNotification].self
            )
            let pending = notifications.filter {
                !previousNotifications.contains($0.seqNumber)
                    && operations.contains($0.profileManagementOperation.lowercased())
            }
            for notification in pending {
                do {
                    try await client.runVoid([
                        "notification", "process", "-r", String(notification.seqNumber)
                    ])
                } catch {
                    state.estk.warning = localizedFormat(
                        "estk.warning.notification_pending",
                        notification.seqNumber
                    )
                }
            }
        } catch {
            appendESTKLog(error.localizedDescription, kind: .failure)
        }
    }

    private func appendESTKLog(_ message: String, kind: ESTKLogEntry.Kind) {
        guard let message = firstPresent(message) else { return }
        state.estk.operationLog.append(ESTKLogEntry(kind: kind, message: message))
        if state.estk.operationLog.count > 200 {
            state.estk.operationLog.removeFirst(state.estk.operationLog.count - 200)
        }
    }

    private func handleESTKAPDU(_ request: LPACAPDURequest) async -> LPACAPDUResponse {
        do {
            switch request.function {
            case "connect":
                _ = await closeTrackedESTKLogicalChannels()
                _ = try await sendUnlogged("AT", timeout: 5_000)
                do {
                    _ = try await sendUnlogged("AT+CCHO=?", timeout: 5_000)
                    _ = try await sendUnlogged("AT+CGLA=?", timeout: 5_000)
                    _ = try await sendUnlogged("AT+CCHC=?", timeout: 5_000)
                    estkAPDUBackend = .logicalChannel
                } catch {
                    _ = try await sendUnlogged("AT+CSIM=?", timeout: 5_000)
                    estkAPDUBackend = .csim
                }
                state.estk.apduBackend = estkAPDUBackend
                updateESTKAPDUDiagnostic(operation: request.function, response: nil)
                return LPACAPDUResponse(errorCode: 0)

            case "disconnect":
                let failures = await closeTrackedESTKLogicalChannels()
                return LPACAPDUResponse(
                    errorCode: failures.isEmpty ? 0 : -1,
                    diagnostic: firstPresent(failures.joined(separator: " · "))
                )

            case "logic_channel_open":
                let aid = try normalizedHex(request.parameter)
                if estkAPDUBackend == .logicalChannel {
                    let lines = try await sendUnlogged("AT+CCHO=\"\(aid)\"", timeout: 30_000)
                    let channel = try parseESTKCCHOChannel(lines)
                    estkLogicalChannels[channel] = channel
                    updateESTKAPDUDiagnostic(operation: request.function, response: nil)
                    return LPACAPDUResponse(errorCode: Int(channel))
                }

                let openResponse = try await transmitESTKAPDU("0070000001")
                let openBytes = try hexBytes(openResponse)
                guard openBytes.count == 3,
                      openBytes[1] == 0x90,
                      openBytes[2] == 0x00 else {
                    throw ESTKError.malformedCSIMResponse
                }

                let channel = openBytes[0]
                let aidLength = aid.count / 2
                guard aidLength <= 255 else { throw ESTKError.malformedAPDURequest }
                let select = String(format: "%02X", channel)
                    + "A40400"
                    + String(format: "%02X", aidLength)
                    + aid
                let selectResponse = try await transmitESTKAPDU(select)
                let selectBytes = try hexBytes(selectResponse)
                guard selectBytes.count >= 2,
                      (selectBytes[selectBytes.count - 2] == 0x90
                        && selectBytes[selectBytes.count - 1] == 0x00)
                        || selectBytes[selectBytes.count - 2] == 0x61 else {
                    throw ESTKError.malformedCSIMResponse
                }
                return LPACAPDUResponse(errorCode: Int(channel))

            case "logic_channel_close":
                let parameter = try normalizedHex(request.parameter)
                guard let channel = UInt8(parameter, radix: 16) else {
                    throw ESTKError.malformedAPDURequest
                }
                if estkAPDUBackend == .logicalChannel {
                    let modemChannel = estkLogicalChannels[channel] ?? channel
                    try await closeESTKLogicalChannel(modemChannel, timeout: 30_000)
                    estkLogicalChannels.removeValue(forKey: channel)
                    updateESTKAPDUDiagnostic(operation: request.function, response: nil)
                } else {
                    let response = try await transmitESTKAPDU("007080" + String(format: "%02X", channel) + "00")
                    updateESTKAPDUDiagnostic(operation: request.function, response: response)
                }
                return LPACAPDUResponse(errorCode: 0)

            case "transmit":
                let response = try await transmitESTKAPDU(request.parameter)
                updateESTKAPDUDiagnostic(operation: request.function, response: response)
                return LPACAPDUResponse(errorCode: 0, data: response)

            default:
                throw ESTKError.unsupportedAPDUFunction(request.function)
            }
        } catch {
            state.estk.lastAPDUOperation = request.function
            state.estk.lastAPDUStatusWord = "ERROR"
            state.estk.lastAPDUResponseBytes = 0
            return LPACAPDUResponse(
                errorCode: -1,
                diagnostic: error.localizedDescription
            )
        }
    }

    private func probeESTKISDR() async -> ESTKProbeResult {
        let aid = firstPresent(settings.estkISDRAID ?? "") ?? ESTKDefaults.isdRAID

        do {
            let lines = try await sendUnlogged("AT+CCHO=\"\(aid)\"", timeout: 8_000)
            let channel = try parseESTKCCHOChannel(lines)
            _ = try? await sendUnlogged("AT+CCHC=\(channel)", timeout: 5_000)
            return .available
        } catch {
            // Some EC25 firmware exposes only CSIM, so retain a standards-based fallback.
        }

        do {
            let openResponse = try await transmitESTKAPDU("0070000001")
            let openBytes = try hexBytes(openResponse)
            guard openBytes.count == 3, openBytes[1] == 0x90, openBytes[2] == 0x00 else {
                return .indeterminate
            }

            let channel = openBytes[0]
            let cla = channel <= 3 ? channel : 0x40 | (channel - 4)
            let select = String(format: "%02X", cla)
                + "A40400"
                + String(format: "%02X", aid.count / 2)
                + aid
            let response = try await transmitESTKAPDU(select)
            _ = try? await transmitESTKAPDU("007080" + String(format: "%02X", channel) + "00")
            let bytes = try hexBytes(response)
            guard bytes.count >= 2 else { return .indeterminate }
            let sw1 = bytes[bytes.count - 2]
            let sw2 = bytes[bytes.count - 1]
            if (sw1 == 0x90 && sw2 == 0x00) || sw1 == 0x61 {
                return .available
            }
            return sw1 == 0x6A && sw2 == 0x82 ? .unavailable : .indeterminate
        } catch {
            return .indeterminate
        }
    }

    private func transmitESTKAPDU(_ command: String) async throws -> String {
        let command = try normalizedHex(command)
        if estkAPDUBackend == .logicalChannel {
            let channel = try estkLogicalChannel(fromAPDU: command)
            let modemChannel = estkLogicalChannels[channel] ?? channel
            let lines = try await sendUnlogged(
                "AT+CGLA=\(modemChannel),\(command.count),\"\(command)\"",
                timeout: 30_000
            )
            return try parseESTKAPDUResponse(lines, prefix: "+CGLA:")
        }

        let lines = try await sendUnlogged(
            "AT+CSIM=\(command.count),\"\(command)\"",
            timeout: 30_000
        )
        return try parseESTKAPDUResponse(lines, prefix: "+CSIM:")
    }

    /// Retries closure only for channels opened by this app. Failed channels
    /// remain tracked so a later lpac connection can attempt cleanup again.
    private func closeTrackedESTKLogicalChannels() async -> [String] {
        guard !estkLogicalChannels.isEmpty else { return [] }

        var failures: [String] = []
        for modemChannel in Set(estkLogicalChannels.values).sorted() {
            do {
                try await closeESTKLogicalChannel(modemChannel, timeout: 8_000)
                estkLogicalChannels = estkLogicalChannels.filter { $0.value != modemChannel }
            } catch {
                failures.append(localizedFormat(
                    "estk.error.channel_cleanup_failed",
                    Int(modemChannel),
                    error.localizedDescription
                ))
            }
        }
        return failures
    }

    /// A removable eUICC can remain busy briefly after a long BPP command.
    /// Retry channel closure with a small backoff instead of immediately
    /// converting that transient state into the operation's primary error.
    private func closeESTKLogicalChannel(_ channel: UInt8, timeout: Int32) async throws {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                _ = try await sendUnlogged("AT+CCHC=\(channel)", timeout: timeout)
                return
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? ESTKError.malformedLogicalChannelResponse
    }

    private func updateESTKAPDUDiagnostic(operation: String, response: String?) {
        state.estk.lastAPDUOperation = operation
        guard let response, response.count >= 4 else {
            state.estk.lastAPDUStatusWord = "-"
            state.estk.lastAPDUResponseBytes = 0
            return
        }
        state.estk.lastAPDUStatusWord = String(response.suffix(4))
        state.estk.lastAPDUResponseBytes = response.count / 2
    }

    private func normalizedHex(_ value: String) throws -> String {
        let hex = trimmed(value).uppercased()
        guard hex.count.isMultiple(of: 2), !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else {
            throw ESTKError.malformedAPDURequest
        }
        return hex
    }

    private func hexBytes(_ value: String) throws -> [UInt8] {
        let hex = try normalizedHex(value)
        return stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        }
    }
}
