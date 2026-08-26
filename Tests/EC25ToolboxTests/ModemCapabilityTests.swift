import XCTest
@testable import EC25Toolbox

@MainActor
final class ModemCapabilityTests: XCTestCase {
    func testProberRecordsSupportedCapabilities() async {
        let capabilities = await ModemCapabilityProber.probe { command in
            switch command {
            case "AT+QGPS=?":
                return ["OK"]
            case "AT+QPCMV=?":
                throw EC25TransportError.sendFailed("ERROR")
            case "AT+QCFG=\"usbcfg\"":
                return ["+QCFG: \"usbcfg\",0x1F1,1,3,2,1,1", "OK"]
            case "AT+VTS=?":
                return ["OK"]
            case "AT+CPBS=?":
                return ["+CPBS: (\"SM\",\"ON\")", "OK"]
            default:
                return ["OK"]
            }
        }

        var expected = ModemCapabilities()
        expected.gnss = .supported
        expected.usbConfiguration = true
        expected.dtmf = true
        expected.phonebook = true
        XCTAssertEqual(capabilities, expected)
    }

    func testProberSurvivesTotalSilenceAndFailures() async {
        let capabilities = await ModemCapabilityProber.probe { _ in
            throw EC25TransportError.sendFailed("timeout")
        }

        // A transport-level failure is recorded as an error, never as a
        // firmware verdict, so one flaky probe cannot hide the GNSS tab.
        XCTAssertEqual(capabilities.gnss, .error)
        XCTAssertFalse(capabilities.usbVoice)
        XCTAssertFalse(capabilities.usbConfiguration)
        XCTAssertFalse(capabilities.dtmf)
        XCTAssertFalse(capabilities.phonebook)
    }

    func testGNSSProbeClassifiesFirmwareVerdicts() async {
        // Plain ERROR: the firmware does not know the command.
        let unsupported = await ModemCapabilityProber.probeGNSS { _ in
            throw EC25TransportError.sendFailed("ERROR")
        }
        XCTAssertEqual(unsupported, .unsupported)

        // CME 4/100: explicit "operation not supported".
        let cme = await ModemCapabilityProber.probeGNSS { _ in
            throw EC25TransportError.sendFailed("operation not supported")
        }
        XCTAssertEqual(cme, .unsupported)

        // CME 4/100 numeric forms.
        XCTAssertEqual(GNSSCapability.classify(.failure(EC25TransportError.sendFailed("+CME ERROR: 4"))), .unsupported)
        XCTAssertEqual(GNSSCapability.classify(.failure(EC25TransportError.sendFailed("+CME ERROR: 100"))), .unsupported)
        // Verbose CME rejections.
        XCTAssertEqual(GNSSCapability.classify(.failure(EC25TransportError.sendFailed("+CME ERROR: operation not allowed"))), .unsupported)

        // Transport noise stays .error.
        XCTAssertEqual(GNSSCapability.classify(.failure(EC25TransportError.sendFailed("command timeout"))), .error)
        XCTAssertEqual(GNSSCapability.classify(.success(["OK"])), .supported)
        // R10: every verdict keeps the GNSS tab visible; an unsupported
        // verdict is explained on the page instead of hiding navigation.
        XCTAssertTrue(PanelTab.allCases.contains(.gnss))
    }

    func testProberRequiresMatchingUSBCFGResponse() async {
        let capabilities = await ModemCapabilityProber.probe { command in
            command == "AT+QCFG=\"usbcfg\"" ? ["OK"] : ["OK"]
        }

        XCTAssertEqual(capabilities.usbConfiguration, false)
    }
}
