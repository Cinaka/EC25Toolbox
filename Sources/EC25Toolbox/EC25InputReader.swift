import Foundation
import IOUSBHost

/// One framed input element delivered by the continuous reader.
enum EC25InputEvent: Equatable, Sendable {
    case line(String)
    case prompt
    /// The framer discarded an oversized line; carries a user-facing message.
    case framingFailure(String)
}

/// Outcome of waiting for the next input event.
enum EC25InputWait: Equatable, Sendable {
    case event(EC25InputEvent)
    /// The reader stopped; the message is `nil` for an orderly stop.
    case closed(String?)
    case timedOut
}

/// Continuously reads the modem input pipe and frames it into AT lines.
///
/// The reader's background thread is the only code that issues reads on the
/// input pipe. `EC25Transport` consumes framed events instead of touching the
/// endpoint directly, so unsolicited modem output keeps flowing between
/// command transactions. All mutable state is guarded by `condition`, which
/// doubles as the signal channel for waiting consumers.
final class EC25InputReader: @unchecked Sendable {
    private let pipe: IOUSBHostPipe
    private let readTimeout: TimeInterval
    private let condition = NSCondition()

    // State guarded by `condition`.
    private var framer = ATLineFramer()
    private var pending: [EC25InputEvent] = []
    private var terminalMessage: String?
    private var stopRequested = false
    private var finished = false
    private var thread: Thread?

    init(pipe: IOUSBHostPipe, readTimeout: TimeInterval = 0.25) {
        self.pipe = pipe
        self.readTimeout = readTimeout
    }

    /// Starts the background read loop. Calling this more than once is a no-op.
    func start() {
        condition.lock()
        guard thread == nil, !stopRequested, !finished else {
            condition.unlock()
            return
        }
        let readerThread = Thread(block: { [weak self] in self?.runLoop() })
        readerThread.name = "ing.fuyaoskyrocket.ec25toolbox.transport.reader"
        readerThread.qualityOfService = .userInitiated
        thread = readerThread
        condition.unlock()
        readerThread.start()
    }

    /// Requests the read loop to stop and waits briefly for the thread to exit,
    /// so callers may safely destroy the underlying interface afterwards.
    func stop() {
        condition.lock()
        stopRequested = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(2)
        while !finished && deadline.timeIntervalSinceNow > 0 {
            condition.wait(until: deadline)
        }
        condition.unlock()
    }

    /// Blocks until an event is available, the reader shuts down, or the
    /// deadline passes. Queued events are drained before reporting shutdown.
    func wait(until deadline: Date) -> EC25InputWait {
        condition.lock()
        defer { condition.unlock() }

        while true {
            if !pending.isEmpty {
                return .event(pending.removeFirst())
            }
            if terminalMessage != nil || stopRequested {
                return .closed(terminalMessage)
            }
            guard deadline.timeIntervalSinceNow > 0, condition.wait(until: deadline) else {
                return .timedOut
            }
        }
    }

    /// Drops every queued event so the next transaction starts from a clean
    /// stream.
    func purge() {
        condition.lock()
        pending.removeAll(keepingCapacity: true)
        condition.unlock()
    }

    /// Flushes the framer's unterminated partial line, if any, without
    /// stopping the reader. Honors a final response that never received its
    /// terminator before the deadline.
    func flushPendingLine() -> String? {
        condition.lock()
        defer { condition.unlock() }
        if case let .line(line)? = framer.flushPending() {
            return line
        }
        return nil
    }

    private func runLoop() {
        loop: while true {
            condition.lock()
            let shouldStop = stopRequested
            condition.unlock()
            if shouldStop { break }

            switch Self.read(from: pipe, timeout: readTimeout) {
            case let .failed(message):
                terminate(with: message)
                break loop
            case let .chunk(data):
                if let data {
                    frame(data)
                }
            }
        }

        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Frames received bytes into queued events and wakes waiting consumers.
    private func frame(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }

        do {
            for output in try framer.accept(data) {
                switch output {
                case let .line(line):
                    pending.append(.line(line))
                case .prompt:
                    pending.append(.prompt)
                }
            }
        } catch {
            pending.append(.framingFailure(localized("transport.response_too_large")))
        }
        condition.broadcast()
    }

    private func terminate(with message: String) {
        condition.lock()
        if terminalMessage == nil {
            terminalMessage = message
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Reads one chunk from the input pipe. A `chunk(nil)` outcome is a read
    /// timeout so the loop can re-check its stop flag.
    private enum ChunkReadOutcome {
        case chunk(Data?)
        case failed(String)
    }

    private static func read(from pipe: IOUSBHostPipe, timeout: TimeInterval) -> ChunkReadOutcome {
        let buffer = NSMutableData(length: 512)!
        var transferred = 0
        do {
            try pipe.__sendIORequest(
                with: buffer,
                bytesTransferred: &transferred,
                completionTimeout: timeout
            )
        } catch let error as NSError where Int32(truncatingIfNeeded: error.code) == kIOReturnTimeout {
            return .chunk(nil)
        } catch {
            let nsError = error as NSError
            return .failed("\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]")
        }

        guard transferred > 0 else { return .chunk(Data()) }
        return .chunk(Data(bytes: buffer.bytes, count: transferred))
    }
}
