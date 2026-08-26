import XCTest
@testable import EC25Toolbox

final class ModemEventTests: XCTestCase {
    // MARK: URC mapping

    func testRingMapsToIncomingCall() {
        XCTAssertEqual(ModemEvent.fromURC("RING"), .incomingCall(number: nil))
    }

    func testCLIPMapsNumber() {
        XCTAssertEqual(
            ModemEvent.fromURC("+CLIP: \"+8613800138000\",145,,,\"\""),
            .incomingCall(number: "+8613800138000")
        )
        // An empty `+CLIP` means the network explicitly withheld the
        // number — distinct from a bare RING still inside the merge window
        // (R12), so it maps to its own input.
        XCTAssertEqual(
            ModemEvent.fromURC("+CLIP: \"\",129"),
            .clipWithoutNumber
        )
    }

    func testCMTIMapsStorageAndIndex() {
        XCTAssertEqual(
            ModemEvent.fromURC("+CMTI: \"ME\",7"),
            .smsArrived(storage: "ME", index: 7)
        )
        XCTAssertEqual(
            ModemEvent.fromURC("+CMTI: \"SM\",12"),
            .smsArrived(storage: "SM", index: 12)
        )
        XCTAssertNil(ModemEvent.fromURC("+CMTI: \"ME\",notanumber"))
    }

    func testCallStateLines() {
        XCTAssertEqual(ModemEvent.fromURC("NO CARRIER"), .callState("NO CARRIER"))
        XCTAssertEqual(ModemEvent.fromURC("BUSY"), .callState("BUSY"))
        XCTAssertEqual(
            ModemEvent.fromURC("+CLCC: 1,1,0,0,0,\"02168888000\",129"),
            .callState("+CLCC: 1,1,0,0,0,\"02168888000\",129")
        )
    }

    func testSIMStatusAndRestartLines() {
        XCTAssertEqual(
            ModemEvent.fromURC("+SIM: removed"),
            .simStatus("+SIM: removed")
        )
        XCTAssertEqual(
            ModemEvent.fromURC("+CIEV: SIM,0"),
            .simStatus("+CIEV: SIM,0")
        )
        XCTAssertEqual(ModemEvent.fromURC("POWERED DOWN"), .moduleRestarted)
        XCTAssertEqual(ModemEvent.fromURC("RDY"), .moduleRestarted)
    }

    func testUnknownLinesMapToNothing() {
        XCTAssertNil(ModemEvent.fromURC("+CSCON: 0"))
        XCTAssertNil(ModemEvent.fromURC("+CREG: 0,2"))
        XCTAssertNil(ModemEvent.fromURC("random text"))
    }

    func testCodableRoundTrip() throws {
        let events: [ModemEvent] = [
            .incomingCall(number: "+8613800138000"),
            .incomingCall(number: nil),
            .callState("BUSY"),
            .smsArrived(storage: "ME", index: 3),
            .simStatus("+CIEV: SIM,0"),
            .disconnected(reason: "device gone"),
            .disconnected(reason: nil),
            .moduleRestarted,
            .gnssNMEA("$GNRMC,123519,A,4807.038,N,01131.000,E"),
        ]

        let data = try JSONEncoder().encode(events)
        XCTAssertEqual(try JSONDecoder().decode([ModemEvent].self, from: data), events)
    }

    // MARK: Event bus

    func testIdleURCReachesSubscriber() async {
        let bus = EC25EventBus()
        let (stream, id) = bus.addSubscriber()
        defer { bus.removeSubscriber(id) }

        bus.deliver(.line("+CMTI: \"ME\",7"))
        bus.deliver(.line("OK"))
        bus.deliver(.prompt)

        let event = await firstEvent(of: stream)
        XCTAssertEqual(event, .smsArrived(storage: "ME", index: 7))
    }

    func testTransactionReceivesEventsWhileActive() async {
        let bus = EC25EventBus()
        let mailbox = bus.beginTransaction()

        bus.deliver(.line("+CSQ: 20,99"))
        bus.deliver(.line("OK"))
        bus.endTransaction()

        let deadline = Date().addingTimeInterval(1)
        XCTAssertEqual(mailbox.wait(until: deadline), .event(.line("+CSQ: 20,99")))
        XCTAssertEqual(mailbox.wait(until: deadline), .event(.line("OK")))
    }

    func testCloseEndsStreamsAndMailbox() async {
        let bus = EC25EventBus()
        let (stream, _) = bus.addSubscriber()
        let mailbox = bus.beginTransaction()

        bus.deliverClosed(reason: "device removed")

        // Idempotent second close.
        bus.deliverClosed(reason: nil)

        let deadline = Date().addingTimeInterval(1)
        XCTAssertEqual(mailbox.wait(until: deadline), .closed("device removed"))

        let first = await firstEvent(of: stream)
        XCTAssertEqual(first, .disconnected(reason: "device removed"))
        let afterEnd = await firstEvent(of: stream, timeout: 0.2)
        XCTAssertNil(afterEnd)
    }

    func testResetAllowsNewSubscribersAfterClose() async {
        let bus = EC25EventBus()
        bus.deliverClosed(reason: nil)
        bus.reset()

        let (stream, _) = bus.addSubscriber()
        bus.deliver(.line("RING"))

        let event = await firstEvent(of: stream)
        XCTAssertEqual(event, .incomingCall(number: nil))
    }

    func testMailboxWaitTimesOutWithoutEvents() {
        let mailbox = EC25TransactionMailbox()
        let soon = Date().addingTimeInterval(0.05)

        XCTAssertEqual(mailbox.wait(until: soon), .timedOut)
    }

    func testUnknownIdleLinesReachNoSubscriber() async {
        let bus = EC25EventBus()
        let (stream, id) = bus.addSubscriber()
        defer { bus.removeSubscriber(id) }

        bus.deliver(.line("+CSCON: 0"))
        bus.deliver(.line("some stray text"))
        bus.deliver(.prompt)

        let event = await firstEvent(of: stream, timeout: 0.2)
        XCTAssertNil(event)
    }

    // MARK: Remote piggyback hub

    func testRemoteHubReplaysBufferedEventsOnAttach() async {
        let hub = RemoteEventHub()
        hub.push([.smsArrived(storage: "ME", index: 1), .incomingCall(number: nil)])

        let stream = hub.attach()
        let first = await firstEvent(of: stream)
        XCTAssertEqual(first, .smsArrived(storage: "ME", index: 1))
        let second = await firstEvent(of: stream)
        XCTAssertEqual(second, .incomingCall(number: nil))
    }

    func testRemoteHubDrainClearsBuffer() {
        let hub = RemoteEventHub()
        hub.push([.moduleRestarted])
        XCTAssertEqual(hub.drain(), [.moduleRestarted])
        XCTAssertEqual(hub.drain(), [])
    }

    // MARK: Helpers

    private func firstEvent(
        of stream: AsyncStream<ModemEvent>,
        timeout: TimeInterval = 1
    ) async -> ModemEvent? {
        await withTaskGroup(of: ModemEvent?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
    }
}
