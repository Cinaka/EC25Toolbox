import CoreAudio
import XCTest
@testable import EC25Toolbox

/// R3 static call-audio decision tests: direction-split module matching,
/// pre-link gating, bounded queue pacing, and phase gating.
final class CallAudioPreflightTests: XCTestCase {
    private func device(
        _ uid: String,
        name: String,
        input: Bool,
        output: Bool,
        transport: UInt32 = kAudioDeviceTransportTypeUSB
    ) -> AudioDeviceSummary {
        AudioDeviceSummary(
            uid: uid,
            name: name,
            manufacturer: "Quectel",
            transportType: transport,
            hasInput: input,
            hasOutput: output
        )
    }

    // MARK: - Direction-split module matching

    func testDirectionSplitPicksEndpointsIndependently() {
        let devices = [
            device("in-only", name: "EC25 In", input: true, output: false),
            device("out-only", name: "EC25 Out", input: false, output: true)
        ]
        let input = ModuleAudioMatcher.bestMatch(in: devices, overrideUID: nil, direction: .input)
        let output = ModuleAudioMatcher.bestMatch(in: devices, overrideUID: nil, direction: .output)
        XCTAssertEqual(input?.uid, "in-only")
        XCTAssertEqual(output?.uid, "out-only")
    }

    func testOverrideWithoutDirectionFallsBackToAuto() {
        let devices = [
            device("no-direction", name: "EC25 Ghost", input: false, output: false),
            device("both", name: "EC25 Card", input: true, output: true)
        ]
        // The override exists but cannot capture; it must not win for .input.
        let input = ModuleAudioMatcher.bestMatch(
            in: devices,
            overrideUID: "no-direction",
            direction: .input
        )
        XCTAssertEqual(input?.uid, "both")
    }

    // MARK: - Pre-link gating

    func testDeniedMicDisablesUplinkOnly() {
        let preflight = CallAudioPreflight.decide(
            micPermission: .denied,
            moduleInput: device("m", name: "EC25", input: true, output: true),
            moduleOutput: device("m", name: "EC25", input: true, output: true)
        )
        XCTAssertFalse(preflight.uplink.allowed)
        XCTAssertEqual(preflight.uplink.errorKey, "callaudio.error.mic_denied")
        XCTAssertTrue(preflight.downlink.allowed)
    }

    func testMissingModuleEndpointsDisableBothDirections() {
        let preflight = CallAudioPreflight.decide(
            micPermission: .granted,
            moduleInput: nil,
            moduleOutput: nil
        )
        XCTAssertEqual(preflight.uplink.errorKey, "callaudio.error.no_module_output")
        XCTAssertEqual(preflight.downlink.errorKey, "callaudio.error.no_module_input")
    }

    func testUndeterminedPermissionStillAllowsUplink() {
        // Undetermined can still prompt at the system level via TCC on first
        // engine start; only an explicit denial blocks the link.
        let preflight = CallAudioPreflight.decide(
            micPermission: .undetermined,
            moduleInput: device("m", name: "EC25", input: true, output: true),
            moduleOutput: device("m", name: "EC25", input: true, output: true)
        )
        XCTAssertTrue(preflight.uplink.allowed)
        XCTAssertTrue(preflight.downlink.allowed)
    }

    // MARK: - Bounded queue pacing

    func testGaugeAdmitsBelowWatermarkAndCountsUnderruns() {
        var gauge = AudioQueueGauge()
        XCTAssertTrue(gauge.admit(1_024))
        XCTAssertEqual(gauge.scheduledFrames, 1_024)
        // First admission into an empty queue means the player had run dry.
        XCTAssertEqual(gauge.underruns, 1)
    }

    func testGaugeDropsPastWatermark() {
        var gauge = AudioQueueGauge(highWaterFrames: 2_048)
        XCTAssertTrue(gauge.admit(2_048))
        XCTAssertFalse(gauge.admit(1))
        XCTAssertEqual(gauge.droppedFrames, 1)
        XCTAssertEqual(gauge.queuedFrames, 2_048)
    }

    func testGaugeRenderProgressDrainsQueueAndClamps() {
        var gauge = AudioQueueGauge()
        XCTAssertTrue(gauge.admit(1_000))
        gauge.noteRendered(totalFrames: 400)
        XCTAssertEqual(gauge.queuedFrames, 600)
        // A clock reset (late report) must not underflow the counters.
        gauge.noteRendered(totalFrames: 0)
        XCTAssertEqual(gauge.queuedFrames, 600)
        gauge.noteRendered(totalFrames: 5_000)
        XCTAssertEqual(gauge.queuedFrames, 0)
    }

    // MARK: - Phase gating (R2/R3 boundary)

    func testLinksOnlyFlowWhileConnected() {
        for phase in [CallPhase.active, .held] {
            let needed = CallAudioController.linksNeeded(for: phase)
            XCTAssertTrue(needed.uplink && needed.downlink, "\(phase) must keep both links")
        }
        for phase in [CallPhase.idle, .incoming, .answering, .dialing, .alerting, .ending, .ended, .failed, .missed] {
            let needed = CallAudioController.linksNeeded(for: phase)
            XCTAssertFalse(needed.uplink || needed.downlink, "\(phase) must not run links")
        }
    }
}
