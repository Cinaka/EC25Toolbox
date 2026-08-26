import Foundation
import CoreAudio

/// One system audio device as seen by the call-audio service. `uid` is the
/// stable `AudioDeviceUID` string — the numeric `AudioObjectID` changes on
/// every re-enumeration and is only resolved at engine-start time.
struct AudioDeviceSummary: Identifiable, Equatable, Sendable {
    var uid: String
    var name: String
    var manufacturer: String
    /// Raw CoreAudio transport type constant (`kAudioDeviceTransportType*`).
    var transportType: UInt32
    var hasInput: Bool
    var hasOutput: Bool

    var id: String { uid }

    var isUSB: Bool { transportType == kAudioDeviceTransportTypeUSB }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty { return uid }
        return trimmedName
    }
}

/// Stable user-facing call-uplink sources. System audio is represented by a
/// synthetic UID in settings; at call start it resolves to a process-private
/// aggregate-device UID that must never leak into the ordinary device picker.
enum CallAudioInputSource {
    static let systemAudioUID = "ing.fuyaoskyrocket.ec25toolbox.callaudio.system-audio"
    private static let runtimeUIDPrefix = systemAudioUID + ".runtime."

    static func isSystemAudio(_ uid: String?) -> Bool {
        uid == systemAudioUID
    }

    static func runtimeSystemAudioUID() -> String {
        runtimeUIDPrefix + UUID().uuidString
    }

    static func eligiblePhysicalInputs(
        from devices: [AudioDeviceSummary],
        moduleUIDs: Set<String>
    ) -> [AudioDeviceSummary] {
        devices.filter {
            $0.hasInput
                && !moduleUIDs.contains($0.uid)
                && !$0.uid.hasPrefix(runtimeUIDPrefix)
        }
    }

    /// Resolves an actual microphone without ever falling back to one of the
    /// modem's own UAC endpoints. A missing saved selection remains missing;
    /// an unset selection may use another safe physical input when the system
    /// default is the modem.
    static func resolvePhysicalUID(
        selectedUID: String?,
        defaultUID: String?,
        candidates: [AudioDeviceSummary]
    ) -> String? {
        if let selectedUID {
            guard !isSystemAudio(selectedUID) else { return nil }
            return candidates.contains(where: { $0.uid == selectedUID }) ? selectedUID : nil
        }
        if let defaultUID, candidates.contains(where: { $0.uid == defaultUID }) {
            return defaultUID
        }
        return candidates.first?.uid
    }

    /// Resolves the local uplink selection. System Audio is the safe fallback
    /// when no physical microphone remains after excluding modem endpoints;
    /// unlike a microphone, it does not depend on recording permission.
    static func resolveLocalSourceUID(
        selectedUID: String?,
        defaultUID: String?,
        candidates: [AudioDeviceSummary]
    ) -> String {
        if isSystemAudio(selectedUID) {
            return systemAudioUID
        }
        return resolvePhysicalUID(
            selectedUID: selectedUID,
            defaultUID: defaultUID,
            candidates: candidates
        ) ?? systemAudioUID
    }
}

/// Ranks enumerated audio devices for "this is the modem's USB sound card".
/// The module (with USB voice enabled) exposes a USB Audio Class device whose
/// name and manufacturer vary by firmware identity — Quectel, Baiwang, or a
/// re-flashed first-generation DJI dongle — so matching is best-effort string
/// scoring and the user can override it in settings.
enum ModuleAudioMatcher {
    /// Which side of the link the pick must serve; a USB sound card may expose
    /// only one direction on some firmware, so the two endpoints are resolved
    /// independently (R3).
    enum Direction: Equatable, Sendable {
        case input
        case output
        case any

        func isSatisfied(by device: AudioDeviceSummary) -> Bool {
            switch self {
            case .input: device.hasInput
            case .output: device.hasOutput
            case .any: true
            }
        }
    }

