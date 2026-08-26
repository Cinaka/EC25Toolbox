import Foundation

/// SMS send/receive, archive projection, notification, read-state, and
/// maintenance operations. Keeping this feature out of the core store leaves
/// `ModemStore` responsible for orchestration instead of SMS implementation.
extension ModemStore {
    /// Refreshes SMS storage while preserving the current status snapshot.
    func refreshMessages() {
        runRefresh {
            guard self.state.simSecurity.isReady else {
                self.clearMessagesForLockedSIM()
                throw SIMPINError.simNotReady
            }
            try await self.refreshMessagesImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Sends a text message through the modem and persists a local sent copy.
    func sendSMS(to number: String, body: String) {
        let cleanNumber = trimmed(number)
        let cleanBody = trimmed(body)
        guard !cleanNumber.isEmpty, !cleanBody.isEmpty else {
            state.lastError = localized("error.sms_empty")
            return
        }
        guard state.simSecurity.isReady else {
            state.lastError = localized("sim_pin.error.sim_not_ready")
            return
        }

        run {
            _ = try await self.send("AT+CMGF=1")
            _ = try await self.send("AT+CSCS=\"UCS2\"")
            let encodedNumber = UCS2.encode(cleanNumber)
            let encodedBody = UCS2.encode(cleanBody)
            _ = try await self.send(
                "AT+CMGS=\"\(encodedNumber)\"",
                payload: encodedBody + String(UnicodeScalar(0x1A)!),
                timeout: 25_000,
                privacy: .maskArguments
            )

            let scope = self.currentSIMMessageScope()
            try self.smsArchive.addSent(
                to: cleanNumber,
                body: cleanBody,
                sentAt: Date(),
                scope: scope,
                moduleID: self.moduleIdentifier
            )
            self.state.smsBackup = self.smsArchive.state
            try await self.refreshMessagesImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Deletes a modem-stored SMS or a locally persisted sent message.
    /// Concatenated messages delete every backing storage/index slot.
    func deleteSMS(_ message: SMSMessage) {
        run {
            if message.storage == "SENT" || !message.presentOnModem {
                try self.smsArchive.delete(messageID: message.id)
                self.state.smsBackup = self.smsArchive.state
                try await self.refreshMessagesImpl()
                return
            }

            _ = try await self.send("AT+CMGF=1")
            for (storage, locations) in Dictionary(grouping: message.effectiveSegmentLocations, by: \.storage) {
                _ = try? await self.send("AT+CPMS=\"\(storage)\",\"\(storage)\",\"\(storage)\"")
                for location in locations {
                    _ = try await self.send("AT+CMGD=\(location.index)")
                }
            }
            try self.smsArchive.delete(messageID: message.id)
            self.state.smsBackup = self.smsArchive.state
            try await self.refreshMessagesImpl()
            self.state.lastUpdated = Date()
        }
    }

    func markAllRead() {
        run {
            try await self.markRead(self.state.messages)
            try await self.refreshMessagesImpl()
            self.state.lastUpdated = Date()
        }
    }

    func markConversationRead(sender: String) {
        run {
            let messages = self.state.messages.filter {
                ($0.sender.isEmpty ? localized("common.unknown") : $0.sender) == sender
            }
            guard messages.contains(where: \.unread) else { return }
            try await self.markRead(messages)
            try await self.refreshMessagesImpl()
            self.state.lastUpdated = Date()
        }
    }

    func refreshMessagesImpl() async throws {
        try await refreshMessagesOnce()
        if settings.smsAutoCleanAfterArchive ?? false {
            await autoCleanArchivedModemMessages()
            try await refreshMessagesOnce()
        }
    }

    /// Lists both modem storages and merges them into the archive. The archive
    /// write precedes notification or modem-side cleanup.
    private func refreshMessagesOnce() async throws {
        guard state.simSecurity.isReady else {
            clearMessagesForLockedSIM()
            return
        }

        let modemStorages = ["ME", "SM"]
        var all: [SMSSegment] = []
        var presentStorages: Set<String> = []
        if smsPDUModeUsable != false {
            do {
                let outcome = try await listSegmentsViaPDU()
                all = outcome.segments
                presentStorages = outcome.presentStorages
                if presentStorages.isEmpty {
                    smsPDUModeUsable = false
                } else {
                    smsPDUModeUsable = true
                    if !state.capabilities.pduSMS {
                        state.capabilities.pduSMS = true
                    }
                }
            } catch {
                smsPDUModeUsable = false
            }
        }
        if presentStorages.count < modemStorages.count {
            _ = try await send("AT+CMGF=1")
            _ = try await send("AT+CSCS=\"UCS2\"")

            for storage in modemStorages where !presentStorages.contains(storage) {
                do {
                    _ = try await send("AT+CPMS=\"\(storage)\",\"\(storage)\",\"\(storage)\"")
                    let lines = try await send(
                        "AT+CMGL=\"ALL\"",
                        timeout: 12_000,
                        privacy: .suppressResponse
                    )
                    all.append(contentsOf: parseMessageList(lines, storage: storage))
                    presentStorages.insert(storage)
                } catch {
                    continue
                }
            }
        }

        let previous = state.messages
        let scope = currentSIMMessageScope()
        guard scope.isIdentified else {
            state.messages = []
            state.unreadCount = 0
            return
        }
        state.messages = try smsArchive.synchronize(
            liveSegments: all,
            presentStorages: presentStorages,
            legacySent: state.sentMessages,
            scope: scope,
            moduleID: moduleIdentifier
        )
        if !state.sentMessages.isEmpty {
            state.sentMessages.removeAll()
            try? FileManager.default.removeItem(at: sentLogURL)
        }
        state.smsBackup = smsArchive.state
        state.unreadCount = state.messages.filter(\.unread).count
        notifyNewIncomingMessages(previous: previous, scope: scope)
    }

    /// Lists ME and SM in PDU mode. A failing storage is omitted so text-mode
    /// fallback can fill only that gap.
    private func listSegmentsViaPDU() async throws -> (
        segments: [SMSSegment],
        presentStorages: Set<String>
    ) {
        _ = try await send("AT+CMGF=0")
        var all: [SMSSegment] = []
        var presentStorages: Set<String> = []
        for storage in ["ME", "SM"] {
            do {
                _ = try await send("AT+CPMS=\"\(storage)\",\"\(storage)\",\"\(storage)\"")
                let lines = try await send("AT+CMGL=4", timeout: 12_000, privacy: .suppressResponse)
                all.append(contentsOf: parsePDUMessageList(lines, storage: storage))
                presentStorages.insert(storage)
            } catch {
                continue
            }
        }
        return (all, presentStorages)
    }

    /// Posts only newly archived incoming messages after a notification
    /// baseline exists for the current SIM scope.
    private func notifyNewIncomingMessages(previous: [SMSMessage], scope: SIMMessageScope) {
        let baselineReady = smsNotificationBaselineScopeID == scope.id
        smsNotificationBaselineScopeID = scope.id
        guard baselineReady, !isSMSSurfaceVisible() else { return }
        let candidates = Set(
            SMSNotification.freshIncoming(previous: previous, current: state.messages).map(\.id)
        )
        guard !candidates.isEmpty else { return }
        let pending = smsArchive.pendingNotificationIDs(within: candidates)
        guard !pending.isEmpty else { return }
        for message in state.messages where pending.contains(message.id) {
            SMSNotification.postNewMessage(
                senderDisplay: smsContactNameResolver?(message.sender)
                    ?? (message.sender.isEmpty ? localized("common.unknown") : message.sender),
                preview: SMSNotification.redactedPreview(of: message.body),
                identifier: message.id,
                moduleID: moduleIdentifier,
                moduleName: moduleDisplayName
            )
        }
        try? smsArchive.markNotified(messageIDs: pending)
        state.smsBackup = smsArchive.state
    }

    /// Removes modem copies only after archive synchronization succeeded.
    private func autoCleanArchivedModemMessages() async {
        let locations = state.messages
            .filter(\.presentOnModem)
            .flatMap(\.effectiveSegmentLocations)
        guard !locations.isEmpty else { return }
        _ = try? await send("AT+CMGF=1")
        for (storage, storageLocations) in Dictionary(grouping: locations, by: \.storage) {
            _ = try? await send("AT+CPMS=\"\(storage)\",\"\(storage)\",\"\(storage)\"")
            for location in storageLocations {
                do {
                    _ = try await send("AT+CMGD=\(location.index)")
                } catch {
                    log(localizedFormat("sms.autoclean.failed", location.index))
                }
            }
        }
    }

    func clearMessagesForLockedSIM() {
        state.messages = []
        state.unreadCount = 0
    }

    func backupSMSNow() {
        run {
            try self.smsArchive.backupNow()
            self.state.smsBackup = self.smsArchive.state
        }
    }

    func restoreSMSFromICloudDrive() {
        run {
            try self.smsArchive.restoreLatestBackup()
            let scope = self.currentSIMMessageScope()
            self.state.messages = scope.isIdentified ? self.smsArchive.messages(in: scope.id) : []
            self.state.smsBackup = self.smsArchive.state
            self.state.unreadCount = self.state.messages.filter(\.unread).count
        }
    }

    func rebuildSMSIndex() {
        run {
            try self.smsArchive.rebuildProjectionAndPersist()
            let scope = self.currentSIMMessageScope()
            self.state.messages = scope.isIdentified ? self.smsArchive.messages(in: scope.id) : []
            self.state.smsBackup = self.smsArchive.state
            self.state.unreadCount = self.state.messages.filter(\.unread).count
        }
    }

    var smsIndexDiagnostics: SMSArchiveRepairer.Diagnostics {
        smsArchive.indexDiagnostics
    }

    private func markRead(_ messages: [SMSMessage]) async throws {
        let targets = messages.filter(\.unread)
        guard !targets.isEmpty else { return }
        let modemLocations = targets
            .filter { $0.storage != "SENT" && $0.presentOnModem }
            .flatMap(\.effectiveSegmentLocations)
        _ = try await send("AT+CMGF=1")
        for (storage, locations) in Dictionary(grouping: modemLocations, by: \.storage) {
            _ = try? await send("AT+CPMS=\"\(storage)\",\"\(storage)\",\"\(storage)\"")
            for location in locations {
                _ = try? await send(
                    "AT+CMGR=\(location.index)",
                    timeout: 6_000,
                    privacy: .suppressResponse
                )
            }
        }
        try smsArchive.markRead(messageIDs: Set(targets.map(\.id)))
        state.smsBackup = smsArchive.state
    }
}
