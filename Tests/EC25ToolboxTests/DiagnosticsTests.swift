import XCTest
@testable import EC25Toolbox

final class DiagnosticsSnapshotTests: XCTestCase {
    private func sensitiveState() -> ModemState {
        var state = ModemState()
        state.info.model = "EC25"
        state.info.revision = "EC25EFAR06A01M4G"
        state.capabilities = ModemCapabilities(
            gnss: .supported, usbVoice: false, usbConfiguration: true,
            dtmf: true, phonebook: false, euicc: true, pduSMS: true
        )
        state.activeCallNumber = "+8613800138000"
        state.call = CallStatus(
            phase: .incoming, number: "+8613800138000", direction: .incoming,
            phaseChangedAt: Date(timeIntervalSince1970: 1_000), startedAt: nil
        )
        state.messages = [
            SMSMessage(
                id: "msg-1", storage: "ME", index: 3, status: "REC UNREAD",
                outgoing: false, unread: true, sender: "+8613800138000",
                date: "26/07/10,09:40:48+32", body: "SECRET-SMS-BODY-98765"
            )
        ]
        state.lastError = "generic failure"
        state.commandRecords = [
            CommandRecord(
                title: "Dial",
                command: "ATD••••;",
                lines: ["OK"],
                error: nil
            ),
            CommandRecord(
                title: "List",
                command: "AT+CMGL=\"ALL\"",
                lines: ["log.redacted_lines: 3"],
                error: nil
            )
        ]
        state.callAudio.selectedModuleUID = "BAIWANGModule-1"
        state.callAudio.moduleDevice = AudioDeviceSummary(
            uid: "BAIWANGModule-1", name: "Baiwang Module", manufacturer: "BAIWANG",
            transportType: 1_879_248_557, hasInput: true, hasOutput: true
        )
        state.callAudio.uplinkRunning = true
        state.callAudio.downlinkRunning = false
        state.callAudio.lastError = "link failure reason"
        state.gnss.phase = .searching
        state.gnss.dataSource = .qgpsloc
        state.gnss.lastError = "CME 516"
        state.gnss.sourceFailure = "+CME ERROR: 504"
        return state
    }

