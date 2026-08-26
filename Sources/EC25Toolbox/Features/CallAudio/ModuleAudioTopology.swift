import Foundation
import CoreAudio

/// USB identity parsed from a USB Audio Class device UID (R14). Apple's USB
/// audio driver derives `kAudioDevicePropertyDeviceUID` from the IORegistry
/// parent chain, so a UID like
/// `AppleUSBAudioEngine:Foo:Bar:9580:8139:1:2` carries the vendor/product IDs,
/// the USB location (parent anchor), and the interface number. Two endpoints
/// sharing vendor/product/location belong to the same physical module even
/// when the HAL exposes them as separate devices.
struct USBAudioIdentity: Equatable, Hashable, Sendable {
    var vid: UInt32
    var pid: UInt32
    /// USB location ID — same value means the same USB parent instance.
    var location: UInt32?
    /// Interface number from the UID, when present. The audio-control
    /// interface has no streams; streaming interfaces carry the in/out
    /// endpoints. Direction never derives from this number — only from the
    /// device's input/output stream scopes.
    var interface: UInt32?

    /// EC25-compatible and original first-generation DJI modem vendor IDs.
    static let quectelVID: UInt32 = 0x2c7c
    static let djiVID: UInt32 = 0x2ca3

    var isKnownModemVendor: Bool { vid == Self.quectelVID || vid == Self.djiVID }

    /// Parses the numeric tail of an `AppleUSBAudioEngine:` UID. Field order
    /// across macOS releases is vendor, product, then optionally location and
    /// interface; textual segments (manufacturer/product) are skipped, and
    /// decimal or `0x`-prefixed values are both accepted. nil when the UID
    /// carries no parseable identity (aggregates, non-USB, future formats).
    static func parse(uid: String) -> USBAudioIdentity? {
        guard uid.hasPrefix("AppleUSBAudioEngine:") else { return nil }
        let fields = uid.split(separator: ":").dropFirst()
        let numbers = fields.compactMap { field -> UInt32? in
            Self.parseNumber(String(field))
        }
        guard numbers.count >= 2 else { return nil }
        var identity = USBAudioIdentity(vid: numbers[0], pid: numbers[1])
        if numbers.count >= 3 { identity.location = numbers[2] }
        if numbers.count >= 4 { identity.interface = numbers[3] }
        return identity
    }

    private static func parseNumber(_ text: String) -> UInt32? {
        if text.hasPrefix("0x"), let value = UInt32(text.dropFirst(2), radix: 16) {
            return value
        }
        return UInt32(text, radix: 10)
    }

    /// Grouping key: same physical module instance.
    var parentKey: USBAudioParentKey {
        USBAudioParentKey(vid: vid, pid: pid, location: location)
    }
}

/// Identity of one physical USB audio device instance (R14): vendor, product,
/// and location anchor. Interface numbers are deliberately excluded — the
/// module's control and streaming interfaces share a parent.
struct USBAudioParentKey: Equatable, Hashable, Sendable {
    var vid: UInt32
    var pid: UInt32
    var location: UInt32?
}

/// One physical module's audio endpoints (R14): the devices grouped under a
/// common USB parent, split by stream scope.
struct ModuleEndpointGroup: Equatable, Sendable {
    var identity: USBAudioIdentity
    /// Device with input streams — the module capture side feeding downlink.
    var captureDevice: AudioDeviceSummary?
    /// Device with output streams — the module playback side receiving uplink.
    var playbackDevice: AudioDeviceSummary?

    var isComplete: Bool { captureDevice != nil && playbackDevice != nil }
}

/// How the module endpoints were resolved (R14 diagnostics).
enum ModuleTopologyEvidence: Equatable, Sendable {
    /// The user's saved override matched a present device.
    case override
    /// Grouped by shared USB vendor/product/location identity; prefers known
    /// modem vendor IDs, then complete groups.
    case usbParentIdentity
    /// No parseable USB identity anywhere — legacy name/vendor scoring picked
    /// the endpoints (fallback only, never used to decide direction).
    case nameScoreFallback

    var localizationKey: String {
        switch self {
        case .override: "callaudio.topology.override"
        case .usbParentIdentity: "callaudio.topology.usb_parent"
        case .nameScoreFallback: "callaudio.topology.name_fallback"
        }
    }
}

