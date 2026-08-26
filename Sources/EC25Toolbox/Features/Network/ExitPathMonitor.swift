import CFNetwork
import Darwin
import Foundation
import Network

/// Observes the system default path with `NWPathMonitor` and reduces every
/// update to plain-value snapshots. Interface link facts and proxy settings
/// are sampled separately because `NWPath` exposes neither addresses nor
/// system proxies.
final class ExitPathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ing.fuyaoskyrocket.ec25toolbox.exitpath")
    private let lock = NSLock()
    private var handler: (@Sendable (ExitPathSnapshot) -> Void)?
    private var started = false

    /// Starts observing. The handler runs on the monitor's private queue.
    func start(_ handler: @escaping @Sendable (ExitPathSnapshot) -> Void) {
        lock.lock()
        self.handler = handler
        let shouldStart = !started
        started = true
        lock.unlock()

        guard shouldStart else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let snapshot = Self.snapshot(for: path)
            self.lock.lock()
            let handler = self.handler
            self.lock.unlock()
            handler?(snapshot)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        lock.lock()
        handler = nil
        lock.unlock()
        monitor.cancel()
    }

    /// The exit interface is the first non-loopback interface of the path;
    /// kind comes from its `NWInterface.InterfaceType`.
    static func snapshot(for path: NWPath) -> ExitPathSnapshot {
        var snapshot = ExitPathSnapshot()
        switch path.status {
        case .satisfied: snapshot.status = .satisfied
        case .unsatisfied: snapshot.status = .unsatisfied
        case .requiresConnection: snapshot.status = .unknown
        @unknown default: snapshot.status = .unknown
        }
        let interfaces = path.availableInterfaces
        guard let exit = interfaces.first(where: { $0.type != .loopback }) else { return snapshot }
        snapshot.interfaceBSD = exit.name
        snapshot.interfaceKind = ExitInterfaceKind.fromNWInterfaceType(
            typeString(exit.type)
        )
        return snapshot
    }

    private static func typeString(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: "wifi"
        case .wiredEthernet: "wiredEthernet"
        case .cellular: "cellular"
        default: "other"
        }
    }
}

/// One-shot system reads shared by the store refresh and diagnostics.
enum InterfaceFacts {
    /// Link-layer facts for one BSD interface via `getifaddrs`.
    static func linkSnapshot(bsdName: String) -> InterfaceLinkSnapshot {
        guard !bsdName.isEmpty else { return InterfaceLinkSnapshot(bsdName: "") }
        var snapshot = InterfaceLinkSnapshot(bsdName: bsdName)
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else {
            return snapshot
        }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let name = entry.pointee.ifa_name,
                  String(cString: name) == bsdName,
                  let sockaddrPtr = entry.pointee.ifa_addr else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            snapshot.isUp = snapshot.isUp || (flags & IFF_UP) == IFF_UP
            snapshot.isRunning = snapshot.isRunning || (flags & IFF_RUNNING) == IFF_RUNNING
            switch Int32(sockaddrPtr.pointee.sa_family) {
            case AF_INET:
                var address = sockaddr_in()
                memcpy(&address, sockaddrPtr, MemoryLayout<sockaddr_in>.size)
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var inAddress = address.sin_addr
                inet_ntop(AF_INET, &inAddress, &buffer, socklen_t(INET_ADDRSTRLEN))
                snapshot.ipv4Addresses.append(
                    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                )
            case AF_INET6:
                var address = sockaddr_in6()
                memcpy(&address, sockaddrPtr, MemoryLayout<sockaddr_in6>.size)
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var inAddress = address.sin6_addr
                inet_ntop(AF_INET6, &inAddress, &buffer, socklen_t(INET6_ADDRSTRLEN))
                snapshot.ipv6Addresses.append(
                    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                )
            default:
                continue
            }
        }
        snapshot.ipv4Addresses = snapshot.ipv4Addresses.uniqued()
        snapshot.ipv6Addresses = snapshot.ipv6Addresses.uniqued()
        return snapshot
    }

    /// System-wide proxy settings (read-only).
    static func systemProxy() -> SystemProxySnapshot {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return SystemProxySnapshot()
        }
        return SystemProxySnapshot.fromDictionary(settings)
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
