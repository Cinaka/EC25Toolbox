@testable import EC25Toolbox
import CryptoKit
import XCTest

final class ModuleVoiceRuntimeTests: XCTestCase {
    func testPinnedManifestHasCompleteAuditableArtifactSet() {
        XCTAssertEqual(
            ModuleVoiceRuntimeManifest.commit,
            "0443dfdaf8aec086fd76ba2ee9152fd908114524"
        )
        XCTAssertEqual(ModuleVoiceRuntimeManifest.kernelRelease, "3.18.44")
        XCTAssertEqual(ModuleVoiceRuntimeManifest.artifacts.count, 6)
        XCTAssertEqual(
            ModuleVoiceRuntimeManifest.deployedArtifacts.map(\.name),
            ["qdc507_aprv3.ko", "qdc507_voice.ko", "mavo-pcm-bridge.armv7"]
        )
        XCTAssertTrue(ModuleVoiceRuntimeManifest.artifacts.allSatisfy {
            $0.byteCount > 0 && $0.sha256.count == 64
                && $0.sha256.allSatisfy { $0.isHexDigit }
        })
    }

    func testRuntimeVerifierRejectsWrongSizeAndChecksum() throws {
        let payload = Data("voice-runtime-test".utf8)
        let correctHash = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
        let valid = ModuleVoiceRuntimeManifest.Artifact(
            name: "test.bin",
            byteCount: payload.count,
            sha256: correctHash,
            permissions: 0o644,
            deployToModule: false
        )
        XCTAssertNoThrow(try ModuleVoiceRuntimeStore.verify(data: payload, artifact: valid))

        var wrongSize = valid
        wrongSize.byteCount += 1
        XCTAssertThrowsError(try ModuleVoiceRuntimeStore.verify(data: payload, artifact: wrongSize))

        var wrongHash = valid
        wrongHash.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try ModuleVoiceRuntimeStore.verify(data: payload, artifact: wrongHash))
    }

    func testRuntimeStoreRejectsSymlinkedVersionDirectory() async throws {
        let temporary = FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent("modulevoice-root-\(UUID().uuidString)")
        let external = temporary.appendingPathComponent("modulevoice-external-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let version = root.appendingPathComponent(ModuleVoiceRuntimeManifest.version)
        try FileManager.default.createSymbolicLink(
            at: version,
            withDestinationURL: external
        )
        let store = ModuleVoiceRuntimeStore(rootDirectory: root)

        do {
            _ = try await store.installedDirectory()
            XCTFail("symlinked runtime directories must fail closed")
        } catch let error as ModuleVoiceRuntimeError {
            guard case .unsafeArtifact = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLegacyQADBKeyAcceptsOnlyOneEightDigitChallenge() throws {
        XCTAssertEqual(
            QDC507ADBKey.parseChallenge(["+QADBKEY: 15478726"]),
            "15478726"
        )
        XCTAssertNil(QDC507ADBKey.parseChallenge(["+QADBKEY: 1234"] ))
        XCTAssertNil(QDC507ADBKey.parseChallenge([
            "+QADBKEY: 12345678",
            "+QADBKEY: 87654321",
        ]))
        XCTAssertEqual(
            try QDC507ADBKey.deriveResponse(challenge: "15478726"),
            "n9Qq0s1x4LtgAvt"
        )
    }
}
