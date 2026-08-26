import XCTest
@testable import EC25Toolbox

private actor FailingInitializationTransport: ModemTransport {
    func connect() async throws -> String { "mock transport" }
    func disconnect() async {}
    func transact(command: String, payload: String?, timeoutMs: Int32) async throws -> [String] {
        throw EC25TransportError.notOpen
    }
}

private actor ReconnectableTerminalTransport: ModemTransport {
    private var isOpen = false
    private var connectCount = 0
    private var commands: [String] = []

    func connect() async throws -> String {
        isOpen = true
        connectCount += 1
        return "mock terminal transport"
    }

    func disconnect() async {
        isOpen = false
    }

    func transact(command: String, payload: String?, timeoutMs: Int32) async throws -> [String] {
        guard isOpen else { throw EC25TransportError.notOpen }
        commands.append(command)
        return []
    }

    func snapshot() -> (connectCount: Int, commands: [String]) {
        (connectCount, commands)
    }
}

private actor PINLockedTransport: ModemTransport {
    private var isOpen = false
    private var commands: [String] = []

    func connect() async throws -> String {
        isOpen = true
        return "mock PIN-locked transport"
    }

    func disconnect() async {
        isOpen = false
    }

    func transact(command: String, payload: String?, timeoutMs: Int32) async throws -> [String] {
        guard isOpen else { throw EC25TransportError.notOpen }
        commands.append(command)
        switch command {
        case "AT+CPIN?":
            return ["+CPIN: SIM PIN"]
        case "AT+QCCID":
            return ["+QCCID: 8986000000000000000F"]
        case "AT+QPINC=\"SC\"":
            return ["+QPINC: \"SC\",3,10"]
        case "AT+CMGF=1", "AT+CSCS=\"UCS2\"":
            throw EC25TransportError.sendFailed("+CME ERROR: SIM PIN required")
        default:
            return []
        }
    }

    func snapshot() -> [String] { commands }
}

final class RemoteManagementTests: XCTestCase {
    func testEC25ATInterfaceProbeOrder() {
        let interfaceNumbers = [0, 1, 2, 3, 4, 8]
        let ordered = interfaceNumbers.sorted {
            EC25Transport.probePriority(interfaceNumber: $0)
                < EC25Transport.probePriority(interfaceNumber: $1)
        }

        XCTAssertEqual(ordered, [2, 3, 1, 0, 4, 8])
    }

    @MainActor
    func testPopoverPinAndStandaloneWindowAreIndependentActions() {
        let presentation = WindowPresentationModel()
        var openedWindows = 0
        presentation.onOpenStandaloneWindow = { openedWindows += 1 }

        presentation.togglePopoverPinned()
        presentation.openStandaloneWindow()

        XCTAssertTrue(presentation.isPopoverPinned)
        XCTAssertEqual(openedWindows, 1)
    }

    @MainActor
    func testFailedInitializationNeverPublishesConnectedState() async {
        let store = ModemStore()
        store.transport = FailingInitializationTransport()

        do {
            try await store.connectImpl(prefix: "test")
            XCTFail("Expected initialization failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, EC25TransportError.notOpen.localizedDescription)
        }
        XCTAssertFalse(store.state.connected)
    }

    @MainActor
    func testPINLockedSIMKeepsModemConnectedWithoutConfiguringSMS() async throws {
        let transport = PINLockedTransport()
        let store = ModemStore()
        store.transport = transport

        try await store.connectImpl(prefix: "test")

        let commands = await transport.snapshot()
        XCTAssertTrue(store.state.connected)
        XCTAssertTrue(store.state.simSecurity.requiresPIN)
        XCTAssertEqual(store.state.simSecurity.pinRetries, 3)
        XCTAssertFalse(commands.contains("AT+CMGF=1"))
        XCTAssertFalse(commands.contains("AT+CSCS=\"UCS2\""))
    }

    @MainActor
    func testTerminalCommandRecoversAClosedTransportOnce() async throws {
        let transport = ReconnectableTerminalTransport()
        let store = ModemStore()
        store.transport = transport
        store.state.connected = true

        _ = try await store.executeTerminalCommand("AT+TESTTERMINAL")

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.connectCount, 1)
        XCTAssertTrue(snapshot.commands.contains("AT+TESTTERMINAL"))
        XCTAssertTrue(store.state.connected)
    }

