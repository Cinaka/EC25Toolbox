import CoreAudio
import Foundation

/// Presents outgoing macOS audio as a private CoreAudio input device.
///
/// A global mono process tap captures every app except EC25 Toolbox itself,
/// preventing the call downlink and ringtone from feeding back into the
/// module uplink. The private aggregate device is consumed by the existing
/// per-device IOProc bridge exactly like a physical microphone. Creating the
/// tap does not start capture; macOS asks for System Audio Recording access
/// when the bridge first starts IO on the aggregate device.
final class SystemAudioCaptureDevice {
    let deviceUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

    init() throws {
        let tap = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tap.name = "EC25 Toolbox System Audio"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        tap.bundleIDs = [AppIdentity.bundleIdentifier]
        tap.isProcessRestoreEnabled = true

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tap, &createdTapID)
        guard tapStatus == noErr, createdTapID != kAudioObjectUnknown else {
            throw CallAudioError.systemAudioUnavailable(tapStatus)
        }
        tapID = createdTapID

        let runtimeUID = CallAudioInputSource.runtimeSystemAudioUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EC25 Toolbox System Audio",
            kAudioAggregateDeviceUIDKey: runtimeUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var createdAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &createdAggregateID
        )
        guard aggregateStatus == noErr, createdAggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(createdTapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw CallAudioError.systemAudioUnavailable(aggregateStatus)
        }
        aggregateDeviceID = createdAggregateID
        deviceUID = runtimeUID
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
