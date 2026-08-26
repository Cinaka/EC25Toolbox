import Foundation

/// Device capabilities recorded from read-only AT probes. A non-success
/// value means the probe failed or is unsupported by the current firmware;
/// it never means the feature was verified working on live hardware.
struct ModemCapabilities: Equatable, Sendable {
    /// `AT+QGPS=?` outcome — unknown until probed; only a definitive
    /// firmware rejection downgrades to `.unsupported`.
    var gnss = GNSSCapability.unknown
    /// `AT+QPCMV=?` succeeded — the USB PCM voice path is present.
    var usbVoice = false
    /// `AT+QCFG="usbcfg"` returned the current USB composition, enabling the
    /// module-initialization flows of P5.
    var usbConfiguration = false
    /// `AT+VTS=?` succeeded — in-call DTMF is available.
    var dtmf = false
    /// `AT+CPBS=?` listed phonebook storages.
    var phonebook = false
    /// An eUICC was detected through the eSTK APDU pipeline. Not probed here;
    /// the eSTK detection fills this in once the session is up.
    var euicc = false
    /// PDU-mode (`AT+CMGF=0`) SMS listing succeeded. Latched by the message
    /// refresh path, not by a prober round-trip.
    var pduSMS = false
}

/// Runs the read-only capability probes through the store's command pipeline
/// and records what the current firmware reports. Probes are independent: one
/// unsupported command never blocks the rest.
@MainActor
enum ModemCapabilityProber {
    static func probe(_ transact: (String) async throws -> [String]) async -> ModemCapabilities {
        var capabilities = ModemCapabilities()

        capabilities.gnss = await probeGNSS(transact)
        if (try? await transact("AT+QPCMV=?")) != nil {
            capabilities.usbVoice = true
        }
        if let lines = try? await transact("AT+QCFG=\"usbcfg\""),
           lines.contains(where: { $0.hasPrefix("+QCFG: \"usbcfg\"") }) {
            capabilities.usbConfiguration = true
        }
        if (try? await transact("AT+VTS=?")) != nil {
            capabilities.dtmf = true
        }
        if let lines = try? await transact("AT+CPBS=?"),
           lines.contains(where: { $0.hasPrefix("+CPBS:") }) {
            capabilities.phonebook = true
        }

        return capabilities
    }

    /// Probes only the GNSS capability, used for the in-page retry button.
    /// A transport failure stays `.error` so the tab never hides on a flaky
    /// round-trip.
    static func probeGNSS(_ transact: (String) async throws -> [String]) async -> GNSSCapability {
        do {
            _ = try await transact("AT+QGPS=?")
            return .supported
        } catch {
            return GNSSCapability.classify(.failure(error))
        }
    }
}
