import Foundation

protocol ModemTransport: Actor {
    func connect() async throws -> String
    func disconnect() async
    func transact(command: String, payload: String?, timeoutMs: Int32) async throws -> [String]
    /// Subscribing never touches transport state, so consumers on any
    /// isolation domain can obtain the stream synchronously.
    nonisolated func events() -> AsyncStream<ModemEvent>
}

extension ModemTransport {
    /// Transports without event support surface an immediately-finished
    /// stream so consumers need no special casing.
    nonisolated func events() -> AsyncStream<ModemEvent> {
        AsyncStream { $0.finish() }
    }
}

extension EC25Transport: ModemTransport {
    func connect() async throws -> String {
        try open()
    }

    func disconnect() async {
        close()
    }

    func transact(command: String, payload: String?, timeoutMs: Int32) async throws -> [String] {
        try send(command: command, payload: payload, timeoutMs: timeoutMs)
    }
}

actor UnavailableRemoteTransport: ModemTransport {
    private let error: RemoteManagementError

    init(error: RemoteManagementError) {
        self.error = error
    }

    func connect() async throws -> String { throw error }
    func disconnect() async {}
    func transact(command: String, payload: String?, timeoutMs: Int32) async throws -> [String] {
        throw error
    }
}
