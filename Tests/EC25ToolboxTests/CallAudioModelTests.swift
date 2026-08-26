import XCTest
import CoreAudio
import AVFAudio
@testable import EC25Toolbox

final class CallAudioModelTests: XCTestCase {
    private func makeDevice(
        uid: String,
        name: String,
        manufacturer: String = "",
        usb: Bool = true,
        hasInput: Bool = true,
        hasOutput: Bool = true
    ) -> AudioDeviceSummary {
        AudioDeviceSummary(
            uid: uid,
            name: name,
            manufacturer: manufacturer,
            transportType: usb ? kAudioDeviceTransportTypeUSB : kAudioDeviceTransportTypeBluetooth,
            hasInput: hasInput,
            hasOutput: hasOutput
        )
    }

    // MARK: - Module sound card matching

    func testUSBQuectelDeviceOutscoresGenericUSBModem() {
        let quectel = makeDevice(uid: "a", name: "EC25 USB Audio", manufacturer: "Quectel")
        let generic = makeDevice(uid: "b", name: "USB Modem Audio", manufacturer: "Generic")

        let picked = ModuleAudioMatcher.bestMatch(in: [generic, quectel], overrideUID: nil)
        XCTAssertEqual(picked?.uid, "a")
        let quectelScore = ModuleAudioMatcher.score(quectel)
        let genericScore = ModuleAudioMatcher.score(generic)
        XCTAssertNotNil(quectelScore)
        XCTAssertNotNil(genericScore)
        XCTAssertGreaterThan(quectelScore!, genericScore!)
    }

    func testNonUSBDevicesAreNeverCandidates() {
        let bluetooth = makeDevice(uid: "a", name: "Quectel EC25", manufacturer: "Quectel", usb: false)
        XCTAssertNil(ModuleAudioMatcher.score(bluetooth))
        XCTAssertNil(ModuleAudioMatcher.bestMatch(in: [bluetooth], overrideUID: nil))
    }

    func testUnmarkedUSBDeviceIsNotACandidate() {
        let plain = makeDevice(uid: "a", name: "USB PnP Audio Device", manufacturer: "ACME")
        XCTAssertNil(ModuleAudioMatcher.score(plain))
    }

    func testDJIIdentityIsWeakAndLosesToQuectel() {
        let dji = makeDevice(uid: "a", name: "DJI USB Audio", manufacturer: "DJI")
        let quectel = makeDevice(uid: "b", name: "EC25 Audio", manufacturer: "Quectel")
        XCTAssertEqual(ModuleAudioMatcher.bestMatch(in: [dji, quectel], overrideUID: nil)?.uid, "b")
        // Still a candidate so re-flashed dongles remain selectable manually.
        XCTAssertNotNil(ModuleAudioMatcher.score(dji))
    }

    func testUserOverrideWinsWhenDevicePresent() {
        let quectel = makeDevice(uid: "a", name: "EC25 USB Audio", manufacturer: "Quectel")
        let other = makeDevice(uid: "b", name: "USB Modem Audio")
        XCTAssertEqual(
            ModuleAudioMatcher.bestMatch(in: [quectel, other], overrideUID: "b")?.uid,
            "b"
        )
    }

    func testOverrideForMissingDeviceFallsBackToAutoMatch() {
        let quectel = makeDevice(uid: "a", name: "EC25 USB Audio", manufacturer: "Quectel")
        XCTAssertEqual(
            ModuleAudioMatcher.bestMatch(in: [quectel], overrideUID: "gone")?.uid,
            "a"
        )
        XCTAssertNil(ModuleAudioMatcher.bestMatch(in: [], overrideUID: "gone"))
    }

    func testEqualScoresResolveStablyByUID() {
        let first = makeDevice(uid: "a", name: "EC25 Audio")
        let second = makeDevice(uid: "b", name: "EC21 Audio")
        XCTAssertEqual(ModuleAudioMatcher.bestMatch(in: [second, first], overrideUID: nil)?.uid, "a")
    }

    // MARK: - Safe uplink sources

    func testPhysicalInputCandidatesExcludeModemAndRuntimeTap() {
        let modem = makeDevice(uid: "module-in", name: "AC Interface", hasOutput: false)
        let microphone = makeDevice(uid: "mac-mic", name: "Mac Microphone", usb: false, hasOutput: false)
        let outputOnly = makeDevice(uid: "speaker", name: "Speaker", usb: false, hasInput: false)
        let tap = makeDevice(
            uid: CallAudioInputSource.runtimeSystemAudioUID(),
            name: "EC25 Toolbox System Audio",
            usb: false,
            hasOutput: false
        )

        let candidates = CallAudioInputSource.eligiblePhysicalInputs(
            from: [modem, microphone, outputOnly, tap],
            moduleUIDs: [modem.uid]
        )
        XCTAssertEqual(candidates.map(\.uid), [microphone.uid])
    }

