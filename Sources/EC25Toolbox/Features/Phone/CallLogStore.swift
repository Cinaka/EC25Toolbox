import Foundation

/// Persists the call history per SIM identity so switching cards or eUICC
/// profiles never mixes records, mirroring the SMS archive's EID/ICCID
/// isolation. Writes are best-effort: persistence failures never disturb the
/// in-memory call log or modem operation.
final class CallLogStore {
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
            .appendingPathComponent("Calls", isDirectory: true)
    }

    /// File URL backing the given SIM identity's call history. Internal so
    /// tests can corrupt the exact file the store reads.
    func url(for scope: SIMMessageScope) -> URL {
        baseDirectory.appendingPathComponent("\(scope.id).json")
    }

    /// Loads the call history recorded for the given SIM identity.
    func load(scope: SIMMessageScope) -> [CallEvent] {
        let fileURL = url(for: scope)
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([CallEvent].self, from: data)) ?? []
    }

    /// Atomically replaces the stored history for the given SIM identity.
    func replace(_ events: [CallEvent], scope: SIMMessageScope) {
        do {
            if events.isEmpty {
                try? fileManager.removeItem(at: url(for: scope))
                return
            }
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(events)
            try data.write(to: url(for: scope), options: .atomic)
        } catch {
            // Call-history persistence is best-effort.
        }
    }
}
