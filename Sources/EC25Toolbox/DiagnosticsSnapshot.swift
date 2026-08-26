import Foundation

/// SMS listing mode the refresh pipeline currently runs in, for diagnostics.
enum SMSDiagnosticsRefreshMode: String, Codable, Sendable {
    case pdu
    case text
    case undetermined

    init(smsPDUModeUsable: Bool?) {
        switch smsPDUModeUsable {
        case true: self = .pdu
        case false: self = .text
        case nil: self = .undetermined
        }
    }
}

/// A redacted point-in-time diagnostics snapshot covering the subsystems the
/// R0-R7 acceptance loop needs: firmware capabilities, call state,
/// notifications, call audio, GNSS, and SMS.
///
/// Safe by construction (R0): a snapshot must never contain SIM PINs, full
/// APDU payloads, complete phone numbers, or SMS bodies. The call section
/// records only the phase and whether a remote party is present; command
/// mirrors reuse the already-redacted `ATLogPrivacy` pipeline output. Encode
/// with `JSONEncoder` for export or bug reports.
struct DiagnosticsSnapshot: Codable, Equatable, Sendable {
    struct FirmwareSection: Codable, Equatable, Sendable {
        var model = "-"
        var revision = "-"
        /// `GNSSCapability` raw value: unknown/supported/unsupported/error.
        var gnss = GNSSCapability.unknown.rawValue
        var usbVoice = false
        var usbConfiguration = false
        var dtmf = false
        var phonebook = false
        var euicc = false
        var pduSMS = false
    }

    struct CallSection: Codable, Equatable, Sendable {
        /// `CallPhase` case name; never a phone number.
        var phase = "idle"
        /// Whether a remote party is connected, without the digits.
        var hasRemoteParty = false
        var direction: String?
        /// Identity of the tracked call (R8); async results bind to it.
        var epoch = 0
        /// CLCC snapshots that claimed the tracked incoming call was active
        /// without any user answer for that epoch (R8 anomaly).
        var clccActiveAnomalies = 0
        /// True when the tracked call was adopted as externally connected
        /// from a CLCC snapshot rather than tracked from RING/CLIP (R8).
        var externalAdoption = false
        /// Module auto-answer rings from `ATS0?`; nil when not probed (R8).
        var autoAnswerRings: Int?
        /// Redacted incoming-call event timeline, oldest first (R8). Entries
        /// never contain phone numbers — only event kinds, epochs, phases,
        /// and CLCC index/direction/status codes.
        var timeline: [String] = []
    }

    struct NotificationSection: Codable, Equatable, Sendable {
        /// `UNAuthorizationStatus` case name, or "unavailable" when the
        /// process has no notification center (e.g. tests, CLI runs).
        var authorizationStatus: String?
        var microphonePermission = "undetermined"
    }

    struct AudioSection: Codable, Equatable, Sendable {
        var moduleDeviceUID: String?
        var moduleDeviceName: String?
        var inputDeviceUID: String?
        var inputDeviceName: String?
        var outputDeviceUID: String?
        var outputDeviceName: String?
        var uplinkRunning = false
        var downlinkRunning = false
        /// Already-localized, user-presentable failure reason.
        var lastError: String?
    }

    struct GNSSSection: Codable, Equatable, Sendable {
        /// `GNSSPhase` case name.
        var phase = "off"
        /// `GNSSDataSource` raw value for the source that delivered the last
        /// position data, following the R4 fallback chain.
        var dataSource: String?
        /// Structured reason the previous data source was abandoned.
        var sourceFailure: String?
        var lastError: String?
    }

    struct SMSSection: Codable, Equatable, Sendable {
        var refreshMode: SMSDiagnosticsRefreshMode = .undetermined
        var autoCleanEnabled = false
    }

    struct CommandMirror: Codable, Equatable, Sendable {
        var title: String
        /// Redacted command mirror from the `ATLogPrivacy` pipeline.
        var command: String
        /// Response lines as redacted for the in-app log; sensitive
        /// responses appear as count summaries.
        var lines: [String]
        var error: String?
    }

