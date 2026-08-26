import Foundation

/// Phone-oriented modem actions isolated from the core status, SMS, and
/// configuration flows.
extension ModemStore {
    /// Connects the call-audio service to settings, the ringtone store, the
    /// active transport, and app state. Audio stays outside the serialized AT
    /// pipeline, while a remote store receives the same controls through the
    /// encrypted remote transport.
    func wireCallAudioService() {
        callAudioService.preferences = { [weak self] in
            guard let self else { return CallAudioPreferences() }
            return CallAudioPreferences(
                inputDeviceUID: self.settings.callAudioInputDeviceUID,
                outputDeviceUID: self.settings.callAudioOutputDeviceUID,
                moduleDeviceUID: self.settings.callAudioModuleDeviceUID,
                ringtoneFileName: self.settings.ringtoneFileName,
                preferredModuleParent: self.moduleDescriptor?.audioParentKey,
                // Runtime readiness is confirmed per call by
                // `AT+QPCMV=1,2`; unknown must never become an all-zero link.
                moduleVoiceReady: self.usesQDC507VoiceRuntime
                    ? self.qdc507VoiceRouteActive
                    : self.state.moduleConfig.usbVoiceOn
            )
        }
        callAudioService.ringtoneURLProvider = { [weak self] in
            guard let self else { return nil }
            return self.ringtoneStore.url(for: self.settings.ringtoneFileName)
        }
        callAudioService.remoteTransportProvider = { [weak self] in
            self?.transport as? RemoteModemTransport
        }
        callAudioService.statusDidChange = { [weak self] status in
            self?.state.callAudio = status
        }
        callAudioService.recordingDidFinish = { [weak self] entry in
            guard let self, let entry else { return }
            let scope = self.currentSIMMessageScope()
            self.state.recordings = self.callRecordingStore.register(entry, scope: scope)
            self.log(localizedFormat("callaudio.log.recording_saved", Int(entry.duration)))
        }
        state.callAudio = callAudioService.status
        state.recordings = callRecordingStore.load(scope: currentSIMMessageScope())
        callAudioService.refreshDevices()
    }

    /// Starts a voice call through the modem's AT dial command.
    ///
    /// - Parameter number: The phone number or service code to dial. Characters
    ///   outside `+`, digits, `*`, and `#` are stripped before sending.
    func dial(number: String) {
        let clean = sanitizedDialNumber(number)
        guard !clean.isEmpty else {
            addCallEvent(title: "phone.call_failed", detail: "phone.number_required", failed: true)
            return
        }

        run {
            do {
                try await self.prepareModuleVoiceForCall()
                _ = try await self.send("ATD\(clean);", timeout: 15_000, privacy: .maskArguments)
                // OK here only means the modem accepted the setup; later
                // progress and failure finals arrive as unsolicited events.
                self.feedMachine(.userDialed(number: clean))
                self.addCallEvent(title: "phone.calling", detail: clean)
            } catch {
                self.addCallEvent(
                    title: "phone.call_failed",
                    detail: error.localizedDescription,
                    failed: true
                )
            }
        }
    }

    /// Hangs up the current voice call, if the modem accepts `ATH`.
    func hangUp() {
        guard callMachine.phase == .dialing
            || callMachine.phase == .alerting
            || callMachine.phase == .answering
            || callMachine.phase == .active
            || callMachine.phase == .held else { return }
        // Enter `.ending` immediately so the UI shows pending feedback; the
        // command result below resolves it.
        let endedEpoch = callMachine.callEpoch
        feedMachine(.hangUpRequested)
        run {
            do {
                _ = try await self.send("ATH", timeout: 8_000)
                // Expired results must not overwrite a newer call: only
                // resolve while the same call's machine waits on this command.
                guard self.callMachine.callEpoch == endedEpoch,
                      self.callMachine.phase == .ending else { return }
                self.feedMachine(.hangUpAccepted)
            } catch {
                guard self.callMachine.callEpoch == endedEpoch,
                      self.callMachine.phase == .ending else { return }
                self.feedMachine(.hangUpFailed)
            }
        }
    }

    /// Answers the incoming call with `ATA`. The explicit user answer intent
    /// is captured synchronously before the command (R8): only this epoch's
    /// request, an accepted `ATA`, and a matching `AT+CLCC active` may reach
    /// `.active`. `OK` alone still only means the modem accepted the command.
    func answer() {
        guard callMachine.phase == .incoming else { return }
        let answeredEpoch = callMachine.callEpoch
        // Records the answer intent and enters `.answering` for immediate
        // pending feedback; a duplicate tap is ignored by the machine.
        feedMachine(.userAnswerRequested)
        run {
            do {
                try await self.prepareModuleVoiceForCall()
                _ = try await self.send("ATA", timeout: 8_000)
                // Skip the result if a different call is now in flight.
                guard self.callMachine.callEpoch == answeredEpoch,
                      self.callMachine.phase == .answering else { return }
                self.feedMachine(.ataAccepted)
            } catch {
                guard self.callMachine.callEpoch == answeredEpoch,
                      self.callMachine.phase == .answering else { return }
                // The caller may still be ringing; the machine returns to
                // incoming so the user can retry.
                self.feedMachine(.ataFailed)
            }
        }
    }

