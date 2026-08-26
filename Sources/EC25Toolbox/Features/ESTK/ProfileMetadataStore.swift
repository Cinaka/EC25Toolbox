import Foundation

/// User-attached profile information (label, phone, tags), keyed by the
/// eUICC's EID and the profile's ICCID so switching cards or profiles never
/// mixes records — the same isolation the SMS archive and call log use.
/// Lives only on this Mac; nothing here is ever written to the card.
struct ProfileMetadata: Codable, Equatable, Identifiable {
    var eid: String
    var iccid: String
    var label: String
    var phone: String
    var tags: [String]
    var updatedAt: Date

    var id: String { "\(eid)|\(iccid)" }

    /// A record with no content is treated as absent by the store.
    var isEmpty: Bool {
        trimmed(label).isEmpty && trimmed(phone).isEmpty && tags.allSatisfy { trimmed($0).isEmpty }
    }

    /// Tags normalized for storage and display: trimmed, empties dropped,
    /// duplicates removed while preserving order.
    var normalizedTags: [String] {
        var seen: Set<String> = []
        return tags.compactMap { tag in
            let clean = trimmed(tag)
            guard !clean.isEmpty, seen.insert(clean).inserted else { return nil }
            return clean
        }
    }
}

/// Persists `ProfileMetadata` with one JSON file per EID. Writes are
/// best-effort: persistence failures never disturb the eSTK flow.
final class ProfileMetadataStore {
    private let fileManager: FileManager
    private let baseDirectory: URL

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let applicationSupport = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        baseDirectory = AppIdentity.applicationSupportDirectory(
            base: applicationSupport,
            fileManager: fileManager
        )
            .appendingPathComponent("ProfileMetadata", isDirectory: true)
    }

    /// File URL backing the given card's metadata. Internal so tests can
    /// corrupt the exact file the store reads.
    func url(forEID eid: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.fileName(eid)).json")
    }

    /// All metadata recorded for the given card.
    func records(eid: String) -> [ProfileMetadata] {
        guard let data = try? Data(contentsOf: url(forEID: eid)) else { return [] }
        return (try? Self.makeDecoder().decode([ProfileMetadata].self, from: data)) ?? []
    }

    func metadata(eid: String, iccid: String) -> ProfileMetadata? {
        records(eid: eid).first { $0.iccid == iccid }
    }

    /// Inserts or updates the record for its ICCID. Saving an emptied
    /// record removes it — an empty metadata entry is meaningless.
    func upsert(_ record: ProfileMetadata) {
        var all = records(eid: record.eid).filter { $0.iccid != record.iccid }
        var normalized = record
        normalized.tags = record.normalizedTags
        if !normalized.isEmpty {
            all.append(normalized)
        }
        replace(all, eid: record.eid)
    }

    func remove(eid: String, iccid: String) {
        replace(records(eid: eid).filter { $0.iccid != iccid }, eid: eid)
    }

    /// Drops records whose ICCID is no longer present in the card's current
    /// profile list (the profile was deleted, or wiped and re-downloaded
    /// with a new ICCID). Returns the surviving records.
    @discardableResult
    func prune(eid: String, keepingICCIDs: [String]) -> [ProfileMetadata] {
        let kept = records(eid: eid).filter { keepingICCIDs.contains($0.iccid) }
        replace(kept, eid: eid)
        return kept
    }

    // MARK: - Internals

    private func replace(_ records: [ProfileMetadata], eid: String) {
        do {
            if records.isEmpty {
                try? fileManager.removeItem(at: url(forEID: eid))
                return
            }
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try Self.makeEncoder().encode(records).write(to: url(forEID: eid), options: .atomic)
        } catch {
            // Metadata persistence is best-effort.
        }
    }

    /// EIDs are digits in practice; stay defensive about path separators.
    private static func fileName(_ eid: String) -> String {
        String(eid.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