/// Resolves the module's two audio endpoints by USB parent identity (R14).
///
/// Rules, in order:
/// 1. A saved override UID wins when that device exists.
/// 2. USB devices are grouped by (vendor, product, location); the group whose
///    vendor is the known modem vendor (0x2c7c) wins over any other complete
///    group; within the group, direction comes solely from the devices'
///    input/output stream scopes.
/// 3. Without any parseable USB identity, fall back to `ModuleAudioMatcher`
///    name scoring per direction — never as a direction decider.
enum ModuleAudioTopology {
    struct Resolution: Equatable, Sendable {
        var group: ModuleEndpointGroup
        var evidence: ModuleTopologyEvidence
        /// All groups found, for the settings diagnostics list.
        var groups: [ModuleEndpointGroup]
    }

    static func resolve(
        devices: [AudioDeviceSummary],
        overrideUID: String?,
        preferredParent: USBAudioParentKey? = nil
    ) -> Resolution? {
        if let overrideUID, !overrideUID.isEmpty,
           let overridden = devices.first(where: { $0.uid == overrideUID }),
           preferredParent == nil
                || USBAudioIdentity.parse(uid: overridden.uid)?.parentKey == preferredParent {
            let group = ModuleEndpointGroup(
                identity: USBAudioIdentity.parse(uid: overridden.uid)
                    ?? USBAudioIdentity(vid: 0, pid: 0),
                captureDevice: overridden.hasInput ? overridden : nil,
                playbackDevice: overridden.hasOutput ? overridden : nil
            )
            return Resolution(group: group, evidence: .override, groups: [group])
        }

        var groups: [USBAudioParentKey: ModuleEndpointGroup] = [:]
        for device in devices {
            guard device.isUSB,
                  let identity = USBAudioIdentity.parse(uid: device.uid) else { continue }
            var group = groups[identity.parentKey]
                ?? ModuleEndpointGroup(identity: identity)
            if device.hasInput { group.captureDevice = merge(group.captureDevice, device) }
            if device.hasOutput { group.playbackDevice = merge(group.playbackDevice, device) }
            groups[identity.parentKey] = group
        }
        let allGroups = groups.values.sorted {
            $0.identity.isKnownModemVendor && !$1.identity.isKnownModemVendor
        }

        // A known modem vendor beats every other group; otherwise the most
        // complete group wins, then the lowest vendor ID for stability.
        let ranked = allGroups.sorted { lhs, rhs in
            let lhsPreferred = preferredParent.map { lhs.identity.parentKey == $0 } ?? false
            let rhsPreferred = preferredParent.map { rhs.identity.parentKey == $0 } ?? false
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            let lhsModem = lhs.identity.isKnownModemVendor
            let rhsModem = rhs.identity.isKnownModemVendor
            if lhsModem != rhsModem { return lhsModem }
            if lhs.isComplete != rhs.isComplete { return lhs.isComplete }
            if lhs.identity.vid != rhs.identity.vid {
                return lhs.identity.vid < rhs.identity.vid
            }
            return lhs.identity.pid < rhs.identity.pid
        }
        if let best = ranked.first, best.isComplete || best.identity.isKnownModemVendor {
            return Resolution(group: best, evidence: .usbParentIdentity, groups: allGroups)
        }

        // No USB identity to group by — legacy name scoring, direction-safe
        // because each side still requires matching stream scopes.
        guard
            let capture = ModuleAudioMatcher.bestMatch(in: devices, overrideUID: nil, direction: .input),
            let playback = ModuleAudioMatcher.bestMatch(in: devices, overrideUID: nil, direction: .output)
        else { return nil }
        let group = ModuleEndpointGroup(
            identity: USBAudioIdentity(vid: 0, pid: 0),
            captureDevice: capture,
            playbackDevice: playback
        )
        return Resolution(group: group, evidence: .nameScoreFallback, groups: [group])
    }

    /// When both sides resolve to the same group member set, keeps a stable
    /// representative (lowest UID).
    private static func merge(
        _ current: AudioDeviceSummary?,
        _ candidate: AudioDeviceSummary
    ) -> AudioDeviceSummary {
        guard let current else { return candidate }
        return current.uid < candidate.uid ? current : candidate
    }
}
