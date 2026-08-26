import XCTest
@testable import EC25Toolbox

final class ATLineRoutingTests: XCTestCase {
    // MARK: Final responses

    func testFinalResponses() {
        XCTAssertEqual(ATLineClassifier.classify(line: "OK", pendingCommand: "AT+CSQ"), .finalOK)
        XCTAssertEqual(ATLineClassifier.classify(line: "ERROR", pendingCommand: "AT+CSQ"), .finalError("ERROR"))
        XCTAssertEqual(
            ATLineClassifier.classify(line: "+CME ERROR: 100", pendingCommand: "AT+CSQ"),
            .finalError("+CME ERROR: 100")
        )
        XCTAssertEqual(
            ATLineClassifier.classify(line: "+CMS ERROR: 500", pendingCommand: "AT+CMGS"),
            .finalError("+CMS ERROR: 500")
        )
    }

    // MARK: Echo

    func testCommandEchoIsRecognized() {
        XCTAssertEqual(ATLineClassifier.classify(line: "AT+CSQ", pendingCommand: "AT+CSQ"), .echo)
        XCTAssertEqual(ATLineClassifier.classify(line: "AT+CSQ", pendingCommand: nil), .info)
    }

    // MARK: URC routing

    func testKnownURCPrefixesAreDiverted() {
        XCTAssertEqual(ATLineClassifier.classify(line: "+CMTI: \"ME\",3", pendingCommand: "AT+CSQ"), .urc)
        XCTAssertEqual(ATLineClassifier.classify(line: "RING", pendingCommand: "AT+CSQ"), .urc)
        XCTAssertEqual(ATLineClassifier.classify(line: "+CLIP: \"+8613800138000\",145,,,\"\"", pendingCommand: nil), .urc)
    }

    func testSolicitedResponsesClaimTheirPrefix() {
        // The +CREG: answer to AT+CREG? must stay part of the response even
        // though +CREG: is also an unsolicited prefix.
        XCTAssertEqual(
            ATLineClassifier.classify(line: "+CREG: 0,2", pendingCommand: "AT+CREG?"),
            .info
        )
        // The same line is unsolicited when another command is pending.
        XCTAssertEqual(
            ATLineClassifier.classify(line: "+CREG: 0,2", pendingCommand: "AT+CSQ"),
            .urc
        )
    }

    func testDialFailuresAreFinalsOnlyWhileDialing() {
        XCTAssertEqual(
            ATLineClassifier.classify(line: "NO CARRIER", pendingCommand: "ATD13800138000;"),
            .finalError("NO CARRIER")
        )
        XCTAssertEqual(ATLineClassifier.classify(line: "NO CARRIER", pendingCommand: "AT+CSQ"), .urc)
        XCTAssertEqual(ATLineClassifier.classify(line: "NO CARRIER", pendingCommand: nil), .urc)
    }

    // MARK: Expected-prefix derivation

    func testExpectedResponsePrefixDerivation() {
        XCTAssertEqual(ATLineClassifier.expectedResponsePrefix(for: "AT+CSQ"), "+CSQ:")
        XCTAssertEqual(ATLineClassifier.expectedResponsePrefix(for: "AT+CREG?"), "+CREG:")
        XCTAssertEqual(ATLineClassifier.expectedResponsePrefix(for: "at+cops?"), "+COPS:")
        XCTAssertEqual(ATLineClassifier.expectedResponsePrefix(for: "AT+CMGL=\"ALL\""), "+CMGL:")
        XCTAssertEqual(ATLineClassifier.expectedResponsePrefix(for: "AT+QGPSLOC=0"), "+QGPSLOC:")
        XCTAssertNil(ATLineClassifier.expectedResponsePrefix(for: "AT"))
        XCTAssertNil(ATLineClassifier.expectedResponsePrefix(for: "ATI"))
        XCTAssertNil(ATLineClassifier.expectedResponsePrefix(for: "ATD13800138000;"))
    }

    // MARK: Response collection

    func testSimulatedURCsDoNotPolluteCommandResponse() {
        var collector = ATResponseCollector(pendingCommand: "AT+CMGL=\"ALL\"")

        let outcome1 = collector.accept(.line("AT+CMGL=\"ALL\""))
        let outcome2 = collector.accept(.line("+CMGL: 1,\"REC READ\",,\"8613800138000\""));
        let outcome3 = collector.accept(.line("+CMTI: \"ME\",7"));
        let outcome4 = collector.accept(.line("RING"));
        let outcome5 = collector.accept(.line("+CMGL: 2,\"REC UNREAD\",,\"8613800138001\""));
        let outcome6 = collector.accept(.line("OK"))

        XCTAssertEqual(outcome1, .continueReading)
        XCTAssertEqual(outcome2, .continueReading)
        XCTAssertEqual(outcome3, .continueReading)
        XCTAssertEqual(outcome4, .continueReading)
        XCTAssertEqual(outcome5, .continueReading)
        XCTAssertEqual(outcome6, .done)
        XCTAssertEqual(collector.responseLines, [
            "+CMGL: 1,\"REC READ\",,\"8613800138000\"",
            "+CMGL: 2,\"REC UNREAD\",,\"8613800138001\"",
        ])
        XCTAssertEqual(collector.urcs, ["+CMTI: \"ME\",7", "RING"])
    }

    func testCollectorFailsOnErrorResponse() {
        var collector = ATResponseCollector(pendingCommand: "AT+CSQ")

        XCTAssertEqual(collector.accept(.line("AT+CSQ")), .continueReading)
        XCTAssertEqual(collector.accept(.line("+CME ERROR: 100")), .failed("+CME ERROR: 100"))
    }

    func testCollectorPassesThroughFramingFailure() {
        var collector = ATResponseCollector(pendingCommand: "AT+CSQ")

        XCTAssertEqual(collector.accept(.framingFailure("oversized")), .failed("oversized"))
    }

    func testCollectorSkipsPromptEvents() {
        var collector = ATResponseCollector(pendingCommand: "AT+CMGS=17")

        XCTAssertEqual(collector.accept(.prompt), .continueReading)
        XCTAssertEqual(collector.accept(.line("OK")), .done)
    }

    func testFinishWithTailHonorsUnterminatedOK() {
        var collector = ATResponseCollector(pendingCommand: "AT+CSQ")

        _ = collector.accept(.line("+CSQ: 21,99"))
        XCTAssertEqual(collector.finishWithTail("OK"), .done)
        XCTAssertEqual(collector.responseLines, ["+CSQ: 21,99"])
    }

    func testFinishWithTailReportsTimeoutOtherwise() {
        var collector = ATResponseCollector(pendingCommand: "AT+CSQ")

        _ = collector.accept(.line("+CSQ: 21,99"))
        XCTAssertEqual(collector.finishWithTail(nil), .failed(nil))
        XCTAssertEqual(collector.finishWithTail("+CSQ: 21,99"), .failed(nil))
        XCTAssertEqual(collector.finishWithTail("+CME ERROR: 100"), .failed("+CME ERROR: 100"))
    }

    func testFinishWithTailClassifiesUnterminatedURCAsTimeout() {
        var collector = ATResponseCollector(pendingCommand: "AT+CSQ")

        _ = collector.accept(.line("+CSQ: 21,99"))
        // A trailing URC without terminator must not complete the response.
        XCTAssertEqual(collector.finishWithTail("+CMTI: \"ME\",7"), .failed(nil))
        XCTAssertEqual(collector.urcs, [])
    }
}
