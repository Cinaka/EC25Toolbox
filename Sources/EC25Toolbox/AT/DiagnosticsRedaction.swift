import Foundation

/// How a command's diagnostics mirror is treated when it carries or returns
/// subscriber-sensitive data (dial strings, recipients, ICCID, message
/// content). `sendUnlogged` remains the stronger option for secrets such as
/// PINs and APDU payloads, which must not be mirrored at all.
enum ATLogPrivacy {
    /// Command echo and response lines mirror verbatim.
    case plain
    /// The command carries a dial string or message recipient; its argument
    /// is masked in the mirror while responses mirror verbatim.
    case maskArguments
    /// The response carries message content or card identifiers; the command
    /// mirrors verbatim while response lines are replaced by a count summary.
    case suppressResponse
}

/// Masks subscriber-identifying arguments of known commands for the app log.
/// Unknown commands mirror verbatim; only the argument is ever masked, so the
/// operator can still see which command ran.
func redactedCommandMirror(_ command: String) -> String {
    if command.hasPrefix("ATD") {
        let suffix = command.hasSuffix(";") ? ";" : ""
        return "ATD" + String(repeating: "•", count: 4) + suffix
    }
    if let equals = command.range(of: "AT+CMGS=") {
        return command[..<equals.upperBound] + "\"•••\""
    }
    return command
}
