import Foundation
import AVFAudio

/// Errors surfaced when the duplex bridge cannot run (R14). Localized at the
/// UI edge; the service records the last one.
enum CallAudioError: Error, Equatable {
    /// The capture device exposes no input channels.
    case noCaptureChannels
    /// The playback device exposes no output channels.
    case noPlaybackChannels
    /// The saved device UID no longer maps to a present device.
    case deviceMissing
    /// An IOProc could not be created/started on a device.
    case ioProcFailed(OSStatus)
    /// One endpoint exposed a stream format that could not be converted.
    case formatMismatch(String)
    /// The module's USB voice path or audio composition is disabled.
    case moduleVoiceDisabled
    /// The module's transient UAC forwarding state was not verified.
    case moduleVoiceUnverified
    /// A CoreAudio process tap/private aggregate device could not be created.
    case systemAudioUnavailable(OSStatus)
    /// No physical Mac microphone remains after excluding modem endpoints.
    case noMacInput

    var localizedKey: String {
        switch self {
        case .noCaptureChannels: "callaudio.error.no_capture"
        case .noPlaybackChannels: "callaudio.error.no_playback"
        case .deviceMissing: "callaudio.error.device_missing"
        case .ioProcFailed: "callaudio.error.io_proc"
        case .formatMismatch: "callaudio.error.format_mismatch"
        case .moduleVoiceDisabled: "callaudio.error.voice_disabled"
        case .moduleVoiceUnverified: "callaudio.error.voice_unverified"
        case .systemAudioUnavailable: "callaudio.error.system_audio_unavailable"
        case .noMacInput: "callaudio.error.no_mac_input"
        }
    }
}

/// The sample-format hand-off between one capture device and one playback
/// device. Pure value describing the decision; the bridge executes it.
struct AudioRoutePlan: Equatable, Sendable {
    var sourceRate: Double
    var sourceChannels: UInt32
    var targetRate: Double
    var targetChannels: UInt32

    var needsConversion: Bool {
        sourceRate != targetRate || sourceChannels != targetChannels
    }

    /// float32 non-interleaved staging format at the playback rate — the
    /// connection format for the player node and the AVAudioConverter target.
    var stagingFormat: AVAudioFormat {
        AVAudioFormat(
            standardFormatWithSampleRate: targetRate,
            channels: max(1, targetChannels)
        ) ?? AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1)!
    }
}

/// One device's stream facts as read before the bridge starts (R14).
struct DeviceStreamFacts: Equatable, Sendable {
    var uid: String
    var nominalRate: Double
    var inputChannels: UInt32
    var outputChannels: UInt32
    var settableRate: Bool

    init(
        uid: String,
        nominalRate: Double = 48_000,
        inputChannels: UInt32 = 0,
        outputChannels: UInt32 = 0,
        settableRate: Bool = true
    ) {
        self.uid = uid
        self.nominalRate = nominalRate
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.settableRate = settableRate
    }
}

/// Per-segment frame counters for the whole duplex path (R14): running means
/// every required segment keeps advancing inside the watchdog window — an
/// engine having started proves nothing by itself.
struct DuplexSegmentCounters: Equatable, Sendable {
    /// Mac microphone capture → uplink ring.
    var macMicCaptureFrames: UInt64 = 0
    /// Uplink ring → module playback device.
    var modulePlaybackFrames: UInt64 = 0
    /// Module capture device → downlink ring.
    var moduleCaptureFrames: UInt64 = 0
    /// Downlink ring → Mac speaker device.
    var macSpeakerFrames: UInt64 = 0

    var droppedFrames: UInt64 = 0
    var starvedFrames: UInt64 = 0

    /// Uplink needs mic capture AND module playback to advance.
    func uplinkAdvancing(from previous: DuplexSegmentCounters) -> Bool {
        macMicCaptureFrames > previous.macMicCaptureFrames
            && modulePlaybackFrames > previous.modulePlaybackFrames
    }

    /// Downlink needs module capture AND Mac speaker playback to advance.
    func downlinkAdvancing(from previous: DuplexSegmentCounters) -> Bool {
        moduleCaptureFrames > previous.moduleCaptureFrames
            && macSpeakerFrames > previous.macSpeakerFrames
    }
}

/// Pure watchdog decision (R14): `running`/`streaming` flags are derived only
/// from segment-counter progress between polls, never from "IO started".
enum DuplexWatchdog {
    struct Verdict: Equatable, Sendable {
        var uplinkStreaming: Bool
        var downlinkStreaming: Bool
        var uplinkRunning: Bool { uplinkStreaming }
        var downlinkRunning: Bool { downlinkStreaming }
        /// True only when both directions stream — the gate for starting a
        /// recording of a real conversation.
        var bothDirectionsStreaming: Bool { uplinkStreaming && downlinkStreaming }
    }

    static func evaluate(current: DuplexSegmentCounters, previous: DuplexSegmentCounters?) -> Verdict {
        guard let previous else {
            return Verdict(uplinkStreaming: false, downlinkStreaming: false)
        }
        return Verdict(
            uplinkStreaming: current.uplinkAdvancing(from: previous),
            downlinkStreaming: current.downlinkAdvancing(from: previous)
        )
    }
}

/// Separates callback/frame liveness from actual signal energy. A CoreAudio
/// device can advance every counter while delivering only digital zeroes.
enum AudioSignalDetector {
    /// About -100 dBFS: low enough for speech/system playback while treating
    /// exact and near-digital silence as absent.
    static let silenceThreshold: Float = 0.000_01

    static func hasSignal(peak: Float?) -> Bool {
        guard let peak, peak.isFinite else { return false }
        return peak >= silenceThreshold
    }
}

/// Pure epoch guard for rebuild/racing decisions (R14): a rebuild result may
/// only install when the call epoch it was planned for is still current.
enum BridgeEpochGuard {
    static func shouldInstall(rebuildEpoch: Int, currentEpoch: Int) -> Bool {
        rebuildEpoch == currentEpoch
    }
}
