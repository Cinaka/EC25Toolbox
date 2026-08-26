import CryptoKit
import Foundation

/// Immutable identity of the optional QDC507 module-side voice runtime.
///
/// The artifacts are never bundled with EC25 Toolbox. After explicit user
/// consent they are downloaded from this exact MaVo commit, verified, and
/// cached under Application Support before being copied to the modem's tmpfs.
enum ModuleVoiceRuntimeManifest {
    static let upstreamRepository = URL(string: "https://github.com/moluncn/mavo")!
    static let commit = "0443dfdaf8aec086fd76ba2ee9152fd908114524"
    static let version = "qdc507-3.18.44-voice-20260712.5"
    static let kernelRelease = "3.18.44"
    static let baseURL = URL(
        string: "https://raw.githubusercontent.com/moluncn/mavo/\(commit)/Resources/ModuleVoice/"
    )!

    struct Artifact: Equatable, Sendable {
        var name: String
        var byteCount: Int
        var sha256: String
        var permissions: Int
        var deployToModule: Bool
    }

    static let artifacts: [Artifact] = [
        Artifact(
            name: "qdc507_aprv3.ko",
            byteCount: 36_664,
            sha256: "3d82d3dec4f1e323201bba87156df9d41438e08314097353f2607f9117211d4a",
            permissions: 0o644,
            deployToModule: true
        ),
        Artifact(
            name: "qdc507_voice.ko",
            byteCount: 999_236,
            sha256: "ed3821682d5309969a01c764192c83feff9669c61ef237c69475cd1619cf296c",
            permissions: 0o644,
            deployToModule: true
        ),
        Artifact(
            name: "mavo-pcm-bridge.armv7",
            byteCount: 17_860,
            sha256: "88d47c15e61d1428a59c821fed804c2e6490e82859a085062f21966b58d167fc",
            permissions: 0o755,
            deployToModule: true
        ),
        Artifact(
            name: "manifest.json",
            byteCount: 729,
            sha256: "f4f6c266ced7015d4e61d993a6e31247c26a9e85a8fdf1c6d842c459e1e2970a",
            permissions: 0o644,
            deployToModule: false
        ),
        Artifact(
            name: "COPYING-GPL-2.0",
            byteCount: 18_693,
            sha256: "af8067302947c01fd9eee72befa54c7e3ef8a48fecde7fd71277f2290b2bf0f7",
            permissions: 0o644,
            deployToModule: false
        ),
        Artifact(
            name: "MODULE-REPORT.md",
            byteCount: 7_443,
            sha256: "fb9d58336bcfdad8938d7833c113a815c2153d9a04564eb73cddabea737f8be2",
            permissions: 0o644,
            deployToModule: false
        ),
    ]

    static var deployedArtifacts: [Artifact] {
        artifacts.filter(\.deployToModule)
    }
}

enum ModuleVoiceRuntimePhase: String, Equatable, Sendable {
    case unavailable
    case downloading
    case ready
    case preparing
    case prepared
    case routing
    case active
    case stopping
    case failed
}

struct ModuleVoiceRuntimeStatus: Equatable, Sendable {
    var phase: ModuleVoiceRuntimePhase = .unavailable
    /// Kept independently from `phase` so a deployment or routing failure
    /// does not make a verified local cache look absent in Settings.
    var localCacheAvailable = false
    var detail: String?
    var currentArtifact: String?
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = Int64(ModuleVoiceRuntimeManifest.artifacts.reduce(0) { $0 + $1.byteCount })

    var isInstalled: Bool {
        if localCacheAvailable { return true }
        return switch phase {
        case .ready, .preparing, .prepared, .routing, .active, .stopping:
            true
        case .unavailable, .downloading, .failed:
            false
        }
    }
}

enum ModuleVoiceRuntimeError: LocalizedError, Equatable {
    case invalidHTTPSResponse(String)
    case unexpectedSize(name: String, expected: Int, actual: Int)
    case checksumMismatch(String)
    case missingArtifact(String)
    case unsafeArtifact(String)
    case notInstalled
    case directModuleRequired
    case unsupportedKernel(expected: String, actual: String)
    case rootRequired
    case adbAuthorizationRequired
    case adbUnavailable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidHTTPSResponse(detail):
            localizedFormat("modulevoice.error.download_response", detail)
        case let .unexpectedSize(name, expected, actual):
            localizedFormat("modulevoice.error.size", name, expected, actual)
        case let .checksumMismatch(name):
            localizedFormat("modulevoice.error.checksum", name)
        case let .missingArtifact(name):
            localizedFormat("modulevoice.error.missing", name)
        case let .unsafeArtifact(name):
            localizedFormat("modulevoice.error.unsafe_file", name)
        case .notInstalled:
            localized("modulevoice.error.not_installed")
        case .directModuleRequired:
            localized("modulevoice.error.direct_only")
        case let .unsupportedKernel(expected, actual):
            localizedFormat("modulevoice.error.kernel", expected, actual)
        case .rootRequired:
            localized("modulevoice.error.root_required")
        case .adbAuthorizationRequired:
            localized("modulevoice.error.adb_auth")
        case let .adbUnavailable(detail):
            localizedFormat("modulevoice.error.adb_unavailable", detail)
        case let .commandFailed(detail):
            detail
        }
    }
}

