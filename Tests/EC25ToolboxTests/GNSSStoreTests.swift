import XCTest
@testable import EC25Toolbox

/// Records AT commands and answers from a scripted table without touching
/// USB or the network.
actor GNSSScriptedTransport: ModemTransport {
    private(set) var commands: [String] = []
    private var responses: [String: [String]] = [:]
    private var sequences: [String: [[String]]] = [:]
    private var failures: [String: [Error]] = [:]

    func setResponse(_ command: String, lines: [String]) {
        responses[command] = lines
    }

    /// Successive responses for one command; the first transact pops the
    /// first entry, later transacts keep returning the last one.
    func setResponseSequence(_ command: String, _ lineGroups: [[String]]) {
        sequences[command] = lineGroups
    }

    func setFailure(_ command: String, error: Error, times: Int) {
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
final class GNSSStoreTests: XCTestCase {
    private func makeStore() -> (ModemStore, GNSSScriptedTransport) {
        let store = ModemStore(
            callLogStore: CallLogStore(applicationSupportDirectory: URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true
            ))
        )
        let mock = GNSSScriptedTransport()
        store.transport = mock
        store.state.connected = true
        store.state.capabilities.gnss = .supported
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

    private func commands(_ mock: GNSSScriptedTransport) async -> [String] {
        await mock.commands
    }

    // MARK: - Idempotent start

    func testStartWithRunningEngineSkipsQGPSStart() async {
        let (store, mock) = makeStore()
        await mock.setResponse("AT+QGPS?", lines: ["+QGPS: 1", "OK"])

        store.startGNSS()
        await waitUntil { store.state.gnss.phase == .searching }

        XCTAssertEqual(store.state.gnss.phase, .searching)
        // Already running: no QGPSCFG, no second QGPS=1.
        let sent = await commands(mock)
        XCTAssertEqual(sent, ["AT+QGPS?"])
        XCTAssertNil(store.state.lastError)
        store.stopGNSS()
    }

    func testStartColdPathQueriesStateConfiguresAndStarts() async {
        let (store, mock) = makeStore()
        await mock.setResponse("AT+QGPS?", lines: ["+QGPS: 0", "OK"])

        store.startGNSS()
        await waitUntil { store.state.gnss.phase == .searching }

        let sent = await commands(mock)
        XCTAssertEqual(sent, ["AT+QGPS?", "AT+QGPSCFG=\"nmeasrc\",1", "AT+QGPS=1"])
        store.stopGNSS()
    }

    func testAlreadyActiveRejectionIsNotAFailure() async {
        let (store, mock) = makeStore()
        // First read reports the engine off; the recovery re-check after the
        // rejected start sees it running.
        await mock.setResponseSequence("AT+QGPS?", [
            ["+QGPS: 0", "OK"],
            ["+QGPS: 1", "OK"]
        ])
        await mock.setFailure(
            "AT+QGPS=1",
            error: EC25TransportError.sendFailed("+CME ERROR: 504"),
            times: 1
        )

        store.startGNSS()
        await waitUntil { store.state.gnss.phase == .searching }

        XCTAssertEqual(store.state.gnss.phase, .searching)
        XCTAssertNil(store.state.lastError)
        store.stopGNSS()
    }

    // MARK: - Poll outcomes

    func testCME516NumericKeepsSearchingWithoutError() async {
        let (store, mock) = makeStore()
        await mock.setResponse("AT+QGPS?", lines: ["+QGPS: 1", "OK"])
        store.startGNSS()
        await waitUntil { store.state.gnss.phase == .searching }

        await mock.setFailure(
            "AT+QGPSLOC=2",
            error: EC25TransportError.sendFailed("+CME ERROR: 516"),
            times: 5
        )
        await store.runGNSSPollCycle()

        XCTAssertEqual(store.state.gnss.phase, .searching)
        XCTAssertNil(store.state.gnss.lastError)
        store.stopGNSS()
    }

    func testVerboseNoFixedNowIsAlsoNoPosition() async {
        let (store, mock) = makeStore()
        await mock.setResponse("AT+QGPS?", lines: ["+QGPS: 1", "OK"])
        store.startGNSS()
        await waitUntil { store.state.gnss.phase == .searching }

        await mock.setFailure(
            "AT+QGPSLOC=2",
            error: EC25TransportError.sendFailed("+CME ERROR: not fixed now"),
            times: 5
        )
        await store.runGNSSPollCycle()

        XCTAssertEqual(store.state.gnss.phase, .searching)
        XCTAssertNil(store.state.gnss.lastError)
        store.stopGNSS()
    }

    func testFallbackAdvancesToQGPSLOCAndDeliversFix() async {
        let (store, mock) = makeStore()
        await mock.setResponse("AT+QGPS?", lines: ["+QGPS: 1", "OK"])
        store.startGNSS()
        await waitUntil { store.state.gnss.phase == .searching }

        // QGPSLOC=2 rejected twice by this firmware.
        await mock.setFailure(
            "AT+QGPSLOC=2",
            error: EC25TransportError.sendFailed("+CME ERROR: 504"),
            times: 10
        )
        await store.runGNSSPollCycle()
        XCTAssertEqual(store.gnssSourceRuntime.current, .qgpsloc2)
        await store.runGNSSPollCycle()
        XCTAssertEqual(store.gnssSourceRuntime.current, .qgpsloc)
        XCTAssertEqual(store.state.gnss.sourceFailure, "+CME ERROR: 504")

        // The fallback source delivers a position.
        await mock.setResponse(
            "AT+QGPSLOC",
            lines: ["+QGPSLOC: 061951.000,3150.7223N,11711.9293E,1.1,90.0,1,12.50,1.11,0.60,230513,09", "OK"]
        )
        await store.runGNSSPollCycle()

        XCTAssertEqual(store.state.gnss.phase, .fixed)
        XCTAssertEqual(store.state.gnss.dataSource, .qgpsloc)
        XCTAssertEqual(store.gnssSourceRuntime.consecutiveFailures, 0)
        XCTAssertEqual(store.state.gnss.lastFix?.satelliteCount, 9)
        store.stopGNSS()
    }

    func testQGPSGNMEASourceParsesNMEAIntoFix() async {
        let (store, mock) = makeStore()
        await mock.setResponse("AT+QGPS?", lines: ["+QGPS: 1", "OK"])
        store.startGNSS()
        await waitUntil { store.state.gnss.phase == .searching }

        store.gnssSourceRuntime.current = .qgpsgnmea
        await mock.setResponse("AT+QGPSGNMEA", lines: [
            "$GNRMC,061951.000,A,3150.7223,N,11711.9293,E,0.6,12.50,230513,,,A*79",
            "$GNGGA,061951.000,3150.7223,N,11711.9293,E,1,09,1.1,90.0,M,0.0,M,,*4D",
            "OK"
        ])
        await store.runGNSSPollCycle()

        XCTAssertEqual(store.state.gnss.phase, .fixed)
        XCTAssertEqual(store.state.gnss.dataSource, .qgpsgnmea)
        XCTAssertEqual(store.state.gnss.lastFix?.hdop, 1.1)
        store.stopGNSS()
    }

    func testNMEAPortSourceSkipsATQueriesOnMockTransport() async {
        let (store, mock) = makeStore()
        await mock.setResponse("AT+QGPS?", lines: ["+QGPS: 1", "OK"])
        store.startGNSS()
        await waitUntil { store.state.gnss.phase == .searching }
        let baseline = await commands(mock).count

        // A non-EC25Transport session cannot open the USB endpoint. The
        // first cycle records the unavailability and flips back to the
        // AT-port source; the second cycle polls QGPSGNMEA instead of the
        // endpoint.
        store.gnssSourceRuntime.current = .nmeaPort
        await store.runGNSSPollCycle()
        await store.runGNSSPollCycle()

        XCTAssertEqual(store.gnssSourceRuntime.current, .qgpsgnmea)
        XCTAssertEqual(store.state.gnss.sourceFailure, localized("gnss.source.unavailable_remote"))
        let sent = await commands(mock)
        XCTAssertEqual(sent.count, baseline + 1)
        XCTAssertEqual(sent.last, "AT+QGPSGNMEA")
        store.stopGNSS()
    }

    // MARK: - Lifecycle

    func testStopClearsPollAndSourceState() async {
        let (store, mock) = makeStore()
        await mock.setResponse("AT+QGPS?", lines: ["+QGPS: 1", "OK"])
        store.startGNSS()
        await waitUntil { store.state.gnss.phase == .searching }

        store.stopGNSS()
        await waitUntil { store.state.gnss.phase == .off }

        XCTAssertEqual(store.state.gnss.phase, .off)
        XCTAssertNil(store.state.gnss.dataSource)
        XCTAssertNil(store.gnssPollTask)
        let sent = await commands(mock)
        XCTAssertEqual(sent.last, "AT+QGPSEND")
    }

    func testDisconnectMarksEngineLostAndCancelsTasks() async {
        let (store, mock) = makeStore()
        await mock.setResponse("AT+QGPS?", lines: ["+QGPS: 1", "OK"])
        store.startGNSS()
        await waitUntil { store.state.gnss.phase == .searching }

        await store.markDisconnected(logRemoval: false)

        XCTAssertEqual(store.state.gnss.phase, .lost)
        XCTAssertNil(store.gnssPollTask)
        XCTAssertNil(store.gnssNMEATask)
    }

    func testUnsupportedCapabilityRefusesStart() async {
        let (store, mock) = makeStore()
        store.state.capabilities.gnss = .unsupported

        store.startGNSS()
        await waitUntil { store.state.lastError != nil }

        XCTAssertEqual(store.state.gnss.phase, .off)
        let sent = await commands(mock)
        XCTAssertTrue(sent.isEmpty)
    }
}
