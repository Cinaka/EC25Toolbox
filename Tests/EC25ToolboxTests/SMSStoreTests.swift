import XCTest
@testable import EC25Toolbox

/// Records AT commands and answers from a scripted table without touching
/// USB or the network.
actor SMSScriptedTransport: ModemTransport {
    private(set) var commands: [String] = []
    private var responses: [String: [String]] = [:]
    private var sequences: [String: [[String]]] = [:]
    private var failures: [String: [Error]] = [:]

    func setResponse(_ command: String, lines: [String]) {
        responses[command] = lines
    }

    /// Successive responses for one command; each transact pops the first
    /// entry, later transacts keep returning the last one.
    func setResponseSequence(_ command: String, _ lineGroups: [[String]]) {
        sequences[command] = lineGroups
    }

    func setFailure(_ command: String, error: Error, times: Int = 1) {
        failures[command] = Array(repeating: error, count: times)
    }

    func connect() throws -> String { "USB mock" }

    func disconnect() {}

    func transact(command: String, payload: String?, timeoutMs: Int32) throws -> [String] {
        commands.append(command)
        if var queued = failures[command], !queued.isEmpty {
            failures[command] = Array(queued.dropFirst())
            throw queued.removeFirst()
        }
        if var sequence = sequences[command], !sequence.isEmpty {
            let lines = sequence.removeFirst()
            sequences[command] = sequence.isEmpty ? nil : sequence
            return lines
        }
        if let lines = responses[command] {
            return lines
        }
        return ["OK"]
    }
}

@MainActor
final class SMSStoreTests: XCTestCase {
    private struct StubError: LocalizedError {
        var errorDescription: String? { "scripted failure" }
    }