/// Downloads and verifies the optional runtime without ever placing it in the
/// source tree or application bundle. All public operations are actor-isolated
/// so two module sessions cannot race while replacing the shared cache.
actor ModuleVoiceRuntimeStore {
    typealias Progress = @Sendable (_ artifact: String, _ completed: Int64, _ total: Int64) async -> Void

    static let shared = ModuleVoiceRuntimeStore()

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let session: URLSession

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        session: URLSession? = nil
    ) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.rootDirectory = AppIdentity.applicationSupportDirectory(base: base, fileManager: fileManager)
                .appendingPathComponent("VoiceRuntime", isDirectory: true)
        }
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 180
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    var runtimeDirectory: URL {
        rootDirectory.appendingPathComponent(ModuleVoiceRuntimeManifest.version, isDirectory: true)
    }

    func installedDirectory() throws -> URL {
        try verify(directory: runtimeDirectory)
        return runtimeDirectory
    }

    func isInstalled() -> Bool {
        (try? installedDirectory()) != nil
    }

    func download(progress: Progress? = nil) async throws -> URL {
        if let existing = try? installedDirectory() {
            return existing
        }
        try createRuntimeDirectory()

        var completed: Int64 = 0
        let total = Int64(ModuleVoiceRuntimeManifest.artifacts.reduce(0) { $0 + $1.byteCount })
        for artifact in ModuleVoiceRuntimeManifest.artifacts {
            await progress?(artifact.name, completed, total)
            let source = ModuleVoiceRuntimeManifest.baseURL.appendingPathComponent(artifact.name)
            let (temporaryURL, response) = try await session.download(from: source)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  response.url?.scheme?.lowercased() == "https" else {
                throw ModuleVoiceRuntimeError.invalidHTTPSResponse(
                    (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "non-HTTP response"
                )
            }

            let data = try Data(contentsOf: temporaryURL, options: [.mappedIfSafe])
            try Self.verify(data: data, artifact: artifact)
            let destination = runtimeDirectory.appendingPathComponent(artifact.name, isDirectory: false)
            try data.write(to: destination, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: artifact.permissions],
                ofItemAtPath: destination.path
            )
            completed += Int64(artifact.byteCount)
            await progress?(artifact.name, completed, total)
        }

        try verify(directory: runtimeDirectory)
        return runtimeDirectory
    }

    func removeInstalledRuntime() throws {
        let target = runtimeDirectory.standardizedFileURL
        let root = rootDirectory.standardizedFileURL
        guard target.deletingLastPathComponent() == root else {
            throw ModuleVoiceRuntimeError.unsafeArtifact(target.path)
        }
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    private func verify(directory: URL) throws {
        let directoryValues: URLResourceValues
        do {
            directoryValues = try directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw ModuleVoiceRuntimeError.missingArtifact(directory.lastPathComponent)
        }
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw ModuleVoiceRuntimeError.unsafeArtifact(directory.path)
        }
        for artifact in ModuleVoiceRuntimeManifest.artifacts {
            let url = directory.appendingPathComponent(artifact.name, isDirectory: false)
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
            } catch {
                throw ModuleVoiceRuntimeError.missingArtifact(artifact.name)
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ModuleVoiceRuntimeError.unsafeArtifact(artifact.name)
            }
            guard values.fileSize == artifact.byteCount else {
                throw ModuleVoiceRuntimeError.unexpectedSize(
                    name: artifact.name,
                    expected: artifact.byteCount,
                    actual: values.fileSize ?? -1
                )
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            try Self.verify(data: data, artifact: artifact)
        }
    }

    private func createRuntimeDirectory() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let rootValues = try rootDirectory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ModuleVoiceRuntimeError.unsafeArtifact(rootDirectory.path)
        }

        if fileManager.fileExists(atPath: runtimeDirectory.path) {
            let values = try runtimeDirectory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ModuleVoiceRuntimeError.unsafeArtifact(runtimeDirectory.path)
            }
        } else {
            try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: false)
        }
    }

    static func verify(data: Data, artifact: ModuleVoiceRuntimeManifest.Artifact) throws {
        guard data.count == artifact.byteCount else {
            throw ModuleVoiceRuntimeError.unexpectedSize(
                name: artifact.name,
                expected: artifact.byteCount,
                actual: data.count
            )
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
            throw ModuleVoiceRuntimeError.checksumMismatch(artifact.name)
        }
    }
}
