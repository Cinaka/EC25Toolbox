import Foundation

/// A source of framed input events that a command transaction can wait on.
/// The continuous reader is the source during interface probes; committed
/// sessions wait on a mailbox fed by the event dispatcher.
protocol EC25InputSource: Sendable {
    func wait(until deadline: Date) -> EC25InputWait
}

extension EC25InputReader: EC25InputSource {}

/// Mailbox that buffers framed events for the single in-flight command
/// transaction. The event dispatcher delivers here while a transaction owns
/// the session, so unsolicited output never blocks between commands.
final class EC25TransactionMailbox: @unchecked Sendable, EC25InputSource {
    private let condition = NSCondition()
    private var pending: [EC25InputEvent] = []
    private var closedMessage: String?
    private var closed = false

    /// Queues one event and wakes a waiting transaction.
    func enqueue(_ event: EC25InputEvent) {
        condition.lock()
        pending.append(event)
        condition.broadcast()
        condition.unlock()
    }

    /// Ends the mailbox, optionally with the reader's terminal message.
    func close(with message: String?) {
        condition.lock()
        closed = true
        if closedMessage == nil {
            closedMessage = message
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until an event is queued, the mailbox closes, or the deadline
    /// passes. Queued events are drained before reporting closure.
    func wait(until deadline: Date) -> EC25InputWait {
        condition.lock()
        defer { condition.unlock() }

        while true {
            if !pending.isEmpty {
                return .event(pending.removeFirst())
            }
            if closed {
                return .closed(closedMessage)
            }
            guard deadline.timeIntervalSinceNow > 0, condition.wait(until: deadline) else {
                return .timedOut
            }
        }
    }
}

/// Routes framed input between the active command transaction and subscriber
/// streams of `ModemEvent`, and finishes every stream when the session ends.
final class EC25EventBus: @unchecked Sendable {
    private let condition = NSCondition()
    private var continuations: [UUID: AsyncStream<ModemEvent>.Continuation] = [:]
    private var mailbox: EC25TransactionMailbox?
    private var closed = false

    /// Registers a subscriber stream. Streams finish when the session ends;
    /// consumers subscribe again after reconnecting.
    func addSubscriber() -> (stream: AsyncStream<ModemEvent>, id: UUID) {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: ModemEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        condition.lock()
        if closed {
            continuation.finish()
        } else {
            continuations[id] = continuation
        }
        condition.unlock()
        return (stream, id)
    }

    func removeSubscriber(_ id: UUID) {
        condition.lock()
        continuations[id] = nil
        condition.unlock()
    }

    /// Starts the mailbox for the next command transaction.
    func beginTransaction() -> EC25TransactionMailbox {
        condition.lock()
        let mailbox = EC25TransactionMailbox()
        self.mailbox = mailbox
        condition.unlock()
        return mailbox
    }

    /// Ends the active transaction; later deliveries revert to subscribers.
    func endTransaction() {
        condition.lock()
        mailbox = nil
        condition.unlock()
    }

    /// Delivers one framed event from the continuous reader. While a
    /// transaction is active the event belongs to it; otherwise unsolicited
    /// lines surface on the subscriber streams.
    func deliver(_ event: EC25InputEvent) {
        condition.lock()
        if closed {
            condition.unlock()
            return
        }
        if let mailbox {
            condition.unlock()
            mailbox.enqueue(event)
            return
        }

        if case let .line(line) = event,
           case .urc = ATLineClassifier.classify(line: line, pendingCommand: nil),
           let domainEvent = ModemEvent.fromURC(line) {
            for continuation in continuations.values {
                continuation.yield(domainEvent)
            }
        }
        condition.unlock()
    }

    /// Emits transaction-diverted unsolicited lines onto the subscriber
    /// streams once the transaction has read them out.
    func emitURCs(_ lines: [String]) {
        condition.lock()
        if closed || lines.isEmpty {
            condition.unlock()
            return
        }
        for line in lines {
            guard let domainEvent = ModemEvent.fromURC(line) else { continue }
            for continuation in continuations.values {
                continuation.yield(domainEvent)
            }
        }
        condition.unlock()
    }

    /// Ends the session: the pending transaction (if any) is closed with the
    /// reason, subscribers receive a final `.disconnected`, and every stream
    /// finishes. Idempotent.
    func deliverClosed(reason: String?) {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        closed = true
        let pendingMailbox = mailbox
        mailbox = nil
        let continuations = continuations
        self.continuations.removeAll()
        condition.unlock()

        pendingMailbox?.close(with: reason)
        for continuation in continuations.values {
            continuation.yield(ModemEvent.disconnected(reason: reason))
            continuation.finish()
        }
    }

    /// Prepares for a fresh session after a reconnect. Subscribers that held
    /// finished streams must subscribe again.
    func reset() {
        condition.lock()
        closed = false
        condition.unlock()
    }
}
