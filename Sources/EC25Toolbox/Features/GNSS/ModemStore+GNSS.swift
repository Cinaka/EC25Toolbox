import Foundation

/// Runtime state of the R4 position-source fallback chain. Kept outside the
/// state machine because it is transport bookkeeping, not UI phase.
struct GNSSSourceRuntime: Equatable, Sendable {
    var current: GNSSDataSource = .qgpsloc2
    var consecutiveFailures = 0

    /// A source that delivered a fix is immediately (re)confirmed.
    mutating func delivered() {
        consecutiveFailures = 0
    }

    /// Applies one policy decision; an advance resets the failure counter.
    mutating func apply(_ decision: GNSSSourcePolicy.Decision) {
        consecutiveFailures = decision.failureCount
        if let next = decision.advanceTo {
            current = next
        }
    }
}

/// GNSS engine actions isolated from the core status, SMS, and call flows.
/// The engine only runs on explicit user request; at most one position query
/// is in flight at any moment, and the poll loop awaits each query's
/// completion so cycles never pile up behind the command chain.
extension ModemStore {
    /// Starts the GNSS engine and begins periodic position polling. Start is
    /// idempotent: an engine that is already running goes straight to
    /// searching without a second `AT+QGPS=1`.
    func startGNSS() {
        guard state.capabilities.gnss != .unsupported else {
            state.lastError = localized("gnss.error.unsupported")
            return
        }
        guard state.connected else {
            state.lastError = localized("gnss.error.disconnected")
            return
        }
        run {
            try await self.startGNSSImpl()
        }
    }

    /// Stops polling, releases the NMEA endpoint, and powers the engine
    /// down. `QGPSEND` is best-effort so the UI state still settles when the
    /// module is already gone.
    func stopGNSS() {
        gnssPollTask?.cancel()
        gnssPollTask = nil
        teardownGNSSNMEAEndpoint()
        run {
            _ = try? await self.send("AT+QGPSEND")
            self.feedGNSS(.stop)
        }
    }

    /// Re-runs the GNSS capability probe from the GNSS page's retry control.
    /// Only a definitive firmware rejection hides the tab afterwards.
    func refreshGNSSCapability() {
        guard state.connected else { return }
        enqueueBackground {
            self.state.capabilities.gnss = await ModemCapabilityProber.probeGNSS { command in
                try await self.send(command, timeout: 4_000)
            }
        }
    }

    /// Feeds one input into the GNSS state machine and publishes the snapshot
    /// even without a phase change (a fresh fix still updates coordinates).
    func feedGNSS(_ input: GNSSInput) {
        _ = gnssMachine.handle(input, now: Date())
        state.gnss = gnssMachine.status
        if !gnssMachine.isEngineRunning {
            gnssPollTask?.cancel()
            gnssPollTask = nil
            teardownGNSSNMEAEndpoint()
        }
    }

    // MARK: - Start / stop internals

    private func startGNSSImpl() async throws {
        // Probe the engine state first: a running engine must not read as a
        // failed start.
        var alreadyRunning = false
        if let lines = try? await send("AT+QGPS?", timeout: 4_000) {
            alreadyRunning = GNSSParsing.parseQGPSState(lines) ?? false
        }
        if !alreadyRunning {
            // NMEA-over-AT is needed by the QGPSGNMEA fallback; a rejected
            // CFG must not block engine startup.
            _ = try? await send("AT+QGPSCFG=\"nmeasrc\",1")
            do {
                _ = try await send("AT+QGPS=1", timeout: 15_000)
            } catch {
                // Some firmwares reject a redundant start; re-check instead
                // of reporting failure when the engine is actually up.
                let recovered = (try? await send("AT+QGPS?", timeout: 4_000))
                    .flatMap(GNSSParsing.parseQGPSState) ?? false
                guard recovered else {
                    gnssSourceRuntime = GNSSSourceRuntime()
                    throw error
                }
            }
        }
        gnssSourceRuntime = GNSSSourceRuntime()
        feedGNSS(.start)
        startGNSSPolling()
    }

    // MARK: - Polling

