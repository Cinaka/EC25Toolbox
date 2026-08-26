import XCTest
@testable import EC25Toolbox

final class SMSPDUTests: XCTestCase {
    /// SMSC +12345678901, sender +9876543210, 2025-08-21 16:14:48 +8h,
    /// 7-bit body "hellohello".
    private let deliver7Bit = "07912143658709F1040A9189674523010000528012614184230AE8329BFD4697D9EC37"

    func testDecodeDeliver7Bit() throws {
        let decoded = try SMSPDU.decode(deliver7Bit)
        XCTAssertEqual(decoded.direction, .deliver)
        XCTAssertEqual(decoded.sender, "+9876543210")
        XCTAssertEqual(decoded.date, "25/08/21,16:14:48+32")
        XCTAssertEqual(decoded.alphabet, .gsm7)
        XCTAssertNil(decoded.header)
        XCTAssertEqual(decoded.text, "hellohello")
        XCTAssertNil(decoded.binary)
    }

    func testDecodeDeliverUCS2() throws {
        // Same envelope, DCS 0x08, body "你好" (4F60 597D).
        let pdu = "07912143658709F1040A918967452301000852801261418423044F60597D"
        let decoded = try SMSPDU.decode(pdu)
        XCTAssertEqual(decoded.alphabet, .ucs2)
        XCTAssertEqual(decoded.text, "你好")
    }

    func testDecodeDeliverAlphanumericSender() throws {
        // TP-OA type-of-number 0xD0 ("EC25" packed 7-bit).
        let pdu = "07912143658709F10404D0C5A1AC060000528012614184230AE8329BFD4697D9EC37"
        let decoded = try SMSPDU.decode(pdu)
        XCTAssertEqual(decoded.sender, "EC25")
        XCTAssertEqual(decoded.text, "hellohello")
    }

    func testDecodeNegativeTimezone() throws {
        // Timezone octet 0x2B: sign bit set, 32 quarter-hours west.
        let pdu = "07912143658709F1040A91896745230100005280126141842B0AE8329BFD4697D9EC37"
        let decoded = try SMSPDU.decode(pdu)
        XCTAssertTrue(decoded.date.hasSuffix("-32"), decoded.date)
    }

    func testDecodeDeliverOctetPayloadIsBinary() throws {
        // DCS 0xF6 (8-bit, SIM-specific) with 4 payload octets.
        let pdu = "07912143658709F1040A91896745230100F65280126141842304DEADBEEF"
        let decoded = try SMSPDU.decode(pdu)
        XCTAssertEqual(decoded.alphabet, .octet)
        XCTAssertEqual(decoded.text, "")
        XCTAssertEqual(decoded.binary, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testDecodeRejectsMalformedInput() {
        XCTAssertThrowsError(try SMSPDU.decode("ZZ")) { error in
            XCTAssertEqual(error as? SMSPDUError, .invalidHex)
        }
        XCTAssertThrowsError(try SMSPDU.decode("0791")) { error in
            XCTAssertEqual(error as? SMSPDUError, .truncated)
        }
        // MTI = 2 (status report) is not a user message.
        XCTAssertThrowsError(try SMSPDU.decode("00020B918967452301F0000052801261418423000A")) { error in
            XCTAssertEqual(error as? SMSPDUError, .unsupportedMessageType(2))
        }
    }

    func testEncodeSubmitRoundTrip() throws {
        let encoded = SMSPDU.encodeSubmit(
            destination: "+8613800138000",
            text: "Meet at 7?",
            messageReference: 1
        )
        XCTAssertNotNil(encoded)
        let decoded = try SMSPDU.decode(encoded!.pdu)
        XCTAssertEqual(decoded.direction, .submit)
        XCTAssertEqual(decoded.sender, "+8613800138000")
        XCTAssertEqual(decoded.text, "Meet at 7?")
        XCTAssertEqual(decoded.date, "-")
        XCTAssertEqual(encoded!.length, encoded!.pdu.count / 2 - 1)
    }

    func testEncodeSubmitUCS2RoundTrip() throws {
        let encoded = SMSPDU.encodeSubmit(
            destination: "106980095533",
            text: "验证码测试",
            messageReference: 2
        )
        XCTAssertNotNil(encoded)
        let decoded = try SMSPDU.decode(encoded!.pdu)
        XCTAssertEqual(decoded.alphabet, .ucs2)
        XCTAssertEqual(decoded.sender, "106980095533")
        XCTAssertEqual(decoded.text, "验证码测试")
    }

    func testConcatSubmitRoundTripPreservesOrderAndFillBits() throws {
        let text = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 8) // 208 septets
        let parts = SMSPDU.encodeConcatSubmit(destination: "+1234", text: text, referenceSeed: 7)
        XCTAssertEqual(parts.count, 2)

        let first = try SMSPDU.decode(parts[0].pdu)
        let second = try SMSPDU.decode(parts[1].pdu)
        XCTAssertEqual(first.header?.concatenation, SMSConcatenation(reference: 7, total: 2, sequence: 1))
        XCTAssertEqual(second.header?.concatenation, SMSConcatenation(reference: 7, total: 2, sequence: 2))
        XCTAssertEqual(first.text + second.text, text)
    }

    func testConcatSubmitUCS2RoundTrip() throws {
        let text = String(repeating: "长短信正文内容", count: 20) // 140 chars > 70
        let parts = SMSPDU.encodeConcatSubmit(destination: "+1234", text: text, referenceSeed: 200)
        XCTAssertEqual(parts.count, 3)
        let decoded = try parts.map { try SMSPDU.decode($0.pdu) }
        XCTAssertEqual(decoded.map(\.text).joined(), text)
        XCTAssertEqual(Set(decoded.compactMap(\.header?.concatenation?.reference)), [200])
    }

    func testShortTextStaysSingleSubmit() {
        let parts = SMSPDU.encodeConcatSubmit(destination: "+1234", text: "short", referenceSeed: 9)
        XCTAssertEqual(parts.count, 1)
        XCTAssertNotNil(parts.first)
    }

    func testAlphabetMapping() {
        XCTAssertEqual(SMSPDU.alphabet(for: 0x00), .gsm7)
        XCTAssertEqual(SMSPDU.alphabet(for: 0x04), .octet)
        XCTAssertEqual(SMSPDU.alphabet(for: 0x08), .ucs2)
        XCTAssertEqual(SMSPDU.alphabet(for: 0xF6), .octet)
        XCTAssertEqual(SMSPDU.alphabet(for: 0xF0), .gsm7)
    }
}