    var generatedAt: Date
    var firmware = FirmwareSection()
    var call = CallSection()
    var notifications = NotificationSection()
    var audio = AudioSection()
    var gnss = GNSSSection()
    var sms = SMSSection()
    /// Last global error string, already user-presentable and redacted.
    var lastError: String?
    /// Most recent commands, newest last, already redacted.
    var recentCommands: [CommandMirror] = []

    /// Builds a snapshot from live state plus the permission readings that
    /// only the caller can collect (`UNUserNotificationCenter` is guarded by
    /// `AppNotificationCenter.isAvailable`, microphone by TCC). Pure with
    /// respect to `state`: nothing sensitive is copied even when present.
    static func build(
        from state: ModemState,
        smsRefreshMode: SMSDiagnosticsRefreshMode,
        autoCleanEnabled: Bool,
        notificationAuthorizationStatus: String?,
        microphonePermissionStatus: String,
        generatedAt: Date
    ) -> DiagnosticsSnapshot {
        var snapshot = DiagnosticsSnapshot(generatedAt: generatedAt)
        snapshot.firmware = FirmwareSection(
            model: state.info.model,
            revision: state.info.revision,
            gnss: state.capabilities.gnss.rawValue,
            usbVoice: state.capabilities.usbVoice,
            usbConfiguration: state.capabilities.usbConfiguration,
            dtmf: state.capabilities.dtmf,
            phonebook: state.capabilities.phonebook,
            euicc: state.capabilities.euicc,
            pduSMS: state.capabilities.pduSMS
        )
        snapshot.call = CallSection(
            phase: String(describing: state.call.phase),
            hasRemoteParty: state.activeCallNumber != nil,
            direction: state.call.direction.map { String(describing: $0) },
            epoch: state.call.epoch,
            clccActiveAnomalies: state.call.clccActiveAnomalies,
            externalAdoption: state.call.isExternalAdoption,
            autoAnswerRings: state.autoAnswerRings,
            timeline: state.callTimeline.entries.suffix(24).map(\.formatted)
        )
        snapshot.notifications = NotificationSection(
            authorizationStatus: notificationAuthorizationStatus,
            microphonePermission: microphonePermissionStatus
        )
        snapshot.audio = AudioSection(
            moduleDeviceUID: state.callAudio.selectedModuleUID,
            moduleDeviceName: state.callAudio.moduleDevice?.name,
            inputDeviceUID: state.callAudio.selectedInputUID,
            inputDeviceName: selectedDeviceName(
                uid: state.callAudio.selectedInputUID, in: state.callAudio.inputDevices
            ),
            outputDeviceUID: state.callAudio.selectedOutputUID,
            outputDeviceName: selectedDeviceName(
                uid: state.callAudio.selectedOutputUID, in: state.callAudio.outputDevices
            ),
            uplinkRunning: state.callAudio.uplinkRunning,
            downlinkRunning: state.callAudio.downlinkRunning,
            lastError: state.callAudio.lastError
        )
        snapshot.gnss = GNSSSection(
            phase: String(describing: state.gnss.phase),
            dataSource: state.gnss.dataSource?.rawValue,
            sourceFailure: state.gnss.sourceFailure,
            lastError: state.gnss.lastError
        )
        snapshot.sms = SMSSection(
            refreshMode: smsRefreshMode,
            autoCleanEnabled: autoCleanEnabled
        )
        snapshot.lastError = state.lastError
        snapshot.recentCommands = state.commandRecords.suffix(5).map {
            CommandMirror(title: $0.title, command: $0.command, lines: Array($0.lines.suffix(3)), error: $0.error)
        }
        return snapshot
    }

    private static func selectedDeviceName(uid: String?, in devices: [AudioDeviceSummary]) -> String? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }?.name
    }
}
