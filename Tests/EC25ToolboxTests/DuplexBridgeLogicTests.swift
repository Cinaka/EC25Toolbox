import XCTest
import CoreAudio
@testable import EC25Toolbox

/// Duplex-bridge decisions: per-segment watchdog verdicts, rebuild epoch
/// guard, preflight module-voice gate, and error localization keys. Native
/// endpoint rates and realtime conversion are covered by
/// `AudioRateConverterRingTests`.
final class DuplexBridgeLogicTests: XCTestCase {
    // MARK: - Watchdog

    private func counters(
        mic: UInt64 = 0,
        modulePlayback: UInt64 = 0,
        moduleCapture: UInt64 = 0,
        speaker: UInt64 = 0
    ) -> DuplexSegmentCounters {
        var value = DuplexSegmentCounters()
        value.macMicCaptureFrames = mic
        value.modulePlaybackFrames = modulePlayback
        value.moduleCaptureFrames = moduleCapture
        value.macSpeakerFrames = speaker
        return value
    }

    func testFirstPollNeverReportsStreaming() {
        let verdict = DuplexWatchdog.evaluate(
            current: counters(mic: 100, modulePlayback: 90, moduleCapture: 80, speaker: 70),
            previous: nil
        )
        XCTAssertEqual(verdict.uplinkStreaming, false)
        XCTAssertEqual(verdict.downlinkStreaming, false)
        XCTAssertEqual(verdict.bothDirectionsStreaming, false)
    }

    func testAllSegmentsAdvancingMeansDuplex() {
        let previous = counters(mic: 100, modulePlayback: 90, moduleCapture: 80, speaker: 70)
        let current = counters(mic: 200, modulePlayback: 190, moduleCapture: 180, speaker: 170)
        let verdict = DuplexWatchdog.evaluate(current: current, previous: previous)
        XCTAssertEqual(verdict.uplinkStreaming, true)
        XCTAssertEqual(verdict.downlinkStreaming, true)
        XCTAssertEqual(verdict.uplinkRunning, true)
        XCTAssertEqual(verdict.bothDirectionsStreaming, true)
    }

    func testModulePlaybackStallKillsUplinkOnly() {
        // Mic keeps capturing, but the module playback side stopped
        // consuming: uplink is NOT streaming even though one segment moves.
        let previous = counters(mic: 100, modulePlayback: 90, moduleCapture: 80, speaker: 70)
        let current = counters(mic: 200, modulePlayback: 90, moduleCapture: 180, speaker: 170)
        let verdict = DuplexWatchdog.evaluate(current: current, previous: previous)
        XCTAssertEqual(verdict.uplinkStreaming, false)
        XCTAssertEqual(verdict.downlinkStreaming, true)
        XCTAssertEqual(verdict.bothDirectionsStreaming, false)
    }

    func testMacSpeakerStallKillsDownlinkOnly() {
        let previous = counters(mic: 100, modulePlayback: 90, moduleCapture: 80, speaker: 70)
        let current = counters(mic: 200, modulePlayback: 190, moduleCapture: 180, speaker: 70)
        let verdict = DuplexWatchdog.evaluate(current: current, previous: previous)
        XCTAssertEqual(verdict.uplinkStreaming, true)
        XCTAssertEqual(verdict.downlinkStreaming, false)
    }

    // MARK: - Epoch guard

    func testEpochGuard() {
        XCTAssertTrue(BridgeEpochGuard.shouldInstall(rebuildEpoch: 3, currentEpoch: 3))
        XCTAssertFalse(BridgeEpochGuard.shouldInstall(rebuildEpoch: 3, currentEpoch: 4))
    }

    // MARK: - Preflight module-voice gate

    private func device(_ uid: String, input: Bool, output: Bool) -> AudioDeviceSummary {
        AudioDeviceSummary(
            uid: uid,
            name: uid,
            manufacturer: "",
            transportType: kAudioDeviceTransportTypeUSB,
            hasInput: input,
            hasOutput: output
        )
    }

    func testModuleVoiceRejectedBlocksBothDirectionsWithPreciseReason() {
        let preflight = CallAudioPreflight.decide(
            micPermission: .granted,
            moduleInput: device("module-in", input: true, output: false),
            moduleOutput: device("module-out", input: false, output: true),
            moduleVoiceReady: false
        )
        XCTAssertEqual(preflight.uplink.allowed, false)
        XCTAssertEqual(preflight.downlink.allowed, false)
        XCTAssertEqual(preflight.uplink.errorKey, "callaudio.error.voice_disabled")
        XCTAssertEqual(preflight.downlink.errorKey, "callaudio.error.voice_disabled")
    }

    func testUnknownModuleVoiceBlocksInsteadOfClaimingAZeroFilledLink() {
        let preflight = CallAudioPreflight.decide(
            micPermission: .granted,
            moduleInput: device("module-in", input: true, output: false),
            moduleOutput: device("module-out", input: false, output: true),
            moduleVoiceReady: nil
        )
        XCTAssertEqual(preflight.uplink.allowed, false)
        XCTAssertEqual(preflight.downlink.allowed, false)
        XCTAssertEqual(preflight.uplink.errorKey, "callaudio.error.voice_unverified")
        XCTAssertEqual(preflight.downlink.errorKey, "callaudio.error.voice_unverified")
    }

    func testMicDeniedStillWinsOverVoiceGate() {
        let preflight = CallAudioPreflight.decide(
            micPermission: .denied,
            moduleInput: device("module-in", input: true, output: false),
            moduleOutput: device("module-out", input: false, output: true),
            moduleVoiceReady: false
        )
        XCTAssertEqual(preflight.uplink.errorKey, "callaudio.error.mic_denied")
    }

    // MARK: - Signal energy

    func testSignalDetectorSeparatesDigitalSilenceFromFrameFlow() {
        XCTAssertFalse(AudioSignalDetector.hasSignal(peak: nil))
        XCTAssertFalse(AudioSignalDetector.hasSignal(peak: 0))
        XCTAssertFalse(AudioSignalDetector.hasSignal(peak: 0.000_001))
        XCTAssertTrue(AudioSignalDetector.hasSignal(peak: 0.001))
    }

    // MARK: - Error keys

    func testCallAudioErrorLocalizationKeys() {
        XCTAssertEqual(CallAudioError.ioProcFailed(-1).localizedKey, "callaudio.error.io_proc")
        XCTAssertEqual(CallAudioError.formatMismatch("48k vs 44.1k").localizedKey, "callaudio.error.format_mismatch")
        XCTAssertEqual(CallAudioError.moduleVoiceDisabled.localizedKey, "callaudio.error.voice_disabled")
    }
}