    func testSnapshotNeverContainsSensitiveData() throws {
        let snapshot = DiagnosticsSnapshot.build(
            from: sensitiveState(),
            smsRefreshMode: .pdu,
            autoCleanEnabled: true,
            notificationAuthorizationStatus: "authorized",
            microphonePermissionStatus: "granted",
            generatedAt: Date(timeIntervalSince1970: 1_783_647_648)
        )

        let json = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("13800138000"), "phone numbers must never enter the snapshot")
        XCTAssertFalse(json.contains("SECRET-SMS-BODY-98765"), "SMS bodies must never enter the snapshot")
        XCTAssertFalse(json.contains("+86"), "dial strings must never enter the snapshot")
        // Only the redacted dial mirror may appear.
        XCTAssertTrue(json.contains("ATD••••;"))
    }

    func testSnapshotCoversRequiredSections() {
        let snapshot = DiagnosticsSnapshot.build(
            from: sensitiveState(),
            smsRefreshMode: SMSDiagnosticsRefreshMode(smsPDUModeUsable: nil),
            autoCleanEnabled: false,
            notificationAuthorizationStatus: "denied",
            microphonePermissionStatus: "undetermined",
            generatedAt: Date(timeIntervalSince1970: 1_783_647_648)
        )

        // Firmware capability results.
        XCTAssertEqual(snapshot.firmware.model, "EC25")
        XCTAssertEqual(snapshot.firmware.revision, "EC25EFAR06A01M4G")
        XCTAssertEqual(snapshot.firmware.gnss, "supported")
        XCTAssertFalse(snapshot.firmware.usbVoice)
        XCTAssertTrue(snapshot.firmware.usbConfiguration)
        XCTAssertTrue(snapshot.firmware.dtmf)
        XCTAssertFalse(snapshot.firmware.phonebook)
        XCTAssertTrue(snapshot.firmware.euicc)
        XCTAssertTrue(snapshot.firmware.pduSMS)

        // Call: phase only, never the number.
        XCTAssertEqual(snapshot.call.phase, "incoming")
        XCTAssertTrue(snapshot.call.hasRemoteParty)
        XCTAssertEqual(snapshot.call.direction, "incoming")

        // Notification and microphone permissions.
        XCTAssertEqual(snapshot.notifications.authorizationStatus, "denied")
        XCTAssertEqual(snapshot.notifications.microphonePermission, "undetermined")

        // Audio input/output endpoints and link state.
        XCTAssertEqual(snapshot.audio.moduleDeviceUID, "BAIWANGModule-1")
        XCTAssertEqual(snapshot.audio.moduleDeviceName, "Baiwang Module")
        XCTAssertTrue(snapshot.audio.uplinkRunning)
        XCTAssertFalse(snapshot.audio.downlinkRunning)
        XCTAssertEqual(snapshot.audio.lastError, "link failure reason")

        // GNSS data source.
        XCTAssertEqual(snapshot.gnss.phase, "searching")
        XCTAssertEqual(snapshot.gnss.dataSource, "qgpsloc")
        XCTAssertEqual(snapshot.gnss.sourceFailure, "+CME ERROR: 504")
        XCTAssertEqual(snapshot.gnss.lastError, "CME 516")

        // SMS refresh mode and auto-clean.
        XCTAssertEqual(snapshot.sms.refreshMode, .undetermined)
        XCTAssertFalse(snapshot.sms.autoCleanEnabled)

        // Recent commands carry the redacted mirrors.
        XCTAssertEqual(snapshot.recentCommands.count, 2)
        XCTAssertEqual(snapshot.recentCommands.first?.command, "ATD••••;")
        XCTAssertEqual(snapshot.lastError, "generic failure")
    }

    func testSMSRefreshModeLatching() {
        XCTAssertEqual(SMSDiagnosticsRefreshMode(smsPDUModeUsable: true), .pdu)
        XCTAssertEqual(SMSDiagnosticsRefreshMode(smsPDUModeUsable: false), .text)
        XCTAssertEqual(SMSDiagnosticsRefreshMode(smsPDUModeUsable: nil), .undetermined)
    }

    func testSnapshotCodableRoundtrip() throws {
        let snapshot = DiagnosticsSnapshot.build(
            from: sensitiveState(),
            smsRefreshMode: .text,
            autoCleanEnabled: true,
            notificationAuthorizationStatus: "unavailable",
            microphonePermissionStatus: "denied",
            generatedAt: Date(timeIntervalSince1970: 1_783_647_648)
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DiagnosticsSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testRecentCommandsCappedAndNewestKept() {
        var state = ModemState()
        for index in 0..<8 {
            state.commandRecords.append(CommandRecord(
                title: "C\(index)", command: "AT+CMD\(index)", lines: ["line \(index)"], error: nil
            ))
        }
        let snapshot = DiagnosticsSnapshot.build(
            from: state,
            smsRefreshMode: .text,
            autoCleanEnabled: false,
            notificationAuthorizationStatus: nil,
            microphonePermissionStatus: "undetermined",
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snapshot.recentCommands.count, 5)
        XCTAssertEqual(snapshot.recentCommands.first?.command, "AT+CMD3")
        XCTAssertEqual(snapshot.recentCommands.last?.command, "AT+CMD7")
    }
}

final class DiagnosticsRedactionTests: XCTestCase {
    func testDialCommandMasksNumberButKeepsStructure() {
        XCTAssertEqual(redactedCommandMirror("ATD+8613800138000;"), "ATD••••;")
        XCTAssertEqual(redactedCommandMirror("ATD13800138000"), "ATD••••")
        XCTAssertEqual(redactedCommandMirror("ATD*99#;"), "ATD••••;")
    }

    func testSMSSendCommandMasksRecipientOnly() {
        XCTAssertEqual(
            redactedCommandMirror("AT+CMGS=\"0031005600138001F3\""),
            "AT+CMGS=\"•••\""
        )
        XCTAssertEqual(
            redactedCommandMirror("AT+CMGS=\"13800138000\""),
            "AT+CMGS=\"•••\""
        )
    }

    func testUnknownCommandsMirrorVerbatim() {
        XCTAssertEqual(redactedCommandMirror("AT+CPBS=?"), "AT+CPBS=?")
        XCTAssertEqual(redactedCommandMirror("AT+CMGL=\"ALL\""), "AT+CMGL=\"ALL\"")
        XCTAssertEqual(redactedCommandMirror("AT"), "AT")
    }

    func testMaskingNeverEmitsTheOriginalArgument() {
        let sensitive = "ATD+8613800138000;"
        let mirrored = redactedCommandMirror(sensitive)
        XCTAssertFalse(mirrored.contains("13800138000"))
        let recipient = "AT+CMGS=\"0031005600138001F3\""
        XCTAssertFalse(redactedCommandMirror(recipient).contains("00310056"))
    }
}