    /// Rejects the incoming call, preferring the dedicated `AT+CHUP` over the
    /// generic hang-up as a fallback.
    func reject() {
        guard callMachine.phase == .incoming else { return }
        let rejectedEpoch = callMachine.callEpoch
        // Enter `.ending` immediately for pending UI feedback.
        feedMachine(.hangUpRequested)
        run {
            do {
                _ = try await self.send("AT+CHUP", timeout: 8_000)
            } catch {
                _ = try await self.send("ATH", timeout: 8_000)
            }
            guard self.callMachine.callEpoch == rejectedEpoch,
                  self.callMachine.phase == .ending else { return }
            self.feedMachine(.hangUpAccepted)
        }
    }

    /// Re-reads the module auto-answer configuration (`ATS0?`, read-only).
    func refreshAutoAnswerConfig() {
        run {
            if let lines = try? await self.send("ATS0?", timeout: 3_000) {
                self.state.autoAnswerRings = parseAutoAnswerRings(lines)
            }
        }
    }

    /// Disables module auto-answer (`ATS0=0`) after explicit user
    /// confirmation in the UI, then re-reads the value to verify (R8).
    func disableAutoAnswer() {
        run {
            _ = try await self.send("ATS0=0", timeout: 5_000)
            if let lines = try? await self.send("ATS0?", timeout: 3_000) {
                self.state.autoAnswerRings = parseAutoAnswerRings(lines)
            }
            self.log(localized("phone.autoanswer.disabled"))
        }
    }

    /// Requests notification authorization while nothing rings (launch or
    /// settings) and mirrors the resolved status into app state. When the
    /// notification center is unreachable the state stays untouched.
    func requestCallNotificationAuthorizationIfNeeded() async {
        guard AppNotificationCenter.isAvailable else { return }
        if let status = await CallNotification.requestAuthorizationIfNeeded() {
            state.callNotificationAuthorization = status
        }
    }

    /// Refreshes the mirrored authorization status without prompting.
    func refreshCallNotificationAuthorization() async {
        guard AppNotificationCenter.isAvailable else { return }
        state.callNotificationAuthorization = await CallNotification.authorizationStatus()
    }

    /// Sends one in-call DTMF tone through `AT+VTS`.
    ///
    /// - Parameter digit: A single DTMF character (`0-9`, `*`, `#`, `A-D`).
    /// Anything else is ignored.
    func sendDTMF(_ digit: String) {
        guard digit.count == 1, "0123456789*#ABCD".contains(digit.uppercased()) else { return }
        guard callMachine.phase == .active else { return }
        let tone = digit.uppercased()
        run {
            _ = try await self.send("AT+VTS=\(tone)", timeout: 4_000)
        }
    }

    /// Probes the card/module phonebook capability with read and test commands
    /// only (`AT+CPBS=?`, `AT+CPBS?`, `AT+CPBR=?`). No storage is selected and
    /// no entries are read, imported, or written, so probing never modifies
    /// card data. Individual query failures degrade to an unsupported snapshot
    /// instead of surfacing a global error.
    func probePhonebook() {
        run {
            var snapshot = PhonebookState()
            var commandFailed = false

            do {
                snapshot.supportedStorages = parsePhonebookStorages(
                    try await self.send("AT+CPBS=?")
                )
            } catch {
                commandFailed = true
            }

            do {
                if let selection = parsePhonebookSelection(try await self.send("AT+CPBS?")) {
                    snapshot.selectedStorage = selection.storage
                    snapshot.usedSlots = selection.used
                    snapshot.totalSlots = selection.total
                }
            } catch {
                commandFailed = true
            }

            do {
                let lines = try await self.send("AT+CPBR=?")
                snapshot.recordRange = parsePhonebookIndexRange(lines)
                if let limits = parsePhonebookRecordLimits(lines) {
                    snapshot.maxNumberLength = limits.numberLength
                    snapshot.maxNameLength = limits.nameLength
                }
            } catch {
                commandFailed = true
            }

            snapshot.lastProbedAt = Date()
            snapshot.lastError = snapshot.isSupported
                ? nil
                : localized(commandFailed ? "phonebook.error.probe_failed" : "phonebook.error.unsupported")
            self.state.phonebook = snapshot
            self.log(localized("phonebook.log.probed"))
        }
    }
}
