import Foundation

enum RingtoneError: LocalizedError, Equatable {
    case unsupportedType
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType: localized("callaudio.ringtone.error.unsupported")
        case .importFailed: localized("callaudio.ringtone.error.import_failed")
        }
    }
}

/// Stores user-imported ringtone audio files under Application
/// Support/Ringtones. Import copies the picked file (the fileImporter grant
/// is transient); listing, deletion, and URL resolution are filename-based
/// and the selected ringtone persists as a settings string.
final class RingtoneStore {
    /// Extensions `AVAudioPlayer` reads on macOS.
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "caf", "aiff", "aif", "flac",
    ]

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
            .appendingPathComponent("Ringtones", isDirectory: true)
    }

    var directory: URL { baseDirectory }

    /// Imports one audio file, returning the stored filename.
    @discardableResult
    func importFile(at sourceURL: URL, securityScoped: Bool = true) throws -> String {
        let ext = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw RingtoneError.unsupportedType
        }
        if securityScoped {
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }
            return try copyRingtone(at: sourceURL, fileExtension: ext)
        }
        return try copyRingtone(at: sourceURL, fileExtension: ext)
    }

    private func copyRingtone(at sourceURL: URL, fileExtension ext: String) throws -> String {
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let baseName = sanitizedBaseName(sourceURL)
            var candidate = "\(baseName).\(ext)"
            var counter = 1
            while fileManager.fileExists(atPath: baseDirectory.appendingPathComponent(candidate).path) {
                counter += 1
                candidate = "\(baseName)-\(counter).\(ext)"
            }
            let destination = baseDirectory.appendingPathComponent(candidate)
            try fileManager.copyItem(at: sourceURL, to: destination)
            return candidate
        } catch {
            throw RingtoneError.importFailed(error.localizedDescription)
        }
    }

    /// Stored ringtone filenames, sorted for stable pickers.
    func list() -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent)
            .sorted()
    }

    func url(for fileName: String?) -> URL? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let candidate = baseDirectory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Deletes one stored ringtone; returns the remaining list.
    @discardableResult
    func delete(_ fileName: String) -> [String] {
        try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(fileName))
        return list()
    }

    private func sanitizedBaseName(_ sourceURL: URL) -> String {
        let raw = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let allowed = raw.unicodeScalars.filter { scalar in
            scalar.isASCII && scalar.value > 31 && scalar != "/"
        }
        let name = String(String.UnicodeScalarView(allowed))
        return name.isEmpty ? "ringtone" : String(name.prefix(60))
    }
}
