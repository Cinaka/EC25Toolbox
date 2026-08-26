import XCTest
@testable import EC25Toolbox

/// Records AT commands without touching USB or the network.
actor CallControlMockTransport: ModemTransport {
    private(set) var commands: [String] = []
    private var failingCommands: Set<String> = []
    private var cannedResponses: [String: [String]] = [:]
    private var delayedCommands: [String: TimeInterval] = [:]

    func setFailing(_ commands: Set<String>) {
        failingCommands = commands
    }

    func setCanned(_ command: String, _ lines: [String]) {
        cannedResponses[command] = lines
    }

    func setDelayed(_ delays: [String: TimeInterval]) {
        delayedCommands = delays
    }

    func connect() throws -> String { "USB mock" }

    func disconnect() {}

    func transact(command: String, payload: String?, timeoutMs: Int32) throws -> [String] {
        if let delay = delayedCommands[command] {
            Thread.sleep(forTimeInterval: delay)
        }
        commands.append(command)
        if failingCommands.contains(command) {
            throw EC25TransportError.sendFailed("mock failure")
        }
        return cannedResponses[command] ?? ["OK"]
    }
}

@MainActor
final class CallControlStoreTests: XCTestCase {
    private func makeStore() -> (ModemStore, CallControlMockTransport) {
        // Route call-history persistence into a temporary directory so the
        // tests never write into the real application-support container.
        let store = ModemStore(
            callLogStore: CallLogStore(applicationSupportDirectory: URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true
            ))
        )
        let mock = CallControlMockTransport()
        store.transport = mock
        return (store, mock)
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Async variant for conditions that must hop to the mock transport actor.
    private func waitUntilTransport(
        _ condition: @escaping () async -> Bool,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testDialSendsATDAndEntersDialing() async {
        let (store, mock) = makeStore()
        store.dial(number: "10086;")
        await waitUntil { store.state.call.phase == .dialing }
        XCTAssertEqual(store.state.call.phase, .dialing)
        XCTAssertEqual(store.state.activeCallNumber, "10086")
        let commands = await mock.commands
        XCTAssertEqual(commands, ["AT+QPCMV=1,2", "ATD10086;"])
    }

    func testAnswerSendsATAThenCLCCActivates() async {
        let (store, mock) = makeStore()
        store.feedMachine(.ring)
        XCTAssertEqual(store.state.call.phase, .incoming)
        store.answer()
        await waitUntil { store.state.call.phase == .answering }
        XCTAssertEqual(store.state.call.phase, .answering)
        // CLCC active must wait for the accepted ATA: feeding it while the
        // command is still in flight is an anomaly, not a connection (R8).
        await waitUntil { store.state.callTimeline.contains(.ataAccepted) }
        store.feedMachine(.clcc([CLCCEntry(index: 1, direction: .incoming, status: .active, number: nil)]))
        XCTAssertEqual(store.state.call.phase, .active)
        let commands = await mock.commands
        XCTAssertEqual(commands, ["AT+QPCMV=1,2", "ATA"])
    }

    // MARK: - R8 answer gate

    func testUnansweredCLCCActiveKeepsIncomingBannerAndLogsAnomaly() {
        let (store, _) = makeStore()
        store.feedMachine(.ring)
        store.feedMachine(.clip(number: "+8613800138000"))
        XCTAssertEqual(store.state.call.phase, .incoming)
        XCTAssertEqual(CallNotification.postedBannerEpoch, 1)

        // The modem reports the tracked incoming call as active with no user
        // answer in this app: the gate keeps it incoming, counts the anomaly,
        // and never retracts the banner or hides the answer surface (R8).
        store.feedMachine(.clcc([CLCCEntry(index: 1, direction: .incoming, status: .active, number: "+8613800138000")]))
        XCTAssertEqual(store.state.call.phase, .incoming)
        XCTAssertEqual(store.state.call.clccActiveAnomalies, 1)
        XCTAssertEqual(CallNotification.postedBannerEpoch, 1)

        // A second anomalous snapshot is counted, still without activation.
        store.feedMachine(.clcc([CLCCEntry(index: 1, direction: .incoming, status: .active, number: nil)]))
        XCTAssertEqual(store.state.call.phase, .incoming)
        XCTAssertEqual(store.state.call.clccActiveAnomalies, 2)

        // No audio link may start for a call that was never answered (R8).
        XCTAssertFalse(store.state.callAudio.uplinkRunning)
        XCTAssertFalse(store.state.callAudio.downlinkRunning)

        // The redacted timeline carries codes and anomaly markers only —
        // never the caller's number.
        let texts = store.state.callTimeline.entries.map(\.formatted)
        XCTAssertTrue(texts.contains { $0.hasPrefix("clccAnomaly|") })
        XCTAssertFalse(texts.contains { $0.contains("+8613800138000") })
    }

    func testStaleATAOKDoesNotFeedNewerCall() async {
        let (store, mock) = makeStore()
        await mock.setDelayed(["ATA": 0.2])
        store.feedMachine(.ring)
        store.answer()
        XCTAssertEqual(store.state.call.phase, .answering)
        // The caller gives up mid-answer, then a second call arrives: the
        // still-pending ATA OK belongs to the old epoch and must be dropped.
        store.feedMachine(.noCarrier)
        XCTAssertEqual(store.state.call.phase, .missed)
        store.feedMachine(.ring)
        XCTAssertEqual(store.state.call.phase, .incoming)
        // R12: a bare RING holds the banner for the CLIP merge window, so the
        // banner deterministically posts once CLIP supplies the number.
        store.feedMachine(.clip(number: "+8613900139000"))
        XCTAssertEqual(CallNotification.postedBannerEpoch, 2)

        await waitUntilTransport { await mock.commands == ["AT+QPCMV=1,2", "ATA"] }
        // Let the answer continuation run past the delayed mock response.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.state.call.phase, .incoming)
        XCTAssertFalse(store.state.callTimeline.contains(.ataAccepted))

        // The epoch-2 call never saw an accepted ATA, so a matching CLCC
        // active still cannot activate it.
        store.feedMachine(.clcc([CLCCEntry(index: 2, direction: .incoming, status: .active, number: nil)]))
        XCTAssertEqual(store.state.call.phase, .incoming)
        XCTAssertEqual(store.state.call.clccActiveAnomalies, 1)
        XCTAssertEqual(CallNotification.postedBannerEpoch, 2)
    }

    func testDuplicateAnswerSendsSingleATA() async {
        let (store, mock) = makeStore()
        store.feedMachine(.ring)
        store.answer()
        // A second tap while answering is a no-op: one ATA per call.
        store.answer()
        await waitUntil { store.state.callTimeline.contains(.ataAccepted) }
        XCTAssertEqual(store.state.call.phase, .answering)
        let commands = await mock.commands
        XCTAssertEqual(commands, ["AT+QPCMV=1,2", "ATA"])
    }

    func testDialStopsWhenModuleRejectsUACPreparation() async {
        let (store, mock) = makeStore()
        await mock.setFailing(["AT+QPCMV=1,2"])

        store.dial(number: "10086")
        await waitUntilTransport { await mock.commands == ["AT+QPCMV=1,2"] }

        let commands = await mock.commands
        XCTAssertEqual(commands, ["AT+QPCMV=1,2"])
        XCTAssertEqual(store.state.call.phase, .idle)
        XCTAssertEqual(store.state.moduleConfig.usbVoiceOn, false)
    }

    // MARK: - R8 banner epoch binding

    func testBannerRetractBindsToPostingEpoch() {
        CallNotification.postIncomingCall(
            title: localized("call.notification.title"),
            body: localized("phone.status.no_number"),
            epoch: 7
        )
        XCTAssertEqual(CallNotification.postedBannerEpoch, 7)
        // A stale epoch from an older call must not remove the newer banner.
        CallNotification.retractIncomingCall(reason: .callEnded, epoch: 6)
        XCTAssertEqual(CallNotification.postedBannerEpoch, 7)
        CallNotification.retractIncomingCall(reason: .userAnswered, epoch: 7)
        XCTAssertNil(CallNotification.postedBannerEpoch)
    }

    func testRetractReasonMapping() {
        // Entering answering/ending is user-attributable; an outcome concludes
        // the call; anything else that leaves the ring phase supersedes the
        // posted epoch.
        XCTAssertEqual(
            ModemStore.callRetractReason(
                for: CallTransition(from: .incoming, to: .answering, outcome: nil, adviseHangUp: false)
            ),
            .userAnswered
        )
        XCTAssertEqual(
            ModemStore.callRetractReason(
                for: CallTransition(from: .answering, to: .ending, outcome: nil, adviseHangUp: false)
            ),
            .userEnded
        )
        XCTAssertEqual(
            ModemStore.callRetractReason(
                for: CallTransition(
                    from: .incoming,
                    to: .ended,
                    outcome: CallOutcome(number: nil, direction: nil, reason: .remoteHangUp, startedAt: nil),
                    adviseHangUp: false
                )
            ),
            .callEnded
        )
        XCTAssertEqual(
            ModemStore.callRetractReason(
                for: CallTransition(from: .incoming, to: .incoming, outcome: nil, adviseHangUp: false)
            ),
            .epochSuperseded
        )
    }

    // MARK: - Auto-answer (ATS0) probing

    func testRefreshAutoAnswerConfigParsesRings() async {
        let (store, mock) = makeStore()
        await mock.setCanned("ATS0?", ["+S0: 2", "OK"])
        store.refreshAutoAnswerConfig()
        await waitUntil { store.state.autoAnswerRings == 2 }
        let commands = await mock.commands
        XCTAssertEqual(commands, ["ATS0?"])
    }

    func testDisableAutoAnswerSendsATS0ThenRereads() async {
        let (store, mock) = makeStore()
        store.disableAutoAnswer()
        await waitUntilTransport { await mock.commands == ["ATS0=0", "ATS0?"] }
        // The mock re-read returns no +S0 line, so the mirrored value clears.
        XCTAssertEqual(store.state.autoAnswerRings, nil)
    }

    func testParseAutoAnswerRingsVectors() {
        XCTAssertEqual(parseAutoAnswerRings(["+S0: 0", "OK"]), 0)
        XCTAssertEqual(parseAutoAnswerRings(["+S0: 3", "OK"]), 3)
        XCTAssertEqual(parseAutoAnswerRings(["+S0:  2 ", "OK"]), 2)
        XCTAssertEqual(parseAutoAnswerRings(["OK"]), nil)
        XCTAssertEqual(parseAutoAnswerRings(["+S0: x", "OK"]), nil)
        XCTAssertEqual(parseAutoAnswerRings([]), nil)
    }

    // MARK: - Reject / hang up / DTMF

    func testRejectPrefersCHUP() async {
        let (store, mock) = makeStore()
        store.feedMachine(.ring)
        store.reject()
        await waitUntil { store.state.call.phase == .ended }
        XCTAssertEqual(store.state.call.phase, .ended)
        let commands = await mock.commands
        XCTAssertEqual(commands, ["AT+CHUP"])
        XCTAssertEqual(store.state.callLog.first?.title, "phone.call.rejected")
    }

    func testRejectFallsBackToATHWhenCHUPFails() async {
        let (store, mock) = makeStore()
        await mock.setFailing(["AT+CHUP"])
        store.feedMachine(.ring)
        store.reject()
        await waitUntil { store.state.call.phase == .ended }
        XCTAssertEqual(store.state.call.phase, .ended)
        let commands = await mock.commands
        XCTAssertEqual(commands, ["AT+CHUP", "ATH"])
    }

    func testHangUpSendsATHAndEndsCall() async {
        let (store, mock) = makeStore()
        store.feedMachine(.ring)
        store.feedMachine(.userAnswerRequested)
        store.feedMachine(.ataAccepted)
        store.feedMachine(.clcc([CLCCEntry(index: 1, direction: .incoming, status: .active, number: nil)]))
        XCTAssertEqual(store.state.call.phase, .active)
        store.hangUp()
        await waitUntil { store.state.call.phase == .ended }
        XCTAssertEqual(store.state.call.phase, .ended)
        let commands = await mock.commands
        XCTAssertEqual(commands, ["ATH"])
        XCTAssertEqual(store.state.callLog.first?.title, "phone.ended")
    }

    func testDTMFOnlyDuringActiveCall() async {
        let (store, mock) = makeStore()
        store.feedMachine(.ring)
        store.feedMachine(.userAnswerRequested)
        store.feedMachine(.ataAccepted)
        store.feedMachine(.clcc([CLCCEntry(index: 1, direction: .incoming, status: .active, number: nil)]))
        XCTAssertEqual(store.state.call.phase, .active)

        store.sendDTMF("5")
        await waitUntil { store.state.logLines.contains { $0.contains("AT+VTS=5") } }
        // Lowercase input is normalized to the DTMF letter set.
        store.sendDTMF("b")
        await waitUntil { store.state.logLines.contains { $0.contains("AT+VTS=B") } }

        // Invalid input and ended calls no longer send tones.
        store.sendDTMF("5;")
        store.sendDTMF("+")
        store.feedMachine(.hangUpRequested)
        store.feedMachine(.hangUpAccepted)
        store.sendDTMF("7")
        await waitUntil { store.state.call.phase == .ended }
        try? await Task.sleep(for: .milliseconds(100))
        let commands = await mock.commands
        XCTAssertEqual(commands, ["AT+VTS=5", "AT+VTS=B"])
    }

    func testAnswerAndRejectOutsideIncomingAreIgnored() async {
        let (store, mock) = makeStore()
        store.answer()
        store.reject()
        XCTAssertEqual(store.state.call.phase, .idle)
        let commands = await mock.commands
        XCTAssertTrue(commands.isEmpty)
    }
}
