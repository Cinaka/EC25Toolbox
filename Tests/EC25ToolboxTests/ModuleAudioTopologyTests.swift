import XCTest
import CoreAudio
@testable import EC25Toolbox

/// R14: module endpoint discovery by USB parent identity — UID parsing,
/// grouping by (vid, pid, location), direction from stream scopes only, and
/// the ordered fallback to name scoring.
final class ModuleAudioTopologyTests: XCTestCase {
    private func makeDevice(
        uid: String,
        name: String = "USB Audio",
        manufacturer: String = "",
        usb: Bool = true,
        hasInput: Bool = false,
        hasOutput: Bool = false
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

    // MARK: - UID parsing

    func testParseDecimalFields() {
        let identity = USBAudioIdentity.parse(uid: "AppleUSBAudioEngine:Quectel:EC25:11388:33001:272:1")
        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.vid, 11_388)
        XCTAssertEqual(identity?.pid, 33_001)
        XCTAssertEqual(identity?.location, 272)
        XCTAssertEqual(identity?.interface, 1)
    }

    func testParseHexFields() {
        let identity = USBAudioIdentity.parse(uid: "AppleUSBAudioEngine:ACME:Widget:0x2C7C:0x0125:0x14300000:3")
        XCTAssertEqual(identity?.vid, 0x2c7c)
        XCTAssertEqual(identity?.pid, 0x0125)
        XCTAssertEqual(identity?.location, 0x1430_0000)
        XCTAssertEqual(identity?.interface, 3)
        XCTAssertEqual(identity?.isKnownModemVendor, true)
    }

    func testParseRejectsNonUSBAndUnderSpecifiedUIDs() {
        XCTAssertNil(USBAudioIdentity.parse(uid: "AppleUSBAudioEngine:OnlyOneNumber:1"))
        XCTAssertNil(USBAudioIdentity.parse(uid: "Built-in Microphone"))
    }

