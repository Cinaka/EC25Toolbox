import Foundation
@preconcurrency import Network

final class RemoteManagementServer: @unchecked Sendable {
    typealias ErrorHandler = @Sendable (String) -> Void
    typealias USBSessionRepairHandler = @Sendable () async throws -> String

    private let transport: EC25Transport
    private let audioService: CallAudioService
    private let usbSessionRepairHandler: USBSessionRepairHandler?
    private let replayGuard = RemoteReplayGuard()
    private let queue = DispatchQueue(label: "ing.fuyaoskyrocket.ec25toolbox.remote.server", qos: .userInitiated)
    private var listeners: [NWListener] = []
    private var secret = Data()
    private var errorHandler: ErrorHandler?
    private var eventTask: Task<Void, Never>?
    private let eventBuffer = RemoteEventHub()
    private var nmeaEndpoint: EC25NMEAEndpoint?
    private var nmeaTask: Task<Void, Never>?

    init(
        transport: EC25Transport,
        audioService: CallAudioService,
        usbSessionRepairHandler: USBSessionRepairHandler? = nil
    ) {
        self.transport = transport
        self.audioService = audioService
        self.usbSessionRepairHandler = usbSessionRepairHandler
    }

    func start(
        lanPort: Int,
        tailscalePort: Int,
        secret: Data,
        errorHandler: ErrorHandler? = nil
    ) throws -> [String] {
        stop()
        guard secret.count == 32 else { throw RemoteManagementError.invalidPairingKey }
        self.secret = secret
        self.errorHandler = errorHandler
        let connectionSecret = secret

        var endpoints: [String] = []
        for address in remoteBindAddresses() {
            let port = address.kind == .lan ? lanPort : tailscalePort
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                throw RemoteManagementError.invalidPort
            }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(address.host),
                port: nwPort
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                Task { await self.handle(connection, secret: connectionSecret) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    self?.errorHandler?(error.localizedDescription)
                }
            }
            listener.start(queue: queue)
            listeners.append(listener)
            endpoints.append("\(address.host):\(port)")
        }
        guard !listeners.isEmpty else { throw RemoteManagementError.serverUnavailable }
        startEventRelay()
        return endpoints
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        eventBuffer.finish()
        stopNMEARelay()
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        secret.removeAll()
        errorHandler = nil
    }

    /// Consumes transport events continuously so unsolicited modem output
    /// survives between client requests; each response carries what
    /// accumulated since the previous one.
    private func startEventRelay() {
        let buffer = eventBuffer
        let stream = transport.events()
        eventTask = Task.detached(priority: .userInitiated) {
            for await event in stream {
                buffer.push([event])
            }
        }
    }

    private func handle(_ connection: NWConnection, secret: Data) async {
        defer { connection.cancel() }
        do {
            try await RemoteSocket.accept(connection)
            let frame = try await RemoteSocket.receiveFrame(from: connection)
            let request = try RemoteCrypto.open(RemoteRequest.self, data: frame, secret: secret)
            do {
                try await replayGuard.accept(request)
                let response = try await process(request)
                let responseFrame = try RemoteCrypto.seal(response, secret: secret)
                try await RemoteSocket.sendFrame(responseFrame, through: connection)
            } catch {
                let response = RemoteResponse(
                    requestID: request.requestID,
                    success: false,
                    error: error.localizedDescription
                )
                let responseFrame = try RemoteCrypto.seal(response, secret: secret)
                try await RemoteSocket.sendFrame(responseFrame, through: connection)
            }
        } catch {
            // Authentication failures intentionally receive no plaintext response.
        }
    }

    private func process(_ request: RemoteRequest) async throws -> RemoteResponse {
        let events = eventBuffer.drain()
        switch request.kind {
        case .probe:
            if request.repairUSBSession == true {
                try await repairUSBSessionIfNeeded()
            }
            let description = await transport.description()
            return RemoteResponse(
                requestID: request.requestID,
                success: true,
                description: description,
                events: events
            )
        case .at:
            guard let command = request.command,
                  !command.isEmpty,
                  command.count <= 4_096,
                  (request.payload?.utf8.count ?? 0) <= 1_048_576 else {
                throw RemoteManagementError.protocolFailure
            }
            let timeout = min(max(request.timeoutMs ?? 4_000, 500), 120_000)
            let lines = try await transport.send(
                command: command,
                payload: request.payload,
                timeoutMs: timeout
            )
            return RemoteResponse(
                requestID: request.requestID,
                success: true,
                lines: lines,
                events: events
            )
        case .nmeaStart:
            try await startNMEARelay()
            return RemoteResponse(
                requestID: request.requestID,
                success: true,
                events: events
            )
        case .nmeaStop:
            stopNMEARelay()
            return RemoteResponse(
                requestID: request.requestID,
                success: true,
                events: events
            )
        case .audioExchange:
            let samples = request.audioSamples ?? []
            let requestedFrames = min(max(request.requestedAudioFrames ?? 0, 0), 8_000)
            guard samples.count <= 8_000,
                  request.audioSampleRate == 8_000 else {
                throw RemoteManagementError.protocolFailure
            }
            let downlink = await audioService.exchangeRemoteAudio(
                uplink: samples,
                sampleRate: 8_000,
                requestedDownlinkFrames: requestedFrames
            )
            return RemoteResponse(
                requestID: request.requestID,
                success: true,
                events: events,
                audioSamples: downlink,
                audioSampleRate: 8_000
            )
        }
    }

    /// After a confirmed remote configuration change, the client reconnects
    /// through the same encrypted endpoint. If the old USB handle no longer
    /// answers AT, reopen either supported identity on the host and restart
    /// the event relay. Healthy sessions are left untouched.
    private func repairUSBSessionIfNeeded() async throws {
        do {
            _ = try await transport.send(command: "AT", timeoutMs: 2_000)
            return
        } catch {
            if let endpoint = nmeaEndpoint {
                nmeaTask?.cancel()
                nmeaTask = nil
                nmeaEndpoint = nil
                await endpoint.close()
            }
            if let usbSessionRepairHandler {
                // The direct-mode store owns connection state, modem
                // initialization, and its own event subscription. Let it
                // rebuild the complete host session instead of reopening only
                // this server's low-level USB handle.
                _ = try await usbSessionRepairHandler()
            } else {
                // Tests and standalone server users without a store callback
                // still get a functional low-level repair path.
                _ = try await transport.open()
            }
            eventTask?.cancel()
            startEventRelay()
        }
    }

    private func startNMEARelay() async throws {
        guard nmeaEndpoint == nil else { return }
        let endpoint = EC25NMEAEndpoint()
        let excluding = await transport.activeInterfaceNumber
        let identity = await transport.activeUSBIdentity
        let deviceID = await transport.activeDevice?.id
        _ = try await endpoint.open(
            identities: identity.map { [$0] } ?? ModuleUSBIdentity.connectionOrder,
            excludingInterface: excluding,
            targetDeviceID: deviceID
        )
        nmeaEndpoint = endpoint
        let buffer = eventBuffer
        nmeaTask = Task.detached(priority: .utility) {
            for await sentence in await endpoint.sentences() {
                guard !Task.isCancelled else { break }
                buffer.push([.gnssNMEA(sentence)])
            }
        }
    }

    private func stopNMEARelay() {
        nmeaTask?.cancel()
        nmeaTask = nil
        let endpoint = nmeaEndpoint
        nmeaEndpoint = nil
        if let endpoint {
            Task { await endpoint.close() }
        }
    }
}