    func testDefaultModemInputFallsBackOnlyToSafePhysicalMicrophone() {
        let microphone = makeDevice(uid: "mac-mic", name: "Mac Microphone", usb: false, hasOutput: false)
        XCTAssertEqual(
            CallAudioInputSource.resolvePhysicalUID(
                selectedUID: nil,
                defaultUID: "module-in",
                candidates: [microphone]
            ),
            microphone.uid
        )
        XCTAssertNil(CallAudioInputSource.resolvePhysicalUID(
            selectedUID: "missing",
            defaultUID: microphone.uid,
            candidates: [microphone]
        ))
        XCTAssertTrue(CallAudioInputSource.isSystemAudio(CallAudioInputSource.systemAudioUID))
    }

    func testLocalInputFallsBackToSystemAudioWithoutPhysicalMicrophone() {
        XCTAssertEqual(
            CallAudioInputSource.resolveLocalSourceUID(
                selectedUID: nil,
                defaultUID: "module-in",
                candidates: []
            ),
            CallAudioInputSource.systemAudioUID
        )
        XCTAssertEqual(
            CallAudioInputSource.resolveLocalSourceUID(
                selectedUID: "disconnected-mic",
                defaultUID: nil,
                candidates: []
            ),
            CallAudioInputSource.systemAudioUID
        )
    }

    func testLocalInputKeepsSafePhysicalMicrophoneWhenAvailable() {
        let microphone = makeDevice(
            uid: "mac-mic",
            name: "Mac Microphone",
            usb: false,
            hasOutput: false
        )
        XCTAssertEqual(
            CallAudioInputSource.resolveLocalSourceUID(
                selectedUID: nil,
                defaultUID: microphone.uid,
                candidates: [microphone]
            ),
            microphone.uid
        )
    }

    // MARK: - Phase-driven link policy

    func testLinksNeededOnlyForConnectedPhases() {
        for phase in [CallPhase.active, .held] {
            let needed = CallAudioController.linksNeeded(for: phase)
            XCTAssertTrue(needed.uplink, "\(phase) should run the uplink")
            XCTAssertTrue(needed.downlink, "\(phase) should run the downlink")
        }
        for phase in [CallPhase.idle, .incoming, .dialing, .alerting, .ended, .failed, .missed] {
            let needed = CallAudioController.linksNeeded(for: phase)
            XCTAssertFalse(needed.uplink, "\(phase) must not run audio links")
            XCTAssertFalse(needed.downlink, "\(phase) must not run audio links")
        }
    }

    // MARK: - Route planning

    func testRoutePlanDetectsConversionNeeds() {
        let same = AudioRoutePlan(sourceRate: 8_000, sourceChannels: 1, targetRate: 8_000, targetChannels: 1)
        XCTAssertFalse(same.needsConversion)

        let rate = AudioRoutePlan(sourceRate: 8_000, sourceChannels: 1, targetRate: 48_000, targetChannels: 1)
        XCTAssertTrue(rate.needsConversion)

        let channels = AudioRoutePlan(sourceRate: 48_000, sourceChannels: 1, targetRate: 48_000, targetChannels: 2)
        XCTAssertTrue(channels.needsConversion)
    }

    func testStagingFormatMirrorsPlaybackRateAndChannels() {
        let plan = AudioRoutePlan(sourceRate: 48_000, sourceChannels: 1, targetRate: 8_000, targetChannels: 1)
        let staging = plan.stagingFormat
        XCTAssertEqual(staging.sampleRate, 8_000)
        XCTAssertEqual(staging.channelCount, 1)
        XCTAssertEqual(staging.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(staging.isInterleaved)

        let stereo = AudioRoutePlan(sourceRate: 44_100, sourceChannels: 1, targetRate: 44_100, targetChannels: 2)
        XCTAssertEqual(stereo.stagingFormat.channelCount, 2)
        XCTAssertEqual(stereo.stagingFormat.sampleRate, 44_100)
    }

    // MARK: - Dial-pad feedback

    func testDTMFFrequencyMappingUsesStandardRowsAndColumns() {
        XCTAssertEqual(DTMFTone.frequencies(for: "1"), .init(low: 697, high: 1_209))
        XCTAssertEqual(DTMFTone.frequencies(for: "5"), .init(low: 770, high: 1_336))
        XCTAssertEqual(DTMFTone.frequencies(for: "#"), .init(low: 941, high: 1_477))
        XCTAssertEqual(DTMFTone.frequencies(for: "d"), .init(low: 941, high: 1_633))
        XCTAssertNil(DTMFTone.frequencies(for: "+"))
        XCTAssertNil(DTMFTone.frequencies(for: "12"))
    }
}