    /// nil marks "not a candidate" (non-USB or no known identity marker).
    static func score(_ device: AudioDeviceSummary) -> Int? {
        guard device.isUSB else { return nil }
        let haystack = "\(device.name) \(device.manufacturer)".lowercased()
        var score = 0
        if haystack.contains("quectel") { score += 60 }
        if haystack.contains("baiwang") { score += 50 }
        if haystack.contains("ec25") || haystack.contains("ec21")
            || haystack.contains("ec20") || haystack.contains("ec200") {
            score += 40
        }
        if haystack.contains("modem") { score += 20 }
        // Weak signal only: DJI also ships USB microphones that must lose to
        // any stronger identity.
        if haystack.contains("dji") { score += 5 }
        guard score > 0 else { return nil }
        return score
    }

    /// Picks the module sound card. A saved user override wins only when the
    /// device still exists *and* serves the requested direction; otherwise the
    /// highest-scoring USB candidate that satisfies the direction is chosen.
    static func bestMatch(
        in devices: [AudioDeviceSummary],
        overrideUID: String?,
        direction: Direction = .any
    ) -> AudioDeviceSummary? {
        if let overrideUID, !overrideUID.isEmpty,
           let overridden = devices.first(where: { $0.uid == overrideUID }),
           direction.isSatisfied(by: overridden) {
            return overridden
        }
        let ranked = devices.compactMap { device -> (device: AudioDeviceSummary, score: Int)? in
            guard let score = score(device), direction.isSatisfied(by: device) else { return nil }
            return (device, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.device.uid < rhs.device.uid
        }
        return ranked.first?.device
    }
}

/// Which audio links should run for a call phase. Audio flows only while the
/// call is connected; held calls keep the links so audio resumes without a
/// rebuild when the remote party returns. Ringback and ringtones are playback
/// concerns outside the links.
enum CallAudioController {
    static func linksNeeded(for phase: CallPhase) -> (uplink: Bool, downlink: Bool) {
        switch phase {
        case .active, .held: (true, true)
        case .idle, .incoming, .answering, .dialing, .alerting, .ending, .ended, .failed, .missed:
            (false, false)
        }
    }
}

/// UI snapshot of the call-audio service, mirrored into `ModemState`.
struct CallAudioStatus: Equatable, Sendable {
    /// The module's USB sound card, when one is currently present.
    var moduleDevice: AudioDeviceSummary?
    /// Direction-split module endpoints (R3): the device feeding the downlink
    /// (module → Mac) and the one receiving the uplink (Mac → module). They
    /// usually coincide, but firmware may expose only one side.
    var moduleInputDevice: AudioDeviceSummary?
    var moduleOutputDevice: AudioDeviceSummary?
    /// Module candidates the user can pick from when auto-match is wrong.
    var moduleCandidates: [AudioDeviceSummary] = []
    var inputDevices: [AudioDeviceSummary] = []
    var outputDevices: [AudioDeviceSummary] = []
    /// How the module endpoints were resolved (R14) — a
    /// `callaudio.topology.*` localization key shown as a settings caption.
    var topologyEvidenceKey: String?
    var selectedInputUID: String?
    var selectedOutputUID: String?
    var selectedModuleUID: String?

    /// Audio backend in use; USB PCM would require a verified native endpoint
    /// and is intentionally not implemented (R3 keeps UAC only).
    var backendKey: String = "callaudio.backend.uac"
    /// Raw `AVAudioApplication.recordPermission` reading at (re)build time.
    var micPermissionRaw: String?

    var uplinkRunning = false
    var downlinkRunning = false
    /// Whether each link actually moved frames recently — "running" must mean
    /// audio is flowing, not merely that the engine started (R3).
    var uplinkStreaming = false
    var downlinkStreaming = false
    var uplinkRoute: AudioRoutePlan?
    var downlinkRoute: AudioRoutePlan?
    var uplinkMetrics: CallAudioLinkMetrics?
    var downlinkMetrics: CallAudioLinkMetrics?
    var muted = false
    var speakerEnabled = true
    var volume: Double = 1

    var isRecording = false
    var recordingStartedAt: Date?

    /// Last link failure as a localized, user-presentable reason.
    var lastError: String?
}

/// Realtime-safe per-link counters, snapshotted out under the link's lock.
struct CallAudioLinkMetrics: Equatable, Sendable {
    var inputFrames: UInt64 = 0
    var scheduledFrames: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var underruns: UInt64 = 0
    var conversionErrors: UInt64 = 0
    /// Peak absolute sample observed during the latest watchdog window.
    /// nil means this backend does not expose signal energy.
    var peakLevel: Float?
}
