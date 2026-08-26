import XCTest
@testable import EC25Toolbox

final class ESTKTests: XCTestCase {
    private struct RetryFailure: Error {}

    func testESTKEntryAlwaysAvailableRegardlessOfProbeOutcome() {
        // R10: the eSTK tab is never hidden — every availability verdict,
        // including a confirmed non-eUICC SIM, is explained inside the page.
        for availability in [ESTKAvailability.unknown, .checking, .available, .unavailable] {
            XCTAssertTrue(PanelTab.allCases.contains(.estk))
            _ = availability
        }
    }

    func testLogicalChannelParsing() throws {
        XCTAssertEqual(try parseESTKCCHOChannel(["+CCHO: 1"]), 1)
        XCTAssertEqual(try parseESTKCCHOChannel(["2"]), 2)
        XCTAssertThrowsError(try parseESTKCCHOChannel(["OK"]))
    }

    func testLogicalChannelExtractionFromAPDU() throws {
        XCTAssertEqual(try estkLogicalChannel(fromAPDU: "01A4040000"), 1)
        XCTAssertEqual(try estkLogicalChannel(fromAPDU: "42A4040000"), 6)
    }

    func testLengthPrefixedAPDUResponseParsing() throws {
        XCTAssertEqual(try parseESTKAPDUResponse(["+CGLA: 8,\"A1B29000\""], prefix: "+CGLA:"), "A1B29000")
        XCTAssertThrowsError(try parseESTKAPDUResponse(["+CSIM: 2,\"9000\""], prefix: "+CSIM:"))
    }

    func testActivationCodeNormalization() throws {
        XCTAssertEqual(
            try normalizedESTKActivationCode("LPA:1$rsp.example.com$matching-id"),
            "LPA:1$rsp.example.com$matching-id"
        )
        XCTAssertEqual(
            try normalizedESTKActivationCode("1$rsp.example.com$matching-id"),
            "LPA:1$rsp.example.com$matching-id"
        )
        XCTAssertEqual(
            try normalizedESTKActivationCode("$rsp.example.com$matching-id"),
            "LPA:1$rsp.example.com$matching-id"
        )
    }

    func testInvalidActivationCodeIsRejected() {
        XCTAssertThrowsError(try normalizedESTKActivationCode("rsp.example.com$matching-id"))
        XCTAssertThrowsError(try normalizedESTKActivationCode("LPA:1$$matching-id"))
    }

    func testManualDownloadArgumentsMatchLPACCLI() throws {
        let request = ESTKDownloadRequest(
            activationCode: "",
            smdpAddress: "rsp.example.com",
            matchingID: "matching-id",
            confirmationCode: "123456"
        )
        XCTAssertEqual(
            try validatedESTKDownloadArguments(request, imei: "123456789012345"),
            [
                "profile", "download",
                "-s", "rsp.example.com",
                "-m", "matching-id",
                "-c", "123456",
                "-i", "123456789012345"
            ]
        )
    }

    func testManualDownloadRejectsInvalidMatchingID() {
        let request = ESTKDownloadRequest(
            activationCode: "",
            smdpAddress: "rsp.example.com",
            matchingID: "contains spaces",
            confirmationCode: ""
        )
        XCTAssertThrowsError(try validatedESTKDownloadArguments(request, imei: nil))
    }

