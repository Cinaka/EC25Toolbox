import Foundation

/// One framed element from a raw AT modem byte stream.
enum ATLineFramerOutput: Equatable, Sendable {
    /// A complete, trimmed, non-empty line.
    case line(String)
    /// The `>` data-entry prompt emitted at the start of a line.
    case prompt
}

/// Frames raw bytes from an AT modem into lines and prompt markers.
///
/// The framer is independent of USB chunk boundaries: CR and LF each terminate
/// a line (so CR, LF, CRLF, and LFCR all work), empty lines are dropped, and
/// the modem's `>` data prompt is recognized when it appears at the start of a
/// line, as in the `AT+CMGS` flow. Filtering command echo and classifying
/// final responses versus URCs stays with the consumer.
struct ATLineFramer {
    enum FramingError: Error, Equatable {
        /// A single unterminated line exceeded the byte limit. The partial
        /// buffer is reset when this is thrown; bytes after the offending one
        /// within the same chunk are dropped and framing resumes with the next
        /// chunk.
        case lineTooLong(limit: Int)
    }

    /// Bytes accumulated for the line currently being received.
    private var partial: [UInt8] = []
    /// Byte limit for a single line, guarding against runaway modem output.
    let maxLineBytes: Int

    init(maxLineBytes: Int = 1_048_576) {
        self.maxLineBytes = max(1, maxLineBytes)
    }

    /// Frames incoming bytes and returns every completed output in stream order.
    mutating func accept(_ data: Data) throws(FramingError) -> [ATLineFramerOutput] {
        var outputs: [ATLineFramerOutput] = []

        for byte in data {
            if byte == 0x0D || byte == 0x0A {
                if let line = finishLine() {
                    outputs.append(.line(line))
                }
            } else if byte == 0x3E && partial.isEmpty {
                outputs.append(.prompt)
            } else {
                partial.append(byte)
                if partial.count > maxLineBytes {
                    partial.removeAll(keepingCapacity: true)
                    throw .lineTooLong(limit: maxLineBytes)
                }
            }
        }

        return outputs
    }

    /// Emits a pending unterminated line as a final output, for stream timeout
    /// or end-of-stream handling. Returns `nil` when nothing is buffered.
    mutating func flushPending() -> ATLineFramerOutput? {
        guard let line = finishLine() else { return nil }
        return .line(line)
    }

    /// Whether bytes are buffered for an unterminated line.
    var hasPendingLine: Bool {
        !partial.isEmpty
    }

    /// Completes the buffered line, returning it when it is non-empty after
    /// trimming.
    private mutating func finishLine() -> String? {
        guard !partial.isEmpty else { return nil }
        let line = String(decoding: partial, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        partial.removeAll(keepingCapacity: true)
        return line.isEmpty ? nil : line
    }
}
