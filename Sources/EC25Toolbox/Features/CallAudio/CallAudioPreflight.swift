import Foundation

/// Mac microphone permission as read at link-(re)build time.
enum CallAudioMicPermission: String, Equatable, Sendable {
    case granted
    case denied
    case undetermined
    /// System-output capture uses System Audio Recording permission instead.
    case notRequired

    var localizationKey: String {
        switch self {
        case .granted: "callaudio.permission.granted"
        case .denied: "callaudio.permission.denied"
        case .undetermined: "callaudio.permission.undetermined"
        case .notRequired: "callaudio.permission.not_required"
        }
    }
}

/// Pure pre-link decision (R3): every gate that can be evaluated *before* an
/// engine starts, so a denied microphone or a one-direction-only module
/// endpoint surfaces as a precise error instead of a silently dead link that
/// reports success on zero-filled input.
struct CallAudioPreflight: Equatable, Sendable {
    struct LinkVerdict: Equatable, Sendable {
        var allowed: Bool
        /// nil when allowed; otherwise a localization key for the UI.
        var errorKey: String?
    }

    var uplink: LinkVerdict
    var downlink: LinkVerdict

    /// - Uplink (Mac mic → module output side) needs microphone permission and
    ///   a module endpoint that can play.
    /// - Downlink (module input side → Mac output) needs a module endpoint that
    ///   can capture; it records no microphone and needs no permission.
    /// - `moduleVoiceReady` is set by the call-preparation command
    ///   `AT+QPCMV=1,2`; false and unknown both block the bridge instead of
    ///   presenting all-zero UAC callbacks as a working link.
    static func decide(
        micPermission: CallAudioMicPermission,
        hasUplinkSource: Bool = true,
        moduleInput: AudioDeviceSummary?,
        moduleOutput: AudioDeviceSummary?,
        moduleVoiceReady: Bool? = true
    ) -> CallAudioPreflight {
        let uplink: LinkVerdict
        if micPermission == .denied {
            uplink = LinkVerdict(allowed: false, errorKey: "callaudio.error.mic_denied")
        } else if !hasUplinkSource {
            uplink = LinkVerdict(allowed: false, errorKey: "callaudio.error.no_mac_input")
        } else if moduleVoiceReady == false {
            uplink = LinkVerdict(allowed: false, errorKey: "callaudio.error.voice_disabled")
        } else if moduleVoiceReady == nil {
            uplink = LinkVerdict(allowed: false, errorKey: "callaudio.error.voice_unverified")
        } else if moduleOutput == nil || moduleOutput?.hasOutput != true {
            uplink = LinkVerdict(allowed: false, errorKey: "callaudio.error.no_module_output")
        } else {
            uplink = LinkVerdict(allowed: true, errorKey: nil)
        }

        let downlink: LinkVerdict
        if moduleVoiceReady == false {
            downlink = LinkVerdict(allowed: false, errorKey: "callaudio.error.voice_disabled")
        } else if moduleVoiceReady == nil {
            downlink = LinkVerdict(allowed: false, errorKey: "callaudio.error.voice_unverified")
        } else if moduleInput == nil || moduleInput?.hasInput != true {
            downlink = LinkVerdict(allowed: false, errorKey: "callaudio.error.no_module_input")
        } else {
            downlink = LinkVerdict(allowed: true, errorKey: nil)
        }

        return CallAudioPreflight(uplink: uplink, downlink: downlink)
    }
}

/// Bounded pacing between the capture tap and the player node (R3). The
/// player's internal scheduling queue is not bounded by itself; this gauge
/// drops new buffers once the queued watermark is exceeded (overrun) and
/// counts starved players (underrun), so the tap stays real-time safe and the
/// queue can never grow without limit.
struct AudioQueueGauge: Equatable, Sendable {
    /// Queued-frame ceiling before buffers are dropped (~85 ms at 48 kHz).
    var highWaterFrames: UInt64 = 4_096

    private(set) var scheduledFrames: UInt64 = 0
    private(set) var renderedFrames: UInt64 = 0
    private(set) var droppedFrames: UInt64 = 0
    private(set) var underruns: UInt64 = 0

    /// Frames scheduled but not yet rendered. Never negative: late render
    /// reports are clamped.
    var queuedFrames: UInt64 {
        scheduledFrames - min(renderedFrames, scheduledFrames)
    }

    /// Records player progress; deltas are clamped so a reset player clock
    /// cannot underflow the counters.
    mutating func noteRendered(totalFrames: UInt64) {
        guard totalFrames > renderedFrames else { return }
        renderedFrames = min(totalFrames, scheduledFrames)
    }

    /// Whether one more buffer may be scheduled. An admission with an empty
    /// queue counts an underrun: the player ran dry between buffers.
    mutating func admit(_ frames: UInt32) -> Bool {
        if queuedFrames >= highWaterFrames {
            droppedFrames += UInt64(frames)
            return false
        }
        if queuedFrames == 0 {
            underruns += 1
        }
        scheduledFrames += UInt64(frames)
        return true
    }
}
