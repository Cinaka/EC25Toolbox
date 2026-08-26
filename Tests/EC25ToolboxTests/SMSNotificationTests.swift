import XCTest
@testable import EC25Toolbox

final class SMSNotificationTests: XCTestCase {
    private func makeMessage(
        id: String,
        outgoing: Bool = false,
        unread: Bool = true,
        sender: String = "10086",
        body: String = "hello"
    ) -> SMSMessage {
        SMSMessage(
            id: id,
            storage: "ME",
            index: 1,
            status: unread ? "REC UNREAD" : "REC READ",
            outgoing: outgoing,
            unread: unread,
            sender: sender,
            date: "26/08/21,15:00:00+32",
            body: body
        )
    }

    func testFreshIncomingKeepsOnlyNewUnreadIncoming() {
        let old = makeMessage(id: "a", unread: true)
        let newIncoming = makeMessage(id: "b", unread: true)
        let newOutgoing = makeMessage(id: "c", outgoing: true)
        let newRead = makeMessage(id: "d", unread: false)

        let fresh = SMSNotification.freshIncoming(
            previous: [old],
            current: [old, newIncoming, newOutgoing, newRead]
        )
        XCTAssertEqual(fresh.map(\.id), ["b"])
    }

    func testRedactedPreviewCollapsesWhitespaceAndTruncates() {
        XCTAssertEqual(
            SMSNotification.redactedPreview(of: "  第一行\n第二行  第三行 "),
            "第一行 第二行 第三行"
        )
        let long = String(repeating: "验证码内容", count: 10)
        let preview = SMSNotification.redactedPreview(of: long)
        XCTAssertEqual(preview.count, 17)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertEqual(String(preview.dropLast()), String(long.prefix(16)))
    }

    func testRedactedPreviewShortBodiesPassThrough() {
        XCTAssertEqual(SMSNotification.redactedPreview(of: "123456"), "123456")
        XCTAssertEqual(SMSNotification.redactedPreview(of: String(repeating: "a", count: 16)), String(repeating: "a", count: 16))
    }

    func testRedactedPreviewEmptyBodyFallsBackToPlaceholder() {
        XCTAssertEqual(
            SMSNotification.redactedPreview(of: "  \n  "),
            localized("sms.notification.no_preview")
        )
    }
}