    private func makeStore() throws -> (ModemStore, SMSScriptedTransport) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let archive = SMSArchiveStore(
            applicationSupportDirectory: root,
            iCloudDriveRoot: root.appendingPathComponent("no-cloud")
        )
        let store = ModemStore(
            callLogStore: CallLogStore(applicationSupportDirectory: root),
            smsArchive: archive
        )
        let mock = SMSScriptedTransport()
        store.transport = mock
        store.state.connected = true
        store.state.simSecurity.status = "READY"
        store.state.info.iccid = "8986000000000000001"
        return (store, mock)
    }

    private func waitUntilRefreshCompletes(_ store: ModemStore, timeout: TimeInterval = 5) async {
        store.refreshMessages()
        // Yield first so the queued MainActor operation actually starts; the
        // scripted transport finishes in milliseconds, so by the time this
        // sleep returns the refresh may already be complete.
        try? await Task.sleep(for: .milliseconds(50))
        let deadline = Date().addingTimeInterval(timeout)
        while (store.state.refreshing || store.state.busy) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func commands(_ mock: SMSScriptedTransport) async -> [String] {
        await mock.commands
    }

    // MARK: - PDU capability latch

    func testEmptyPDUListingStillLatchesPDUUsable() async throws {
        let (store, mock) = try makeStore()
        // CMGL answers with a bare OK: an empty listing is a success, not a
        // firmware rejection of PDU mode.
        await mock.setResponse("AT+CMGL=4", lines: ["OK"])

        await waitUntilRefreshCompletes(store)

        XCTAssertEqual(store.smsPDUModeUsable, true)
        let sent = await commands(mock)
        XCTAssertFalse(sent.contains("AT+CMGF=1"), "no text fallback after a successful PDU round")
        XCTAssertEqual(sent.filter { $0.hasPrefix("AT+CMGL=4") }.count, 2, "both storages listed in PDU mode")
        XCTAssertTrue(store.state.messages.isEmpty)
    }

    func testOneStorageFailingPDUKeepsLatchAndFillsGapViaText() async throws {
        let (store, mock) = try makeStore()
        await mock.setFailure("AT+CPMS=\"SM\",\"SM\",\"SM\"", error: StubError(), times: 8)

        await waitUntilRefreshCompletes(store)

        XCTAssertEqual(store.smsPDUModeUsable, true, "ME answered the PDU round, so PDU mode stays usable")
        let sent = await commands(mock)
        XCTAssertTrue(sent.contains("AT+CMGL=4"), "ME was listed in PDU mode")
        XCTAssertTrue(sent.contains("AT+CMGF=1"), "the failed storage is retried through the text listing")
        // SM's PDU attempt failed at CPMS; the gap fill re-attempts the same
        // storage in text mode (it fails at CPMS again, so no CMGL is reached).
        let smAttempts = sent.filter { $0 == "AT+CPMS=\"SM\",\"SM\",\"SM\"" }.count
        XCTAssertGreaterThanOrEqual(smAttempts, 2, "SM is retried outside the PDU round")
    }

    func testCMGF0RejectionFallsBackPermanentlyToText() async throws {
        let (store, mock) = try makeStore()
        await mock.setFailure("AT+CMGF=0", error: StubError(), times: 4)

        await waitUntilRefreshCompletes(store)

        XCTAssertEqual(store.smsPDUModeUsable, false)
        let sent = await commands(mock)
        XCTAssertTrue(sent.contains("AT+CMGL=\"ALL\""), "text listing takes over")
        XCTAssertFalse(sent.contains("AT+CMGL=4"), "PDU listing is never attempted after rejection")
    }

    func testBothStoragesFailingCMGLFallsBackToTextThisSession() async throws {
        let (store, mock) = try makeStore()
        await mock.setFailure("AT+CMGL=4", error: StubError(), times: 4)

        await waitUntilRefreshCompletes(store)

        XCTAssertEqual(store.smsPDUModeUsable, false, "zero completed storages means PDU mode is unusable")
        let sent = await commands(mock)
        XCTAssertTrue(sent.contains("AT+CMGL=\"ALL\""))
    }

    // MARK: - End-to-end listing into the archive

    /// Minimal DELIVER PDU around a GSM-7 body (no UDH), mirroring what
    /// `AT+CMGL=4` emits. Its SCTS decodes to `25/08/21,16:14:48+32`.
    private func deliverPDU(body: String) -> String {
        let packed = GSM7Bit.pack(body)!
        var bytes: [UInt8] = [0x07, 0x91, 0x21, 0x43, 0x65, 0x87, 0x09, 0xF1]
        bytes.append(0x04)
        bytes.append(contentsOf: [0x0A, 0x91, 0x89, 0x67, 0x45, 0x23, 0x01])
        bytes.append(contentsOf: [0x00, 0x00])
        bytes.append(contentsOf: [0x52, 0x80, 0x12, 0x61, 0x41, 0x84, 0x23])
        bytes.append(UInt8(packed.characterCount))
        bytes.append(contentsOf: packed.octets)
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    func testPDUListingFeedsLogicalMessagesWithParsedTime() async throws {
        let (store, mock) = try makeStore()
        // ME answers with one entry; SM answers with an empty listing.
        await mock.setResponseSequence("AT+CMGL=4", [
            ["+CMGL: 2,0,\(deliverPDU(body: "store hello").count / 2)", deliverPDU(body: "store hello"), "OK"],
            ["OK"],
        ])

        await waitUntilRefreshCompletes(store)

        XCTAssertEqual(store.state.messages.count, 1)
        let message = try XCTUnwrap(store.state.messages.first)
        XCTAssertEqual(message.body, "store hello")
        XCTAssertNotNil(message.instant, "the SCTS parsed once into an absolute instant")
        XCTAssertEqual(message.sourceTimeZoneOffsetSeconds, 32 * 15 * 60, "+32 quarters = +08:00")
        XCTAssertEqual(message.effectiveSegmentLocations, [SMSMessageLocation(storage: "ME", index: 2)])
    }

    // MARK: - Notification suppression (R6)

    /// While the SMS list surface is on screen the banner is skipped, and
    /// skipping must NOT mark the message notified: the user saw it live, so
    /// it never deserves a late banner, but it also must not be silently
    /// counted as announced. A later message arriving while no surface is
    /// visible still banners exactly once.
    func testNotificationsSuppressedWhileSMSSurfaceVisible() async throws {
        let (store, mock) = try makeStore()
        store.isSMSSurfaceVisible = { true }

        let first = deliverPDU(body: "seen live")
        await mock.setResponseSequence("AT+CMGL=4", [
            ["OK"], ["OK"],                                   // baseline round, both storages empty
            ["+CMGL: 2,0,\(first.count / 2)", first, "OK"],  // delivery round, ME
            ["OK"],                                           // delivery round, SM
        ])
        await waitUntilRefreshCompletes(store)
        await waitUntilRefreshCompletes(store)

        XCTAssertEqual(store.state.messages.count, 1)
        let seenLive = try XCTUnwrap(store.state.messages.first)
        let pendingAfterSuppression = store.smsArchive.pendingNotificationIDs(
            within: [seenLive.id]
        )
        XCTAssertEqual(Set(pendingAfterSuppression), [seenLive.id], "a suppressed banner leaves the message pending, unmarked")

        // A second message arrives after the surface closed: it banners and
        // is marked notified, while the first stays pending (never fresh
        // again, so it will never banner late).
        store.isSMSSurfaceVisible = { false }
        let second = deliverPDU(body: "bannered")
        await mock.setResponseSequence("AT+CMGL=4", [
            ["+CMGL: 3,0,\(second.count / 2)", second, "OK"],  // ME delivers
            ["OK"],                                           // SM empty
        ])
        await waitUntilRefreshCompletes(store)

        XCTAssertEqual(store.state.messages.count, 2)
        let bannered = try XCTUnwrap(store.state.messages.first { $0.body == "bannered" })
        let pendingAfterBanner = store.smsArchive.pendingNotificationIDs(
            within: Set(store.state.messages.map(\.id))
        )
        XCTAssertEqual(Set(pendingAfterBanner), [seenLive.id], "only the message seen live remains pending")
        XCTAssertFalse(pendingAfterBanner.contains(bannered.id), "the bannered message was marked notified exactly once")
    }

    // MARK: - Conversation projection

    private func projectionMessage(
        id: String,
        sender: String,
        instant: Date?,
        unread: Bool = false
    ) -> SMSMessage {
        SMSMessage(
            id: id,
            storage: "ME",
            index: 1,
            status: unread ? "REC UNREAD" : "REC READ",
            outgoing: false,
            unread: unread,
            sender: sender,
            date: "26/08/21,15:00:00+32",
            body: "body-\(id)",
            instant: instant
        )
    }

    func testConversationProjectionGroupsSortsAndCountsUnread() {
        let jan1 = Date(timeIntervalSince1970: 1_800_000_000)
        let jan2 = jan1.addingTimeInterval(86_400)
        let jan3 = jan1.addingTimeInterval(2 * 86_400)
        let jan4 = jan1.addingTimeInterval(3 * 86_400)

        let conversations = SMSConversationProjectionModel.project(
            messages: [
                projectionMessage(id: "a1", sender: "Alice", instant: jan2, unread: true),
                projectionMessage(id: "a2", sender: "Alice", instant: jan1),
                projectionMessage(id: "u1", sender: "", instant: jan3, unread: true),
                projectionMessage(id: "u2", sender: "-", instant: nil),
                projectionMessage(id: "b1", sender: "Bob", instant: jan4),
            ],
            unknownLabel: "Unknown"
        )

        // Newest conversation first; empty and "-" senders share the
        // localized unknown label as one conversation key.
        XCTAssertEqual(conversations.map(\.key), ["Bob", "Unknown", "Alice"])

        let bob = conversations[0]
        XCTAssertEqual(bob.messages.map(\.id), ["b1"])
        XCTAssertEqual(bob.unread, 0)

        let unknown = conversations[1]
        XCTAssertEqual(unknown.messages.map(\.id), ["u2", "u1"], "undated messages sort first via the id tie-break")
        XCTAssertEqual(unknown.last.id, "u1")
        XCTAssertEqual(unknown.unread, 1)

        let alice = conversations[2]
        XCTAssertEqual(alice.messages.map(\.id), ["a2", "a1"], "messages sort chronologically within a group")
        XCTAssertEqual(alice.last.id, "a1")
        XCTAssertEqual(alice.unread, 1)
    }

    func testConversationProjectionFollowsMessagesAndSkipsUnrelatedChurn() throws {
        let (store, _) = try makeStore()

        var emissions: [[Conversation]] = []
        let cancellable = store.smsConversations.$conversations
            .dropFirst()
            .sink { emissions.append($0) }
        defer { cancellable.cancel() }

        store.state.messages = [
            projectionMessage(id: "m1", sender: "10086", instant: Date(), unread: true),
        ]
        drainMainQueue()

        XCTAssertEqual(store.smsConversations.conversations.map(\.key), ["10086"])
        XCTAssertEqual(store.smsConversations.conversations.first?.unread, 1)
        XCTAssertEqual(emissions.count, 1)

        // Store churn outside the message collection (refresh spinner) fires
        // objectWillChange but must not re-publish the projection.
        store.state.refreshing = true
        drainMainQueue()
        XCTAssertEqual(emissions.count, 1)

        // Reading the message changes the projection input and re-publishes.
        store.state.messages = [
            projectionMessage(id: "m1", sender: "10086", instant: Date()),
        ]
        drainMainQueue()
        XCTAssertEqual(emissions.count, 2)
        XCTAssertEqual(emissions.last?.first?.unread, 0)
    }

    /// The projection re-derives on the main-queue turn after objectWillChange,
    /// so assertions must first let those queued blocks run.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }
}
