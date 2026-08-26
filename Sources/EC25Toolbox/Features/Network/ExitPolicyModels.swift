import Foundation

/// Automation strategy for the module's dedicated network service. Every mode
/// only ever toggles the app-managed module service — the user's other network
/// services are never modified.
enum ExitPolicy: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    /// No automation: the user enables/disables the module service by hand.
    case manual
    /// Keeps the module service enabled — 4G is always allowed as an exit.
    case allow4G
    /// Parks the module service while a non-module default path (Wi-Fi or
    /// Ethernet) carries traffic, and re-enables it as the fallback exit when
    /// that path goes away.
    case wifiPreferred

    var id: String { rawValue }

    var localizationKey: String { "network.policy.\(rawValue)" }
}

/// Status of one observed network path.
enum ExitPathStatus: String, Equatable, Sendable {
    case satisfied
    case unsatisfied
    case unknown

    var localizationKey: String { "network.exit.status.\(rawValue)" }
}

/// Interface class of the observed exit path.
enum ExitInterfaceKind: String, Equatable, Sendable {
    case wifi
    case wiredEthernet
    case cellular
    case other
    case none

    var localizationKey: String { "network.exit.kind.\(rawValue)" }

    static func fromNWInterfaceType(_ type: String) -> ExitInterfaceKind {
        switch type {
        case "wifi": .wifi
        case "wiredEthernet": .wiredEthernet
        case "cellular": .cellular
        default: .other
        }
    }
}

/// The default-path facts reduced to plain values the UI and the policy
/// decision can consume.
struct ExitPathSnapshot: Equatable, Sendable {
    var status: ExitPathStatus = .unknown
    var interfaceBSD: String?
    var interfaceKind: ExitInterfaceKind = .none

    var displayInterface: String { interfaceBSD?.isEmpty == false ? interfaceBSD! : "-" }
}

/// Link-layer facts for one interface, read via `getifaddrs`.
struct InterfaceLinkSnapshot: Equatable, Sendable {
    var bsdName = ""
    var isUp = false
    var isRunning = false
    var ipv4Addresses: [String] = []
    var ipv6Addresses: [String] = []

    /// Link-local-only IPv6 is not a usable exit; require IPv4 or global IPv6.
    var hasUsableAddress: Bool {
        !ipv4Addresses.isEmpty || ipv6Addresses.contains { !$0.hasPrefix("fe80") }
    }

    var isReady: Bool { isUp && isRunning && hasUsableAddress }

    var displayAddresses: String {
        var parts = ipv4Addresses + ipv6Addresses
        if parts.count > 3 { parts = Array(parts.prefix(3)) + ["…"] }
        return parts.isEmpty ? "-" : parts.joined(separator: ", ")
    }
}

/// System-wide HTTP/SOCKS proxy settings, read-only.
struct SystemProxySnapshot: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case none
        case http
        case socks
    }

    var mode: Mode = .none
    var host = ""
    var port: Int = 0

    var displayEndpoint: String {
        guard mode != .none, !host.isEmpty else { return "-" }
        return port > 0 ? "\(host):\(port)" : host
    }

    /// Maps the `CFNetworkCopySystemProxySettings` dictionary into a value.
    /// Kept as a plain function so the key handling is unit-testable.
    static func fromDictionary(_ dictionary: [String: Any]?) -> SystemProxySnapshot {
        guard let dictionary else { return SystemProxySnapshot() }
        func intValue(_ key: String) -> Int? {
            (dictionary[key] as? NSNumber)?.intValue ?? dictionary[key] as? Int
        }
        func stringValue(_ key: String) -> String? {
            dictionary[key] as? String
        }
        if let host = stringValue("HTTPProxy") ?? stringValue("HTTPSProxy"),
           !host.isEmpty,
           (intValue("HTTPEnable") ?? 0) == 1 || (intValue("HTTPSEnable") ?? 0) == 1 {
            return SystemProxySnapshot(
                mode: .http,
                host: host,
                port: intValue("HTTPPort") ?? intValue("HTTPSPort") ?? 0
            )
        }
        if let host = stringValue("SOCKSProxy"), !host.isEmpty, (intValue("SOCKSEnable") ?? 0) == 1 {
            return SystemProxySnapshot(
                mode: .socks,
                host: host,
                port: intValue("SOCKSPort") ?? 0
            )
        }
        return SystemProxySnapshot()
    }
}

/// Pure policy decision: should the app-managed module service be enabled
/// right now? `nil` means no opinion — leave the service as the user set it.
enum ExitPolicyDecision {
    static func moduleServiceShouldBeEnabled(
        policy: ExitPolicy,
        moduleBSD: String?,
        defaultPath: ExitPathSnapshot
    ) -> Bool? {
        switch policy {
        case .manual:
            return nil
        case .allow4G:
            return true
        case .wifiPreferred:
            guard let moduleBSD, !moduleBSD.isEmpty else { return nil }
            // No usable default path: bring the module up as the fallback.
            guard defaultPath.status == .satisfied,
                  let exit = defaultPath.interfaceBSD, !exit.isEmpty else { return true }
            // The default path rides another interface: keep the module parked
            // until that path disappears.
            return exit == moduleBSD
        }
    }
}
