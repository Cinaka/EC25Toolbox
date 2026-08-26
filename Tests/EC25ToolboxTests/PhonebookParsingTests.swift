import XCTest
@testable import EC25Toolbox

final class PhonebookParsingTests: XCTestCase {
    // MARK: - AT+CPBS=? supported storages

    func testParsePhonebookStoragesListsQuotedTypes() {
        let lines = ["+CPBS: (\"SM\",\"ME\",\"ON\",\"FD\")", "OK"]
        XCTAssertEqual(parsePhonebookStorages(lines), ["SM", "ME", "ON", "FD"])
    }

    func testParsePhonebookStoragesToleratesWhitespaceAndSingleEntry() {
        XCTAssertEqual(parsePhonebookStorages(["+CPBS: ( \"SM\" )"]), ["SM"])
        XCTAssertEqual(parsePhonebookStorages(["+CPBS: ()"]), [])
    }

    func testParsePhonebookStoragesEmptyWithoutPrefixedLine() {
        XCTAssertEqual(parsePhonebookStorages(["OK"]), [])
        XCTAssertEqual(parsePhonebookStorages(["ERROR"]), [])
        XCTAssertEqual(parsePhonebookStorages(["+CPBS: \"SM\""]), [])
    }

    // MARK: - AT+CPBS? selected storage

    func testParsePhonebookSelectionReadsStorageAndSlotCounters() {
        let selection = parsePhonebookSelection(["+CPBS: \"SM\",10,250", "OK"])
        XCTAssertEqual(selection?.storage, "SM")
        XCTAssertEqual(selection?.used, 10)
        XCTAssertEqual(selection?.total, 250)
    }

    func testParsePhonebookSelectionKeepsMissingCountersOptional() {
        let selection = parsePhonebookSelection(["+CPBS: \"ON\""])
        XCTAssertEqual(selection?.storage, "ON")
        XCTAssertNil(selection?.used)
        XCTAssertNil(selection?.total)
    }

    func testParsePhonebookSelectionNilWithoutStorage() {
        XCTAssertNil(parsePhonebookSelection(["OK"]))
        XCTAssertNil(parsePhonebookSelection(["ERROR"]))
        XCTAssertNil(parsePhonebookSelection(["+CPBS: ,5,250"]))
    }

    // MARK: - AT+CPBR=? record range and field limits

    func testParsePhonebookRecordLimitsAfterIndexRange() {
        let limits = parsePhonebookRecordLimits(["+CPBR: (1-250),40,14", "OK"])
        XCTAssertEqual(limits?.numberLength, 40)
        XCTAssertEqual(limits?.nameLength, 14)
    }

    func testParsePhonebookRecordLimitsPartialOrMissingTail() {
        let partial = parsePhonebookRecordLimits(["+CPBR: (1-100),20"])
        XCTAssertEqual(partial?.numberLength, 20)
        XCTAssertNil(partial?.nameLength)

        XCTAssertNil(parsePhonebookRecordLimits(["+CPBR: (1-100)"]))
        XCTAssertNil(parsePhonebookRecordLimits(["OK"]))
    }

    func testParsePhonebookIndexRangeMalformedDegradesToNil() {
        XCTAssertNil(parsePhonebookIndexRange(["+CPBR: (1-)"]))
        XCTAssertNil(parsePhonebookIndexRange(["+CPBR: (250-1)"]))
        XCTAssertNil(parsePhonebookIndexRange(["OK"]))
    }

    // MARK: - Capability decision

    func testPhonebookStateIsSupportedRequiresAnyUsableData() {
        var empty = PhonebookState()
        XCTAssertFalse(empty.isSupported)

        empty.supportedStorages = ["SM"]
        XCTAssertTrue(empty.isSupported)

        var rangeOnly = PhonebookState()
        rangeOnly.recordRange = 1...50
        XCTAssertTrue(rangeOnly.isSupported)

        var selectionOnly = PhonebookState()
        selectionOnly.selectedStorage = "ME"
        XCTAssertTrue(selectionOnly.isSupported)
    }

    func testDegradedProbeResponsesStayUnsupported() {
        // All commands erroring (or answering plain ERROR) yields no usable
        // data, which the store reports as an unsupported snapshot.
        XCTAssertEqual(parsePhonebookStorages(["ERROR"]), [])
        XCTAssertNil(parsePhonebookSelection(["ERROR"]))
        XCTAssertNil(parsePhonebookIndexRange(["ERROR"]))
        XCTAssertNil(parsePhonebookRecordLimits(["ERROR"]))
        XCTAssertFalse(PhonebookState().isSupported)
    }
}
