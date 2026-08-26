import XCTest
@testable import EC25Toolbox

final class GSM7BitTests: XCTestCase {
    func testPackHelloHelloMatchesKnownVector() {
        let packed = GSM7Bit.pack("hellohello")
        XCTAssertEqual(packed?.characterCount, 10)
        XCTAssertEqual(packed?.octets.map { String(format: "%02X", $0) }.joined(), "E8329BFD4697D9EC37")
    }

    func testUnpackHelloHelloRoundTrips() {
        let octets: [UInt8] = [0xE8, 0x32, 0x9B, 0xFD, 0x46, 0x97, 0xD9, 0xEC, 0x37]
        XCTAssertEqual(GSM7Bit.unpack(octets, characterCount: 10), "hellohello")
    }

    func testPackUnpackRoundTripWithExtensionCharacters() {
        let text = "Price €10 {ok} [x] \\ | ^ ~"
        let packed = GSM7Bit.pack(text)
        XCTAssertNotNil(packed)
        XCTAssertEqual(
            GSM7Bit.unpack(packed!.octets, characterCount: packed!.characterCount),
            text
        )
    }

    func testCanEncodeRejectsNonGSMText() {
        XCTAssertTrue(GSM7Bit.canEncode("Plain ASCII 123"))
        XCTAssertTrue(GSM7Bit.canEncode("Grüße à é €"))
        XCTAssertFalse(GSM7Bit.canEncode("中文短信"))
        XCTAssertFalse(GSM7Bit.canEncode("emoji 🎉"))
        XCTAssertNil(GSM7Bit.pack("中文"))
    }

    func testUnpackWithFillBitsSkipsHeaderPadding() {
        // One fill bit then "A" (0x41): (0x41 << 1) = 0x82.
        XCTAssertEqual(GSM7Bit.unpack([0x82], characterCount: 1, fillBits: 1), "A")
    }

    func testUnpackHandlesTruncatedInputGracefully() {
        XCTAssertEqual(GSM7Bit.unpack([], characterCount: 5), "")
        // 0xE8 yields one full septet ("h") plus one garbage septet from the
        // missing second byte, then stops at the buffer end.
        XCTAssertEqual(GSM7Bit.unpack([0xE8], characterCount: 10), "h£")
    }

    func testDefaultAlphabetPunctuationAndSymbols() {
        let text = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ ¡¿§äöñüàÄÖÑÜ"
        let packed = GSM7Bit.pack(text)
        XCTAssertNotNil(packed)
        XCTAssertEqual(
            GSM7Bit.unpack(packed!.octets, characterCount: packed!.characterCount),
            text
        )
    }
}

final class BinarySMSClassifierTests: XCTestCase {
    private func decoded(
        pid: UInt8 = 0x00,
        dcs: UInt8 = 0xF5,
        destinationPort: UInt16? = nil,
        payload: Data?
    ) -> DecodedSMS {
        DecodedSMS(
            direction: .deliver,
            sender: "+1234",
            date: "25/08/21,10:00:00+32",
            pid: pid,
            dcs: dcs,
            alphabet: payload == nil ? .gsm7 : .octet,
            header: destinationPort.map {
                SMSUserDataHeader(destinationPort: $0, length: 7)
            },
            text: payload == nil ? "text" : "",
            binary: payload
        )
    }

    func testTextMessageIsNotClassified() {
        XCTAssertNil(BinarySMSClassifier.classify(decoded: decoded(payload: nil)))
    }

    func testMMSNotificationByContentTypeAndMessageType() {
        let payload = Data([0xBE, 0x8C, 0x82, 0x00, 0x10])
        let result = BinarySMSClassifier.classify(
            decoded: decoded(destinationPort: 2948, payload: payload)
        )
        XCTAssertEqual(result, .mmsNotification)
    }

    func testMMSContentTypeWithoutNotificationTypeIsUnknown() {
        let payload = Data([0xBE, 0x8C, 0x84])
        let result = BinarySMSClassifier.classify(
            decoded: decoded(destinationPort: 2948, payload: payload)
        )
        XCTAssertEqual(result, .unknownBinary)
    }