    /// Polls the active position source every few seconds while the engine
    /// runs. Each cycle is awaited before the next one is scheduled, so at
    /// most one query rides the background chain at a time and user
    /// operations are never starved by a backlog.
    private func startGNSSPolling() {
        gnssPollTask?.cancel()
        gnssPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled,
                      self.gnssMachine.isEngineRunning, self.state.connected else { break }
                self.feedGNSS(.tick)
                guard self.gnssMachine.isEngineRunning else { break }
                await self.pollGNSSOnce().value
            }
        }
    }

    /// One awaited poll cycle on the background chain. Never throws: source
    /// problems feed the fallback policy instead of the user error log.
    private func pollGNSSOnce() -> Task<Void, Never> {
        enqueueBackground { [weak self] in
            await self?.runGNSSPollCycle()
        }
    }

    /// One poll cycle on the background chain. Internal so tests can drive
    /// single cycles deterministically instead of waiting for poll ticks.
    /// Never throws: source problems feed the fallback policy instead of the
    /// user error log.
    @MainActor
    func runGNSSPollCycle() async {
        guard gnssMachine.isEngineRunning, state.connected else { return }
        let source = gnssSourceRuntime.current

        // The USB NMEA endpoint has no AT query; its reader feeds fixes
        // continuously, so this cycle only re-validates the endpoint.
        if source == .nmeaPort {
            guard gnssNMEAEndpoint != nil || gnssRemoteNMEARelayActive else {
                beginGNSSNMEAEndpoint()
                return
            }
            return
        }
        guard let command = source.atCommand else { return }

        let outcome: GNSSPollOutcome
        do {
            let lines = try await sendUnlogged(command, timeout: 5_000)
            switch source {
            case .qgpsloc2, .qgpsloc:
                if var fix = GNSSParsing.parseQGPSLOC(lines) {
                    fix.acquiredAt = Date()
                    feedGNSS(.fix(fix))
                    feedGNSS(.source(source))
                    gnssSourceRuntime.delivered()
                    return
                }
                outcome = .noPosition
            case .qgpsgnmea:
                let sentences = GNSSParsing.parseQGPSGNMEASentences(lines)
                if var fix = GNSSParsing.fixFromNMEA(sentences) {
                    fix.acquiredAt = Date()
                    feedGNSS(.fix(fix))
                    feedGNSS(.source(source))
                    gnssSourceRuntime.delivered()
                    return
                }
                // An engine without a fix yet answers with empty NMEA; that
                // is "no position", not a source failure.
                outcome = .noPosition
            case .nmeaPort:
                return
            }
        } catch {
            let message = error.localizedDescription
            if GNSSParsing.isNoPositionError(message) {
                // CME 516: engine running, satellites not in view yet.
                feedGNSS(.noFix)
                return
            }
            outcome = .failure(GNSSParsing.cmeErrorCode(in: message).map { "+CME ERROR: \($0)" } ?? message)
        }

        applyGNSSSourcePolicy(outcome: outcome, source: source)
    }

    /// Applies the fallback decision and records the structured reason for
    /// diagnostics.
    @MainActor
    private func applyGNSSSourcePolicy(outcome: GNSSPollOutcome, source: GNSSDataSource) {
        let decision = GNSSSourcePolicy.evaluate(
            source: source,
            outcome: outcome,
            consecutiveFailures: gnssSourceRuntime.consecutiveFailures
        )
        gnssSourceRuntime.apply(decision)
        // Non-CME-516 failures keep their structured error code in the UI
        // while the fallback itself handles recovery.
        if case let .failure(message) = outcome {
            feedGNSS(.queryFailed(message))
        }
        if let reason = decision.reason {
            feedGNSS(.sourceFallback(reason))
        }
        if decision.advanceTo == .nmeaPort {
            beginGNSSNMEAEndpoint()
        }
    }

    // MARK: - USB NMEA endpoint

    /// Opens the modem host's independent NMEA interface and streams its
    /// sentences into the machine. Remote sessions explicitly ask the paired
    /// host to open that same endpoint and receive sentences as encrypted
    /// transport events.
    @MainActor
    private func beginGNSSNMEAEndpoint() {
        guard gnssNMEAEndpoint == nil, !gnssRemoteNMEARelayActive else { return }
        if let remote = transport as? RemoteModemTransport {
            gnssRemoteNMEARelayActive = true
            Task { [weak self] in
                do {
                    try await remote.startNMEARelay()
                    guard let self else { return }
                    self.feedGNSS(.source(.nmeaPort))
                } catch {
                    guard let self else { return }
                    self.gnssRemoteNMEARelayActive = false
                    self.noteGNSSNMEAEndpointFailure(error.localizedDescription)
                }
            }
            return
        }
        guard let local = transport as? EC25Transport else {
            noteGNSSNMEAEndpointFailure(localized("gnss.source.unavailable_remote"))
            return
        }
        let endpoint = EC25NMEAEndpoint()
        gnssNMEAEndpoint = endpoint
        gnssNMEATask = Task { [weak self] in
            let excluding = await local.activeInterfaceNumber
            let identity = await local.activeUSBIdentity
            let deviceID = await local.activeDevice?.id
            do {
                _ = try await endpoint.open(
                    identities: identity.map { [$0] } ?? ModuleUSBIdentity.connectionOrder,
                    excludingInterface: excluding,
                    targetDeviceID: deviceID
                )
            } catch {
                self?.noteGNSSNMEAEndpointFailure(error.localizedDescription)
                return
            }
            for await sentence in await endpoint.sentences() {
                guard let self, self.gnssMachine.isEngineRunning else { break }
                self.absorbGNSSNMEASentence(sentence)
            }
        }
    }

    @MainActor
    func absorbGNSSNMEASentence(_ sentence: String) {
        gnssNMEABuffer.append(sentence)
        // NMEA cycles end with GGA; parse once the pair arrives.
        if sentence.contains("GGA") {
            if var fix = GNSSParsing.fixFromNMEA(gnssNMEABuffer) {
                fix.acquiredAt = Date()
                feedGNSS(.fix(fix))
                feedGNSS(.source(.nmeaPort))
                gnssSourceRuntime.delivered()
            }
            gnssNMEABuffer.removeAll(keepingCapacity: true)
        }
    }

    @MainActor
    private func noteGNSSNMEAEndpointFailure(_ message: String) {
        // Endpoint opening is a capability decision, not a transient NMEA
        // poll failure. Fall back immediately to the AT-port NMEA source so
        // an unsupported transport cannot leave the source chain parked on a
        // terminal endpoint that will never produce a sentence.
        gnssSourceRuntime.current = .qgpsgnmea
        gnssSourceRuntime.consecutiveFailures = 0
        feedGNSS(.sourceFallback(message))
        teardownGNSSNMEAEndpoint()
    }

    @MainActor
    func teardownGNSSNMEAEndpoint() {
        gnssNMEATask?.cancel()
        gnssNMEATask = nil
        gnssNMEABuffer.removeAll()
        if gnssRemoteNMEARelayActive,
           let remote = transport as? RemoteModemTransport {
            gnssRemoteNMEARelayActive = false
            Task { await remote.stopNMEARelay() }
        } else {
            gnssRemoteNMEARelayActive = false
        }
        let endpoint = gnssNMEAEndpoint
        gnssNMEAEndpoint = nil
        guard let endpoint else { return }
        Task { await endpoint.close() }
    }
}