    func testLPACProfileListDecoding() throws {
        let json = #"""
        [
          {
            "iccid": "8901000000000000001",
            "isdpAid": "A0000005591010FFFFFFFF8900001000",
            "profileState": "enabled",
            "profileNickname": "Travel",
            "serviceProviderName": "Example Mobile",
            "profileName": "Example eSIM",
            "profileClass": "operational",
            "iconType": "none",
            "icon": null
          }
        ]
        """#

        let profiles = try JSONDecoder().decode([ESTKProfile].self, from: Data(json.utf8))
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].displayName, "Travel")
        XCTAssertTrue(profiles[0].isEnabled)
    }

    func testLPACNullableProfileFieldsDecode() throws {
        let json = #"""
        [
          {
            "iccid": "8901000000000000002",
            "isdpAid": null,
            "profileState": "disabled",
            "profileNickname": null,
            "serviceProviderName": null,
            "profileName": null,
            "profileClass": null
          }
        ]
        """#

        let profiles = try JSONDecoder().decode([ESTKProfile].self, from: Data(json.utf8))
        XCTAssertEqual(profiles[0].displayName, localized("estk.profile.unnamed"))
        XCTAssertEqual(profiles[0].operationIdentifier, "8901000000000000002")
    }

    func testOldSettingsPayloadDecodesWithoutESTKKeys() throws {
        let json = #"""
        {
          "openAtLogin": true,
          "infoPollSeconds": 12,
          "smsPollSeconds": 30,
          "restartOnWake": true,
          "preferredLanguage": null,
          "visibleFields": ["imei"]
        }
        """#

        let settings = try JSONDecoder().decode(ModemSettings.self, from: Data(json.utf8))
        XCTAssertNil(settings.estkISDRAID)
        XCTAssertNil(settings.estkES10xMSS)
        XCTAssertTrue(settings.effectiveESTKNotifyDownloads)
        XCTAssertTrue(settings.effectiveESTKNotifyDeletions)
        XCTAssertFalse(settings.effectiveESTKNotifySwitches)
        XCTAssertNil(settings.estkHTTPProxy)
        XCTAssertNil(settings.estkIgnoreTLSCertificate)
    }

    @MainActor
    func testProfileRefreshRetriesTransientEUICCInitializationFailure() async throws {
        var attempts = 0

        try await retryESTKProfileRefresh(attempts: 4, delay: .zero) {
            attempts += 1
            if attempts < 3 {
                throw RetryFailure()
            }
            return true
        }

        XCTAssertEqual(attempts, 3)
    }

    @MainActor
    func testProfileRefreshStopsWhenProfileStateHasNotChanged() async {
        var attempts = 0

        do {
            try await retryESTKProfileRefresh(attempts: 3, delay: .zero) {
                attempts += 1
                return false
            }
            XCTFail("Expected profile refresh to remain pending")
        } catch {
            XCTAssertEqual(attempts, 3)
            XCTAssertTrue(error is ESTKError)
        }
    }

    func testCompleteChipInfoDecoding() throws {
        let json = #"""
        {
          "eidValue": "89049032000000000000000000000000",
          "EuiccConfiguredAddresses": {
            "defaultDpAddress": "rsp.example.com",
            "rootDsAddress": "lpa.ds.gsma.com"
          },
          "EUICCInfo2": {
            "profileVersion": "2.3.1",
            "svn": "2.2.2",
            "euiccFirmwareVer": "1.0",
            "uiccCapability": ["contactless"],
            "ts102241Version": "16.0",
            "globalplatformVersion": "2.3",
            "rspCapability": ["additionalProfile"],
            "euiccCiPKIdListForVerification": ["81370f00"],
            "euiccCiPKIdListForSigning": ["81370f00"],
            "euiccCategory": "other",
            "forbiddenProfilePolicyRules": ["ppr1"],
            "ppVersion": "1.0",
            "sasAcreditationNumber": "DE-UP-0001",
            "certificationDataObject": {
              "platformLabel": "Example",
              "discoveryBaseURL": "https://example.com"
            },
            "extCardResource": {"freeNonVolatileMemory": 4096}
          },
          "rulesAuthorisationTable": [
            {"pprIds":["1"],"allowedOperators":[{"plmn":"00101"}],"pprFlags":["consentRequired"]}
          ]
        }
        """#
        let info = try JSONDecoder().decode(ESTKChipInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.extendedInfo?.uiccCapability, ["contactless"])
        XCTAssertEqual(info.extendedInfo?.certificationDataObject?.platformLabel, "Example")
        XCTAssertEqual(info.rulesAuthorisationTable?.first?.allowedOperators?.first?.plmn, "00101")
        XCTAssertEqual(ESTKRegistry.manufacturer(forEID: info.eidValue)?.manufacturer, "G+D")
        XCTAssertEqual(ESTKRegistry.certificateIssuer(forKeyID: "81370f00")?.name, "GSM Association - RSP2 Root CI1")
    }

    @MainActor
    func testLPACStandardIOBridge() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("lpac")
        let script = #"""
        #!/bin/sh
        printf '%s\n' '{"type":"apdu","payload":{"func":"connect","param":null}}'
        IFS= read -r response
        printf '%s\n' '{"type":"lpa","payload":{"code":0,"message":"success","data":"fake-version"}}'
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        var receivedFunction: String?
        let client = try LPACClient(
            executablePath: executable.path,
            isdRAID: ESTKDefaults.isdRAID,
            es10xMSS: ESTKDefaults.es10xMSS
        ) { request in
            receivedFunction = request.function
            return LPACAPDUResponse(errorCode: 0)
        }

        let version = try await client.run(["version"], decoding: String.self)
        XCTAssertEqual(version, "fake-version")
        XCTAssertEqual(receivedFunction, "connect")
    }