    func testRenamedKeychainServiceKeepsLegacyMigrationSource() {
        XCTAssertEqual(RemoteAccessKeychain.service, "ing.fuyaoskyrocket.ec25toolbox.remote-access")
        XCTAssertEqual(RemoteAccessKeychain.legacyServices, ["one.nickspace.ec25-manager.remote-access"])
    }

    func testPairingKeyAndAuthenticatedEncryptionRoundTrip() throws {
        let secret = Data((0..<32).map { UInt8($0) })
        let encoded = RemoteAccessKeychain.encodedPairingKey(secret)
        XCTAssertEqual(try RemoteAccessKeychain.decodedPairingKey(encoded), secret)

        let request = RemoteRequest(kind: .at, command: "AT+CSQ", timeoutMs: 5_000)
        let frame = try RemoteCrypto.seal(request, secret: secret)
        XCTAssertNotEqual(frame, try JSONEncoder().encode(request))
        XCTAssertEqual(try RemoteCrypto.open(RemoteRequest.self, data: frame, secret: secret), request)
    }

    func testProtocolV2AudioAndNMEARequestsRoundTrip() throws {
        XCTAssertEqual(RemoteDefaults.protocolVersion, 2)

        let audio = RemoteRequest(
            kind: .audioExchange,
            audioSamples: [0, 0.25, -0.25],
            audioSampleRate: 8_000,
            requestedAudioFrames: 800
        )
        let encodedAudio = try JSONEncoder().encode(audio)
        XCTAssertEqual(try JSONDecoder().decode(RemoteRequest.self, from: encodedAudio), audio)

        let nmea = RemoteRequest(kind: .nmeaStart)
        let encodedNMEA = try JSONEncoder().encode(nmea)
        XCTAssertEqual(try JSONDecoder().decode(RemoteRequest.self, from: encodedNMEA), nmea)

        let repairProbe = RemoteRequest(kind: .probe, repairUSBSession: true)
        let encodedRepairProbe = try JSONEncoder().encode(repairProbe)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteRequest.self, from: encodedRepairProbe),
            repairProbe
        )
    }

    func testWrongPairingKeyCannotDecryptRequest() throws {
        let request = RemoteRequest(kind: .probe)
        let frame = try RemoteCrypto.seal(request, secret: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(
            try RemoteCrypto.open(
                RemoteRequest.self,
                data: frame,
                secret: Data(repeating: 2, count: 32)
            )
        )
    }

    func testReplayAndExpiredRequestsAreRejected() async throws {
        let guardActor = RemoteReplayGuard()
        let request = RemoteRequest(timestamp: 1_000, kind: .probe)
        try await guardActor.accept(request, now: 1_000)
        do {
            try await guardActor.accept(request, now: 1_001)
            XCTFail("Expected replay rejection")
        } catch {
            XCTAssertEqual(error as? RemoteManagementError, .replayedRequest)
        }

        let expired = RemoteRequest(timestamp: 1_000, kind: .probe)
        do {
            try await guardActor.accept(expired, now: 2_000)
            XCTFail("Expected expiry rejection")
        } catch {
            XCTAssertEqual(error as? RemoteManagementError, .requestExpired)
        }
    }

    func testLANAndTailscaleAddressClassification() {
        XCTAssertTrue(isPrivateLANIPv4("192.168.1.20"))
        XCTAssertTrue(isPrivateLANIPv4("172.16.5.2"))
        XCTAssertFalse(isPrivateLANIPv4("8.8.8.8"))
        XCTAssertTrue(isTailscaleIPv4("100.64.0.1"))
        XCTAssertTrue(isTailscaleIPv4("100.127.255.254"))
        XCTAssertFalse(isTailscaleIPv4("100.128.0.1"))
    }

    func testLegacySettingsUseSafeRemoteDefaults() throws {
        let json = #"""
        {
          "openAtLogin": true,
          "infoPollSeconds": 12,
          "smsPollSeconds": 30,
          "restartOnWake": true,
          "visibleFields": ["imei"]
        }
        """#
        let settings = try JSONDecoder().decode(ModemSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.effectiveManagementMode, .direct)
        XCTAssertEqual(settings.effectiveRemoteLANPort, RemoteDefaults.lanPort)
        XCTAssertEqual(settings.effectiveRemoteTailscalePort, RemoteDefaults.tailscalePort)
        XCTAssertTrue(settings.effectiveRemoteSharingEnabled)
    }
}