    func testParentKeyIgnoresInterface() {
        let a = USBAudioIdentity.parse(uid: "AppleUSBAudioEngine:X:Y:100:200:9:1")
        let b = USBAudioIdentity.parse(uid: "AppleUSBAudioEngine:X:Y:100:200:9:2")
        XCTAssertEqual(a?.parentKey, b?.parentKey)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Grouping

    func testSidesOfSameParentGroupWithDirectionFromScopes() {
        // The lower interface number is the output side here on purpose:
        // direction must come from stream scopes, never interface numbers.
        let capture = makeDevice(
            uid: "AppleUSBAudioEngine:Baiwang:EC25:11388:33001:272:2",
            hasInput: true
        )
        let playback = makeDevice(
            uid: "AppleUSBAudioEngine:Baiwang:EC25:11388:33001:272:1",
            hasOutput: true
        )
        let resolution = ModuleAudioTopology.resolve(devices: [capture, playback], overrideUID: nil)
        XCTAssertEqual(resolution?.evidence, .usbParentIdentity)
        XCTAssertEqual(resolution?.group.captureDevice?.uid, capture.uid)
        XCTAssertEqual(resolution?.group.playbackDevice?.uid, playback.uid)
        XCTAssertEqual(resolution?.group.isComplete, true)
        XCTAssertEqual(resolution?.groups.count, 1)
    }

    func testKnownModemVendorBeatsOtherCompleteGroups() {
        let otherCapture = makeDevice(
            uid: "AppleUSBAudioEngine:ACME:Headset:4660:22136:5:1", hasInput: true
        )
        let otherPlayback = makeDevice(
            uid: "AppleUSBAudioEngine:ACME:Headset:4660:22136:5:2", hasOutput: true
        )
        let modemCapture = makeDevice(
            uid: "AppleUSBAudioEngine:Quectel:EC25:0x2C7C:33001:272:2", hasInput: true
        )
        let modemPlayback = makeDevice(
            uid: "AppleUSBAudioEngine:Quectel:EC25:0x2C7C:33001:272:1", hasOutput: true
        )
        let resolution = ModuleAudioTopology.resolve(
            devices: [otherCapture, otherPlayback, modemCapture, modemPlayback],
            overrideUID: nil
        )
        XCTAssertEqual(resolution?.group.identity.isKnownModemVendor, true)
        XCTAssertEqual(resolution?.group.captureDevice?.uid, modemCapture.uid)
        XCTAssertEqual(resolution?.groups.count, 2)
    }

    func testControlOnlyGroupIsNotSelectedOverCompleteGroup() {
        // A control-interface-only device parses but exposes no streams;
        // it must not win against a complete group of the same vendor.
        let controlOnly = makeDevice(
            uid: "AppleUSBAudioEngine:Quectel:EC25:0x2C7C:33001:272:0"
        )
        let completeCapture = makeDevice(
            uid: "AppleUSBAudioEngine:Quectel:EC25:0x2C7C:33001:273:2", hasInput: true
        )
        let completePlayback = makeDevice(
            uid: "AppleUSBAudioEngine:Quectel:EC25:0x2C7C:33001:273:1", hasOutput: true
        )
        let resolution = ModuleAudioTopology.resolve(
            devices: [controlOnly, completeCapture, completePlayback],
            overrideUID: nil
        )
        XCTAssertEqual(resolution?.group.isComplete, true)
        XCTAssertEqual(resolution?.group.captureDevice?.uid, completeCapture.uid)
    }

    func testOverrideWinsWhenDevicePresent() {
        let overridden = makeDevice(
            uid: "AppleUSBAudioEngine:Quectel:EC25:0x2C7C:33001:272:2",
            hasInput: true, hasOutput: true
        )
        let autoCapture = makeDevice(
            uid: "AppleUSBAudioEngine:Quectel:EC25:0x2C7C:33001:273:2", hasInput: true
        )
        let autoPlayback = makeDevice(
            uid: "AppleUSBAudioEngine:Quectel:EC25:0x2C7C:33001:273:1", hasOutput: true
        )
        let resolution = ModuleAudioTopology.resolve(
            devices: [overridden, autoCapture, autoPlayback],
            overrideUID: overridden.uid
        )
        XCTAssertEqual(resolution?.evidence, .override)
        XCTAssertEqual(resolution?.group.captureDevice?.uid, overridden.uid)
        XCTAssertEqual(resolution?.group.playbackDevice?.uid, overridden.uid)
    }

    func testNameScoreFallbackWithoutUSBIdentities() {
        // Vendor drivers without AppleUSBAudioEngine UIDs: the legacy
        // per-direction name matcher still resolves both sides.
        let capture = makeDevice(
            uid: "Baiwang-EC25-Capture", name: "EC25 Audio Input", manufacturer: "Baiwang",
            hasInput: true
        )
        let playback = makeDevice(
            uid: "Baiwang-EC25-Playback", name: "EC25 Audio Output", manufacturer: "Baiwang",
            hasOutput: true
        )
        let resolution = ModuleAudioTopology.resolve(devices: [capture, playback], overrideUID: nil)
        XCTAssertEqual(resolution?.evidence, .nameScoreFallback)
        XCTAssertEqual(resolution?.group.captureDevice?.uid, capture.uid)
        XCTAssertEqual(resolution?.group.playbackDevice?.uid, playback.uid)
    }

    func testNoModuleAnywhereReturnsNil() {
        let macMic = makeDevice(
            uid: "AppleUSBAudioEngine:Apple:Built-in:1452:33344:0:0",
            usb: false, hasInput: true
        )
        XCTAssertNil(ModuleAudioTopology.resolve(devices: [macMic], overrideUID: nil))
    }

    func testEvidenceLocalizationKeys() {
        XCTAssertEqual(ModuleTopologyEvidence.override.localizationKey, "callaudio.topology.override")
        XCTAssertEqual(ModuleTopologyEvidence.usbParentIdentity.localizationKey, "callaudio.topology.usb_parent")
        XCTAssertEqual(ModuleTopologyEvidence.nameScoreFallback.localizationKey, "callaudio.topology.name_fallback")
    }
}