    @MainActor
    func testLPACEarlyExitDoesNotTerminateHostProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("lpac")
        let script = #"""
        #!/bin/sh
        printf '%s\n' '{"type":"apdu","payload":{"func":"connect","param":null}}'
        exit 1
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let client = try LPACClient(
            executablePath: executable.path,
            isdRAID: ESTKDefaults.isdRAID,
            es10xMSS: ESTKDefaults.es10xMSS
        ) { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return LPACAPDUResponse(errorCode: -1)
        }

        do {
            _ = try await client.run(["version"], decoding: String.self)
            XCTFail("Expected the child process to fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    @MainActor
    func testLPACFailureIncludesHTTPDiagnostics() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("lpac")
        let script = #"""
        #!/bin/sh
        printf '%s\n' 'curl_easy_perform() failed: SSL certificate problem' >&2
        printf '%s\n' '{"type":"lpa","payload":{"code":-1,"message":"es9p_handle_notification","data":"HTTP transport failed"}}'
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let client = try LPACClient(
            executablePath: executable.path,
            isdRAID: ESTKDefaults.isdRAID,
            es10xMSS: ESTKDefaults.es10xMSS
        ) { _ in
            LPACAPDUResponse(errorCode: 0)
        }

        do {
            try await client.runVoid(["notification", "process", "1"])
            XCTFail("Expected the notification request to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP transport failed"))
            XCTAssertTrue(error.localizedDescription.contains("SSL certificate problem"))
        }
    }

    @MainActor
    func testLPACProgressIncludesSequenceNumber() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("lpac")
        let script = #"""
        #!/bin/sh
        printf '%s\n' '{"type":"progress","payload":{"code":0,"message":"es9p_handle_notification","data":"109"}}'
        printf '%s\n' '{"type":"lpa","payload":{"code":0,"message":"success","data":null}}'
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        var progressMessages: [String] = []
        let client = try LPACClient(
            executablePath: executable.path,
            isdRAID: ESTKDefaults.isdRAID,
            es10xMSS: ESTKDefaults.es10xMSS,
            progressHandler: { progressMessages.append($0) }
        ) { _ in
            LPACAPDUResponse(errorCode: 0)
        }

        try await client.runVoid(["notification", "process", "109"])
        XCTAssertEqual(progressMessages, ["es9p_handle_notification · 109"])
    }

    @MainActor
    func testBundledLPACAcceptsConnectResponse() async throws {
        guard let path = ProcessInfo.processInfo.environment["EC25_TEST_LPAC_PATH"],
              FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Set EC25_TEST_LPAC_PATH to run the bundled lpac protocol test")
        }

        var functions: [String] = []
        let client = try LPACClient(
            executablePath: path,
            isdRAID: ESTKDefaults.isdRAID,
            es10xMSS: ESTKDefaults.es10xMSS
        ) { request in
            functions.append(request.function)
            switch request.function {
            case "connect", "disconnect":
                return LPACAPDUResponse(errorCode: 0)
            default:
                return LPACAPDUResponse(errorCode: -1, diagnostic: "TEST-APDU-STOP")
            }
        }

        do {
            _ = try await client.run(["chip", "info"], decoding: ESTKChipInfo.self)
            XCTFail("Expected the synthetic APDU failure")
        } catch {
            XCTAssertTrue(functions.contains("connect"), "functions=\(functions), error=\(error)")
            XCTAssertTrue(functions.contains("logic_channel_open"), "functions=\(functions), error=\(error)")
            XCTAssertFalse(error.localizedDescription.contains("couldn’t be saved"))
            XCTAssertFalse(error.localizedDescription.contains("could not be saved"))
        }
    }
}
