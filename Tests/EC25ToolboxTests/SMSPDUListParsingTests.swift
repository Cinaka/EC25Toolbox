import XCTest
@testable import EC25Toolbox

final class SMSPDUListParsingTests: XCTestCase {
    /// Builds a DELIVER PDU around a 7-bit or UCS2 body with an optional
    /// concatenation UDH, mirroring what `AT+CMGL=4` emits after `CMGF=0`.
    private func deliverPDU(
        body: String,
        reference: UInt8? = nil,
        total: Int = 1,
        sequence: Int = 1
    ) -> String {
        var firstOctet: UInt8 = 0x04
        var header: [UInt8] = []
        var dcs: UInt8 = 0x00
        var ud: [UInt8]
        var udl: Int
        if let reference {
            firstOctet |= 0x40
            header = SMSUserDataHeader.concatenationBytes(reference: reference, total: total, sequence: sequence)
        }
        if let packed = GSM7Bit.pack(body) {
            if header.isEmpty {
                ud = packed.octets
                udl = packed.characterCount
            } else {
                let fillBits = (7 - (header.count * 8) % 7) % 7
                var shifted: [UInt8] = []
                var carry = 0
                for octet in packed.octets {
                    shifted.append(UInt8((carry | Int(octet) << fillBits) & 0xFF))
                    carry = Int(octet) >> (8 - fillBits)
                }
                if carry > 0 { shifted.append(UInt8(carry)) }
                ud = header + shifted
                udl = ((header.count * 8) + 6) / 7 + packed.characterCount
            }
        } else {
            dcs = 0x08
            ud = header + Array(body.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
            udl = ud.count
        }

        var bytes: [UInt8] = [0x07, 0x91, 0x21, 0x43, 0x65, 0x87, 0x09, 0xF1]
        bytes.append(firstOctet)
        bytes.append(contentsOf: [0x0A, 0x91, 0x89, 0x67, 0x45, 0x23, 0x01])
        bytes.append(contentsOf: [0x00, dcs])
        bytes.append(contentsOf: [0x52, 0x80, 0x12, 0x61, 0x41, 0x84, 0x23])
        bytes.append(UInt8(udl))
        bytes.append(contentsOf: ud)
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    func testParsesPlainAndUCS2Entries() {
        let lines = [
            "+CMGL: 1,1,,23",
            deliverPDU(body: "hellohello"),
            "+CMGL: 2,0,,14",
            deliverPDU(body: "你好"),
            "OK",
        ]
        let segments = parsePDUMessageList(lines, storage: "SM")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].body, "hellohello")
        XCTAssertEqual(segments[0].sender, "+9876543210")
        XCTAssertFalse(segments[0].unread)
        XCTAssertNil(segments[0].concatenation)
        XCTAssertEqual(segments[1].body, "你好")
        XCTAssertTrue(segments[1].unread)
        XCTAssertEqual(segments[1].status, "REC UNREAD")
        XCTAssertNotNil(segments[1].rawPDU, "PDU-mode listings retain the raw payload")
    }

    func testParsesConcatenatedSegmentsWithUDH() {
        let full = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 8) // 208 chars
        let part1 = String(full.prefix(153))
        let part2 = String(full.dropFirst(153))
        let lines = [
            "+CMGL: 4,0,,160",
            deliverPDU(body: part2, reference: 9, total: 2, sequence: 2),
            "+CMGL: 3,1,,160",
            deliverPDU(body: part1, reference: 9, total: 2, sequence: 1),
        ]
        let segments = parsePDUMessageList(lines, storage: "ME")
        // The parser no longer reassembles: each listing entry stays a segment
        // carrying its concatenation identity for the logical assembly layer.
        XCTAssertEqual(segments.count, 2)
        let byIndex = Dictionary(uniqueKeysWithValues: segments.map { ($0.index, $0) })
        XCTAssertEqual(byIndex[3]?.concatenation?.reference, 9)
        XCTAssertEqual(byIndex[3]?.concatenation?.total, 2)
        XCTAssertEqual(byIndex[3]?.concatenation?.sequence, 1)
        XCTAssertEqual(byIndex[3]?.body, part1)
        XCTAssertEqual(byIndex[4]?.concatenation?.sequence, 2)
    }

    func testSkipsMalformedPDUButKeepsValidEntries() {
        let lines = [
            "+CMGL: 1,1,,23",
            "NOT-A-PDU",
            "+CMGL: 2,1,,23",
            deliverPDU(body: "hellohello"),
        ]
        let segments = parsePDUMessageList(lines, storage: "SM")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].index, 2)
    }

    func testIncompleteGroupStillExposesItsSegment() {
        let lines = [
            "+CMGL: 5,0,,160",
            deliverPDU(body: String(repeating: "a", count: 153), reference: 9, total: 2, sequence: 1),
        ]
        let segments = parsePDUMessageList(lines, storage: "SM")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].body, String(repeating: "a", count: 153))
        XCTAssertEqual(segments[0].concatenation?.sequence, 1)
    }
}
