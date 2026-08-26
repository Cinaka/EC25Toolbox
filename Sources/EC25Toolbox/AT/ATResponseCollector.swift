import Foundation

/// Drives one command transaction over framed input events, separating the
/// command's response from unsolicited modem traffic.
struct ATResponseCollector {
    /// Result of absorbing one event.
    enum Outcome: Equatable {
        /// No final response yet; keep consuming.
        case continueReading
        /// `OK` arrived; `responseLines` is the complete response.
        case done
        /// The transaction failed. The message is `nil` for a plain timeout.
        case failed(String?)
    }

    /// The command awaiting a final response, or `nil` when reading outside a
    /// transaction.
    let pendingCommand: String?
    /// Response data lines accumulated so far.
    private(set) var responseLines: [String] = []
    /// Unsolicited lines diverted away from the response.
    private(set) var urcs: [String] = []

    init(pendingCommand: String?) {
        self.pendingCommand = pendingCommand
    }

    /// Absorbs one framed input event.
    mutating func accept(_ event: EC25InputEvent) -> Outcome {
        switch event {
        case let .line(line):
            switch ATLineClassifier.classify(line: line, pendingCommand: pendingCommand) {
            case .echo:
                return .continueReading
            case .urc:
                urcs.append(line)
                return .continueReading
            case .finalOK:
                return .done
            case let .finalError(message):
                return .failed(message)
            case .info:
                responseLines.append(line)
                return .continueReading
            }
        case .prompt:
            return .continueReading
        case let .framingFailure(message):
            return .failed(message)
        }
    }

    /// Settles the transaction at a deadline with the framer's unterminated
    /// tail line, if any. A tail that completes the response honors it;
    /// anything else fails with a plain timeout.
    mutating func finishWithTail(_ tail: String?) -> Outcome {
        if let tail {
            switch ATLineClassifier.classify(line: tail, pendingCommand: pendingCommand) {
            case .finalOK:
                return .done
            case let .finalError(message):
                return .failed(message)
            case .echo, .urc, .info:
                break
            }
        }
        return .failed(nil)
    }
}
