import Foundation

/// Locked holder for modem events: the remote transport attaches a
/// subscriber stream fed by events piggybacked on responses, while the
/// management server records events between requests and drains them into
/// the next response.
final class RemoteEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ModemEvent>.Continuation?
    private var buffer: [ModemEvent] = []

    /// Attaches a subscriber stream, finishing any previous one and replaying
    /// buffered events so late subscribers miss nothing.
    func attach() -> AsyncStream<ModemEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ModemEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        lock.lock()
        self.continuation?.finish()
        self.continuation = continuation
        let replay = buffer
        lock.unlock()

        for event in replay {
            continuation.yield(event)
        }
        return stream
    }

    /// Records piggybacked events; dropped silently when nobody subscribed.
    func push(_ events: [ModemEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        buffer.append(contentsOf: events)
        if buffer.count > 128 {
            buffer.removeFirst(buffer.count - 128)
        }
        let continuation = continuation
        lock.unlock()

        for event in events {
            continuation?.yield(event)
        }
    }

    /// Drains and clears the buffered events, e.g. to attach them to the
    /// next outgoing response.
    func drain() -> [ModemEvent] {
        lock.lock()
        let events = buffer
        buffer.removeAll()
        lock.unlock()
        return events
    }

    /// Finishes the active stream and clears the replay buffer.
    func finish() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        buffer.removeAll()
        lock.unlock()
    }
}
