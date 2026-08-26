import Foundation

extension ModemStore {
    // MARK: - Modem events & call state

    /// Subscribes to transport events for the current session. Replaces any
    /// previous subscription; the stream finishes when the session ends.
    func startModemEventTask() {
        modemEventTask?.cancel()
        let stream = transport.events()
        modemEventTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.handleModemEvent(event)
            }
        }
    }

    private func handleModemEvent(_ event: ModemEvent) {
        switch event {
        case let .incomingCall(number):
            feedMachine(number == nil ? .ring : .clip(number: number))
        case .clipWithoutNumber:
            feedMachine(.clip(number: nil))
        case let .callState(line):
            feedMachine(CallInput.forURCLine(line))
        case .smsArrived:
            guard state.connected, state.simSecurity.isReady else { return }
            refreshMessages()
        case .simStatus:
            // SIM hot-swap indications are covered by the periodic info poll;
            // reacting here would race the poll's serialized refresh.
            break
        case .disconnected:
            guard state.connected else { return }
            Task { await self.markDisconnected() }
        case .moduleRestarted:
            log(localized("log.module_restarted"))
        case let .gnssNMEA(sentence):
            guard gnssRemoteNMEARelayActive, gnssMachine.isEngineRunning else { return }
            absorbGNSSNMEASentence(sentence)
        }
    }

    /// Internal (not private) so feature extensions can resolve the current
    /// SIM identity for their own scoped stores.
    func currentSIMMessageScope() -> SIMMessageScope {
        SIMMessageScope(eid: state.estk.chipInfo?.eidValue, iccid: state.info.iccid)
    }

    /// Feeds one input into the call state machine and applies any transition.
    func feedMachine(_ input: CallInput?) {
        guard let input else { return }
        recordCallTimelineInput(input)
        let anomaliesBefore = callMachine.clccActiveAnomalies
        let transition = callMachine.handle(input, now: Date())
        if callMachine.clccActiveAnomalies > anomaliesBefore {
            // R8 anomaly: the modem reported the tracked incoming call as
            // active although this app never accepted an answer for it. The
            // incoming surface and its notification stay untouched.
            appendCallTimeline(.clccAnomaly, detail: "clccActiveWithoutAnswer")
            log(localized("phone.call.anomaly_clcc_active"))
        }
        coordinateCallerIdentity(input: input, transition: transition)
        guard let transition else {
            // No phase change, but machine bookkeeping (epoch status, anomaly
            // counters, ring watchdog) may still have moved; republish the
            // snapshot so diagnostics and the timeline stay in sync.
            state.call = callMachine.status
            state.callerIdentity = callIdentityCoordinator.identity
            restartCallMaintenanceIfNeeded()
            return
        }
        applyCallTransition(transition)
    }

    /// R12 caller-identity coordination: routes CLIP/CLCC numbers and
    /// withheld indications of the current epoch into the coordinator and
    /// applies its banner decisions. Runs after the machine handled the
    /// input (so the epoch is fresh) and before `applyCallTransition`
    /// (so a begin-transition finds the identity already seeded).
    private func coordinateCallerIdentity(input: CallInput, transition: CallTransition?) {
        let epoch = callMachine.callEpoch
        let now = Date()
        switch input {
        case let .clip(number):
            guard callMachine.phase == .incoming else { break }
            let decision = callIdentityCoordinator.clipArrived(
                number: number,
                epoch: epoch,
                at: now
            )
            applyCallerIdentityDecision(decision, epoch: epoch)
        case let .clcc(entries):
            guard callMachine.phase == .incoming || callMachine.phase == .answering,
                  let tracked = entries.first(where: {
                      $0.direction == .incoming && ($0.status == .incoming || $0.status == .waiting)
                  }),
                  let number = tracked.number, !number.isEmpty else { break }
            let decision = callIdentityCoordinator.clccNumber(
                number: number,
                epoch: epoch,
                at: now
            )
            applyCallerIdentityDecision(decision, epoch: epoch)
        case .ataFailed:
            // Returns to `.incoming` while the call still rings;
            // `applyCallTransition` re-arms the banner through
            // `incomingBegan` after the retraction below.
            break
        default:
            break
        }
        state.callerIdentity = callIdentityCoordinator.identity
    }

    /// Applies one coordinator decision: schedules the merge-window hold,
    /// posts the first banner, or replaces the posted banner in place.
    private func applyCallerIdentityDecision(
        _ decision: IncomingCallIdentityCoordinator.Decision,
        epoch: Int
    ) {
        switch decision {
        case .none:
            break
        case .holdBanner(let deadline):
            scheduleCallerIdentityHold(deadline: deadline, epoch: epoch)
        case .postBanner:
            postCallerIdentityBanner(epoch: epoch, replacing: false)
        case .replaceBanner:
            postCallerIdentityBanner(epoch: epoch, replacing: true)
        }
        if callIdentityCoordinator.identity?.status == .resolved {
            resolveCallerContactName()
        }
        state.callerIdentity = callIdentityCoordinator.identity
    }

    /// Posts (or replaces) the incoming-call banner through the shared
    /// identity derivator. Replacement keeps the same request identifier,
    /// category, and epoch-bound actions — only the content changes (R12).
    private func postCallerIdentityBanner(epoch: Int, replacing: Bool) {
        guard callIdentityCoordinator.identity?.epoch == epoch else { return }
        let display = callerIdentityDisplay()
        let title = localized("call.notification.title")
        if replacing {
            CallNotification.replaceIncomingCallContent(
                title: title,
                body: display.title,
                epoch: epoch,
                moduleID: moduleIdentifier,
                moduleName: moduleDisplayName
            )
            appendCallTimeline(.notifyReplaced, detail: display.timelineToken)
        } else {
            CallNotification.postIncomingCall(
                title: title,
                body: display.title,
                epoch: epoch,
                moduleID: moduleIdentifier,
                moduleName: moduleDisplayName
            )
            appendCallTimeline(.notifyPosted, detail: display.timelineToken)
        }
    }

    /// Shared display for every caller-identity surface (R12): notification,
    /// call surface, phone status, and history rows all derive through this.
    func callerIdentityDisplay() -> CallerIdentityDerivator.Display {
        CallerIdentityDerivator.display(
            identity: callIdentityCoordinator.identity,
            pendingText: localized("call.identity.resolving"),
            unknownText: localized("phone.status.no_number"),
            withheldText: localized("call.identity.withheld")
        )
    }

    /// Waits out the bounded merge window; if no CLIP number arrived and the
    /// call still rings, the banner posts with the explicit unknown text.
    private func scheduleCallerIdentityHold(deadline: Date, epoch: Int) {
        callerIdentityHoldTask?.cancel()
        let delay = max(0, deadline.timeIntervalSinceNow)
        callerIdentityHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard self.callMachine.phase == .incoming,
                  self.callIdentityCoordinator.identity?.epoch == epoch else { return }
            let decision = self.callIdentityCoordinator.mergeWindowExpired(epoch: epoch, at: Date())
            self.applyCallerIdentityDecision(decision, epoch: epoch)
        }
    }

    /// Resolves the contact name for the current resolved identity from the
    /// in-memory snapshot; when that snapshot may still be loading, retries
    /// once asynchronously (never prompting). Stale epochs are dropped by
    /// the coordinator.
    private func resolveCallerContactName() {
        guard let identity = callIdentityCoordinator.identity,
              identity.status == .resolved,
              identity.displayName == nil,
              let number = identity.normalizedNumber ?? identity.rawNumber else { return }
        let epoch = identity.epoch
        if let name = callContactNameResolver?(number) {
            let decision = callIdentityCoordinator.contactResolved(name: name, epoch: epoch, at: Date())
            applyCallerIdentityDecision(decision, epoch: epoch)
            return
        }
        guard let reload = callContactSnapshotReload else { return }
        Task { [weak self] in
            await reload()
            guard let self else { return }
            guard self.callIdentityCoordinator.identity?.epoch == epoch,
                  self.callIdentityCoordinator.identity?.status == .resolved,
                  self.callIdentityCoordinator.identity?.displayName == nil else { return }
            guard let name = self.callContactNameResolver?(number) else { return }
            let decision = self.callIdentityCoordinator.contactResolved(name: name, epoch: epoch, at: Date())
            self.applyCallerIdentityDecision(decision, epoch: epoch)
        }
    }

    /// Maps raw machine inputs onto redacted timeline entries. CLCC details
    /// carry index/direction/status codes only — never subscriber data.
    private func recordCallTimelineInput(_ input: CallInput) {
        switch input {
        case .ring:
            appendCallTimeline(.ring)
        case let .clip(number):
            appendCallTimeline(.clip, detail: number == nil ? "hasNumber=false" : "hasNumber=true")
        case let .clcc(entries):
            let summary = entries
                .map { "idx=\($0.index) dir=\($0.direction.rawValue) stat=\($0.status.rawValue)" }
                .joined(separator: " ")
            appendCallTimeline(.clccSnapshot, detail: summary.isEmpty ? "empty" : summary)
        case .clccEmpty:
            appendCallTimeline(.clccSnapshot, detail: "empty")
        case .userAnswerRequested:
            appendCallTimeline(.userAnswer)
        case .ataAccepted:
            appendCallTimeline(.ataAccepted)
        case .ataFailed:
            appendCallTimeline(.ataFailed)
        case .hangUpRequested:
            appendCallTimeline(callMachine.phase == .incoming ? .userReject : .userHangUp)
        case .hangUpAccepted:
            appendCallTimeline(.hangUpAccepted)
        case .hangUpFailed:
            appendCallTimeline(.hangUpFailed)
        case .transportLost:
            appendCallTimeline(.transportLost)
        case .noCarrier, .busy, .noAnswer, .dialFailure, .userDialed, .tick:
            break
        }
    }

    private func appendCallTimeline(
        _ kind: CallTimelineEntry.Kind,
        detail: String? = nil
    ) {
        state.callTimeline.append(
            kind,
            at: Date(),
            epoch: callMachine.callEpoch,
            phase: callMachine.phase,
            detail: detail
        )
    }

    /// Derives the explicit retraction reason for a transition that leaves
    /// the ring/answer phases or concludes the call (R8).
    static func callRetractReason(for transition: CallTransition) -> CallNotification.RetractReason {
        if transition.to == .answering { return .userAnswered }
        if transition.to == .ending { return .userEnded }
        if transition.outcome != nil { return .callEnded }
        return .epochSuperseded
    }

    private func applyCallTransition(_ transition: CallTransition) {
        let previousStatus = state.call
        state.call = callMachine.status
        // Legacy field consumed by the existing dialer UI until P1-C.
        state.activeCallNumber = callMachine.hasLiveCall ? callMachine.number : nil
        if let outcome = transition.outcome {
            recordCallOutcome(outcome)
            appendCallTimeline(.callConcluded, detail: String(describing: outcome.reason))
        } else if transition.to != transition.from {
            appendCallTimeline(.phaseChanged, detail: "from=\(transition.from.rawValue)")
        }
        if callMachine.status.isExternalAdoption, !previousStatus.isExternalAdoption {
            appendCallTimeline(.externalAdopted)
        }
        // Retraction needs a user- or modem-attributable reason bound to the
        // posting epoch: the user answered/rejected/ended, the call genuinely
        // concluded, or the epoch was superseded. A raw CLCC anomaly stays in
        // `.incoming` and never reaches this branch (R8). Reverting from a
        // failed answer back to `.incoming` retracts first so the banner can
        // be re-posted for the same still-ringing call below.
        let leavesRingPhase = transition.to != transition.from
            && (transition.from == .incoming || transition.from == .answering)
        if leavesRingPhase || transition.outcome != nil {
            let reason = Self.callRetractReason(for: transition)
            CallNotification.retractIncomingCall(
                reason: reason,
                epoch: callMachine.callEpoch,
                moduleID: moduleIdentifier
            )
            callIdentityCoordinator.bannerRetracted(epoch: callMachine.callEpoch)
            callerIdentityHoldTask?.cancel()
            appendCallTimeline(.notifyRetracted, detail: "reason=\(reason.rawValue)")
        }
        // A concluded call drops its identity so late CLIP/CLCC or contact
        // results for the old epoch can never relabel a newer call (R12).
        if transition.outcome != nil || !callMachine.hasLiveCall {
            callIdentityCoordinator.callEnded(epoch: callMachine.callEpoch)
            callerIdentityHoldTask?.cancel()
            state.callerIdentity = callIdentityCoordinator.identity
        }
        // The banner posts for a fresh incoming epoch through the identity
        // coordinator (R12): a bare RING holds the banner for the bounded
        // CLIP merge window instead of immediately showing "unknown".
        if transition.to == .incoming, transition.from != .incoming {
            let decision = callIdentityCoordinator.incomingBegan(
                epoch: callMachine.callEpoch,
                number: callMachine.number,
                at: Date(),
                mergeWindow: callerIdentityMergeWindow
            )
            applyCallerIdentityDecision(decision, epoch: callMachine.callEpoch)
        }
        if transition.adviseHangUp, state.connected {
            enqueueBackground {
                _ = try? await self.sendUnlogged("ATH", timeout: 4_000)
            }
        }
        syncCallAudioWithSelectedVoiceBackend(
            transition: transition,
            remoteNumber: callMachine.number
        )
        if transition.to == .active, transition.from != .active,
           !usesQDC507VoiceRuntime {
            startAutomaticCallRecordingIfNeeded()
        }
        restartCallMaintenanceIfNeeded()
    }

    private func recordCallOutcome(_ outcome: CallOutcome) {
        let title: String
        var detail = outcome.number ?? localized("phone.current_call")
        var failed = false
        switch outcome.reason {
        case .localHangUp:
            title = "phone.ended"
        case .remoteHangUp:
            title = "phone.call.ended_remote"
        case .rejected:
            title = "phone.call.rejected"
        case .missed:
            title = "phone.call.missed"
        case .busy:
            title = "phone.call.busy"
            failed = true
        case .noAnswer:
            title = "phone.call.no_answer"
            failed = true
        case .noCarrier:
            title = "phone.call.no_carrier"
            failed = true
        case .dialTimeout:
            title = "phone.call.dial_timeout"
            failed = true
        case .answerTimeout:
            title = "phone.call.answer_timeout"
            failed = true
        case let .dialFailed(message):
            title = "phone.call_failed"
            detail = message
            failed = true
        case .transportLost:
            title = "phone.call.transport_lost"
            failed = true
        }
        addCallEvent(title: title, detail: detail, failed: failed)
    }

    /// Keeps exactly one maintenance loop alive while the machine tracks a
    /// call (live phases plus the terminal linger countdown).
    private func restartCallMaintenanceIfNeeded() {
        if callMachine.isTrackingCall {
            guard !callMaintenanceRunning else { return }
            callMaintenanceRunning = true
            callMaintenanceTask = Task { [weak self] in
                await self?.runCallMaintenance()
            }
        } else {
            callMaintenanceTask?.cancel()
        }
    }

    /// Drives per-second machine ticks, `AT+CLCC` polling, and terminal
    /// linger expiry while a call is tracked.
    private func runCallMaintenance() async {
        defer { callMaintenanceRunning = false }
        var tickCount = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, callMachine.isTrackingCall else { break }
            feedMachine(.tick)
            tickCount += 1
            // Poll the call list every other tick while a live call exists.
            if tickCount % 2 == 0,
               callMachine.hasLiveCall,
               state.connected,
               !state.busy,
               !state.refreshing,
               !foregroundOperationQueued,
               !refreshOperationQueued {
                enqueueBackground { [weak self] in
                    guard let self, self.callMachine.hasLiveCall, self.state.connected else { return }
                    do {
                        let lines = try await self.sendUnlogged("AT+CLCC", timeout: 3_000)
                        let entries = CLCCEntry.parse(lines)
                        self.feedMachine(entries.isEmpty ? .clccEmpty : .clcc(entries))
                    } catch {
                        // Transport hiccups must not be read as the call ending.
                    }
                }
            }
        }
    }

}