    func testWAPServiceIndicationAndLoading() {
        XCTAssertEqual(
            BinarySMSClassifier.classify(decoded: decoded(destinationPort: 2948, payload: Data([0xAE, 0x06]))),
            .wapSI
        )
        XCTAssertEqual(
            BinarySMSClassifier.classify(decoded: decoded(destinationPort: 2948, payload: Data([0xB0, 0x05]))),
            .wapSL
        )
    }

    func testOMAClientProvisioning() {
        XCTAssertEqual(
            BinarySMSClassifier.classify(decoded: decoded(destinationPort: 2948, payload: Data([0xB6, 0x01]))),
            .omaCP
        )
    }

    func testSIMOTAByPIDOrDCS() {
        XCTAssertEqual(
            BinarySMSClassifier.classify(decoded: decoded(pid: 0x7F, payload: Data([0x02, 0x70]))),
            .simOTA
        )
        XCTAssertEqual(
            BinarySMSClassifier.classify(decoded: decoded(dcs: 0xF6, payload: Data([0x02, 0x70]))),
            .simOTA
        )
    }

    func testUnknownPushAndPortlessBinaryAreUnknown() {
        XCTAssertEqual(
            BinarySMSClassifier.classify(decoded: decoded(destinationPort: 2948, payload: Data([0x99]))),
            .unknownBinary
        )
        XCTAssertEqual(
            BinarySMSClassifier.classify(decoded: decoded(payload: Data([0x01, 0x02]))),
            .unknownBinary
        )
    }
}

final class VerificationCodeExtractorTests: XCTestCase {
    func testChineseKeywordBeforeAndAfterCode() {
        XCTAssertEqual(
            VerificationCodeExtractor.extract(from: "【支付宝】您的验证码是 123456，5分钟内有效，请勿泄露。"),
            ["123456"]
        )
        XCTAssertEqual(
            VerificationCodeExtractor.extract(from: "456789为您的登录验证码，3分钟内有效。"),
            ["456789"]
        )
        XCTAssertEqual(
            VerificationCodeExtractor.extract(from: "【顺丰】取件码8462，请凭码取件。"),
            ["8462"]
        )
    }

    func testEnglishKeywords() {
        XCTAssertEqual(
            VerificationCodeExtractor.extract(from: "Your verification code is 4832. Do not share it."),
            ["4832"]
        )
        XCTAssertEqual(
            VerificationCodeExtractor.extract(from: "Use OTP 938271 to sign in to your account."),
            ["938271"]
        )
        XCTAssertEqual(
            VerificationCodeExtractor.extract(from: "Security Code: 12345"),
            ["12345"]
        )
    }

    func testFourToEightDigitsOnly() {
        XCTAssertEqual(VerificationCodeExtractor.extract(from: "验证码123"), [])
        XCTAssertEqual(VerificationCodeExtractor.extract(from: "验证码123456789"), [])
        XCTAssertEqual(VerificationCodeExtractor.extract(from: "验证码12345678"), ["12345678"])
    }

    func testCodesInsideLongerDigitRunsAreRejected() {
        XCTAssertEqual(VerificationCodeExtractor.extract(from: "验证码 20260821123456"), [])
        XCTAssertEqual(VerificationCodeExtractor.extract(from: "验证码1234567890"), [])
    }

    func testAmountsAndDecimalsAreRejected() {
        XCTAssertEqual(VerificationCodeExtractor.extract(from: "验证码金额￥1234.56"), [])
        XCTAssertEqual(VerificationCodeExtractor.extract(from: "验证码12.3456"), [])
    }

    func testBareYearInValiditySentenceIsNotACode() {
        XCTAssertEqual(VerificationCodeExtractor.extract(from: "您的验证码有效期至2026年，请及时使用。"), [])
    }

    func testNoKeywordMeansNoCode() {
        XCTAssertEqual(VerificationCodeExtractor.extract(from: "您的订单号 20260821 已发货。"), [])
        XCTAssertEqual(VerificationCodeExtractor.extract(from: "会议时间 14:30，会议室 1234"), [])
        XCTAssertEqual(VerificationCodeExtractor.extract(from: "Your zip code 94103 and order 847291"), [])
    }

    func testMultipleKeywordsCollectDistinctCodes() {
        XCTAssertEqual(
            VerificationCodeExtractor.extract(from: "验证码 1234，备用验证码 5678"),
            ["1234", "5678"]
        )
    }

    func testEmptyBody() {
        XCTAssertEqual(VerificationCodeExtractor.extract(from: ""), [])
    }
}
