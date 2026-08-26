import Darwin
import Foundation

/// Reads per-interface byte counters from the kernel via `sysctl(NET_RT_IFLIST2)`.
/// USB NICs frequently leave the `getifaddrs` statistics at zero, so the system
/// route-table walk is the reliable source.
enum TrafficCounterReader {
    static func counters(bsdName: String) -> (bytesIn: UInt64, bytesOut: UInt64)? {
        guard !bsdName.isEmpty else { return nil }
        var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, AF_UNSPEC, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        var offset = 0
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        while offset + MemoryLayout<if_msghdr2>.size <= size {
            let header = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            }
            defer { offset += Int(header.ifm_msglen) }
            guard header.ifm_type == UInt8(RTM_IFINFO2), header.ifm_msglen > 0 else { continue }
            guard if_indextoname(UInt32(header.ifm_index), &nameBuffer) != nil else { continue }
            let interfaceName = String(
                decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard interfaceName == bsdName else { continue }
            let data = header.ifm_data
            return (data.ifi_ibytes, data.ifi_obytes)
        }
        return nil
    }
}

/// Best-effort archive of finished traffic sessions. One JSON file, capped,
/// atomic writes; failures are silently ignored — traffic history is
/// non-critical.
struct TrafficArchiveStore {
    let fileURL: URL
    private let maxRecords = 60

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func lastSession() -> TrafficSessionRecord? {
        records().last
    }

    func records() -> [TrafficSessionRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TrafficSessionRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    func record(_ record: TrafficSessionRecord) {
        var all = records().filter { $0.id != record.id }
        all.append(record)
        if all.count > maxRecords {
            all = Array(all.suffix(maxRecords))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
