import Foundation
import CoreAudio

/// Enumerates system audio devices and watches for hardware changes. Purely a
/// system-read layer: it owns no engine state and publishes nothing; owners
/// pull `snapshot()` and get called back on `onDevicesChanged` when the device
/// list or a default device changes (module re-enumeration, headphone plugs,
/// default switches). Callbacks arrive on an internal serial queue; owners
/// must hop to their own actor.
final class AudioDeviceCatalog {
    /// Fired when the device list or a default input/output device changed.
    var onDevicesChanged: (() -> Void)?

    private let callbackQueue = DispatchQueue(label: "ing.fuyaoskyrocket.ec25toolbox.audio-catalog")
    private var watching = false
    private var listenerBlocks: [AudioObjectPropertyListenerBlock] = []

    deinit {
        stopWatching()
    }

    private static var watchedSelectors: [AudioObjectPropertySelector] {
        [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
        ]
    }

    private static func address(for selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func startWatching() {
        guard !watching else { return }
        watching = true
        for selector in Self.watchedSelectors {
            var address = Self.address(for: selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onDevicesChanged?()
            }
            listenerBlocks.append(block)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                callbackQueue,
                block
            )
        }
    }

    func stopWatching() {
        guard watching else { return }
        watching = false
        for (index, selector) in Self.watchedSelectors.enumerated() {
            guard index < listenerBlocks.count else { continue }
            var address = Self.address(for: selector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                callbackQueue,
                listenerBlocks[index]
            )
        }
        listenerBlocks.removeAll()
    }

    /// Current device inventory plus the UIDs of the system default
    /// input/output devices.
    func snapshot() -> (all: [AudioDeviceSummary], defaultInputUID: String?, defaultOutputUID: String?) {
        let devices = Self.deviceIDs().compactMap(Self.summarize)
        return (
            devices,
            Self.defaultDeviceUID(selector: kAudioHardwarePropertyDefaultInputDevice),
            Self.defaultDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        )
    }

    /// Resolves a stable device UID to the current (volatile) object ID.
    static func objectID(forUID uid: String) -> AudioObjectID? {
        var uidValue = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &uidValue) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &id
            )
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var count = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &count
        ) == noErr, count > 0 else { return [] }
        let total = Int(count) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: total)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &count, &ids
        ) == noErr else { return [] }
        return ids
    }

    static func summarize(_ id: AudioObjectID) -> AudioDeviceSummary? {
        guard let uid = stringProperty(
            id, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal
        ) else { return nil }
        let name = stringProperty(
            id, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal
        ) ?? ""
        let manufacturer = stringProperty(
            id, selector: kAudioDevicePropertyDeviceManufacturer, scope: kAudioObjectPropertyScopeGlobal
        ) ?? ""
        var transportType = UInt32(0)
        withUnsafeMutablePointer(to: &transportType) { pointer in
            _ = scalarProperty(
                id, selector: kAudioDevicePropertyTransportType,
                scope: kAudioObjectPropertyScopeGlobal, pointer: pointer
            )
        }
        return AudioDeviceSummary(
            uid: uid,
            name: name,
            manufacturer: manufacturer,
            transportType: transportType,
            hasInput: streamCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
            hasOutput: streamCount(id, scope: kAudioObjectPropertyScopeOutput) > 0
        )
    }

    static func defaultDeviceUID(selector: AudioObjectPropertySelector) -> String? {
        var id = AudioObjectID()
        var filled = false
        withUnsafeMutablePointer(to: &id) { pointer in
            filled = scalarProperty(
                AudioObjectID(kAudioObjectSystemObject), selector: selector,
                scope: kAudioObjectPropertyScopeGlobal, pointer: pointer
            )
        }
        guard filled, id != kAudioObjectUnknown, id != 0 else { return nil }
        return stringProperty(
            id, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal
        )
    }

    // MARK: - Format-planning facts (R14)

    /// Pre-bridge stream facts for the duplex format planner: nominal rate,
    /// per-scope channel counts, and whether the rate is programmable (more
    /// than one supported rate). nil when the UID no longer resolves.
    static func streamFacts(uid: String) -> DeviceStreamFacts? {
        guard let objectID = objectID(forUID: uid) else { return nil }
        var rate = 0.0
        withUnsafeMutablePointer(to: &rate) { pointer in
            _ = scalarProperty(
                objectID,
                selector: kAudioDevicePropertyNominalSampleRate,
                scope: kAudioObjectPropertyScopeGlobal,
                pointer: pointer,
                byteSize: UInt32(MemoryLayout<Float64>.size)
            )
        }
        let rates = availableSampleRates(objectID)
        return DeviceStreamFacts(
            uid: uid,
            nominalRate: rate > 0 ? rate : 48_000,
            inputChannels: streamFormatChannels(objectID, scope: kAudioObjectPropertyScopeInput),
            outputChannels: streamFormatChannels(objectID, scope: kAudioObjectPropertyScopeOutput),
            // A single-entry range list means the rate is fixed; an empty list
            // is unknown, so assume programmable and let the set fail visibly.
            settableRate: rates.count != 1
        )
    }

    /// Re-points a device's nominal sample rate before IO starts. Returns
    /// false when the device is gone or rejects the change.
    static func setNominalRate(uid: String, rate: Double) -> Bool {
        guard let objectID = objectID(forUID: uid), rate > 0 else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                objectID, &address, 0, nil,
                UInt32(MemoryLayout<Float64>.size), pointer
            )
        }
        return status == noErr
    }

    private static func streamFormatChannels(
        _ id: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &format) == noErr else { return 0 }
        return format.mChannelsPerFrame
    }

    private static func availableSampleRates(_ id: AudioObjectID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioValueRange>.size
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        var filled = size
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &filled, &ranges) == noErr else { return [] }
        return ranges.map(\.mMinimum)
    }

    // MARK: - CoreAudio property helpers

    private static func stringProperty(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var reportedSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &reportedSize) == noErr,
              reportedSize > 0, reportedSize <= 256
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(reportedSize))
        var fetched = reportedSize
        let status = bytes.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &fetched, buffer.baseAddress!)
        }
        guard status == noErr, fetched > 0 else { return nil }
        let data = bytes.prefix(Int(min(fetched, reportedSize)))

        // CFString-typed properties (device UID, name) come back as the
        // pointer itself, but vendor drivers have been observed returning the
        // manufacturer as a raw C string in the same call — bridging those
        // bytes as a CFString segfaults. Distinguish by shape: a pointer
        // always carries non-printable high bytes on arm64 macOS, while a C
        // string is printable ASCII terminated by NUL.
        let looksLikeCString = data.allSatisfy { $0 == 0 || ($0 >= 0x20 && $0 < 0x7f) }
        if reportedSize == MemoryLayout<CFString>.size, !looksLikeCString {
            // Accumulate little-endian: the first byte is the pointer's low byte.
            var pointer = UInt64(0)
            for byte in data.prefix(MemoryLayout<CFString>.size).reversed() {
                pointer = (pointer << 8) | UInt64(byte)
            }
            guard pointer != 0 else { return nil }
            return unsafeBitCast(UInt(pointer), to: CFString.self) as String
        }

        let cString = data.prefix(while: { $0 != 0 })
        return String(bytes: cString, encoding: .utf8)
            ?? String(bytes: cString, encoding: .macOSRoman)
    }

    private static func scalarProperty(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        pointer: UnsafeMutableRawPointer,
        byteSize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var size = byteSize
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr
    }

    private static func streamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }
}
