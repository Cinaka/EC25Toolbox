import XCTest
@testable import EC25Toolbox

final class ATLineFramerTests: XCTestCase {
    func testFramesTransactionAcrossSingleByteChunks() throws {
        var framer = ATLineFramer()
        var outputs: [ATLineFramerOutput] = []
        let stream = Data("AT+CSQ\r\r\n+CSQ: 20,99\r\n\r\nOK\r\n".utf8)

        for byte in stream {
            outputs += try framer.accept(Data([byte]))
        }

        XCTAssertEqual(outputs, [
            .line("AT+CSQ"),
            .line("+CSQ: 20,99"),
            .line("OK"),
        ])
    }

    func testMixedTerminatorsEachEndALine() throws {
        var framer = ATLineFramer()
        let outputs = try framer.accept(Data("A\rB\nC\r\nD\n\rE\r\n".utf8))

        XCTAssertEqual(outputs, [
            .line("A"),
            .line("B"),
            .line("C"),
            .line("D"),
            .line("E"),
        ])
    }

    func testEmptyAndWhitespaceLinesAreDropped() throws {
        var framer = ATLineFramer()
        let outputs = try framer.accept(Data("\r\n\r\n\r\n   \r\nOK\r\r".utf8))

        XCTAssertEqual(outputs, [.line("OK")])
    }

    func testPromptEmittedOnlyAtLineStart() throws {
        var framer = ATLineFramer()

        XCTAssertEqual(try framer.accept(Data("\r\n> ".utf8)), [.prompt])
        XCTAssertEqual(try framer.accept(Data("a>b\r\n".utf8)), [.line("a>b")])
    }

    func testOversizedLineThrowsAndFramingResumes() throws {
        var framer = ATLineFramer(maxLineBytes: 4)

        XCTAssertThrowsError(try framer.accept(Data("TOOLONG\r\n".utf8))) { error in
            XCTAssertEqual(error as? ATLineFramer.FramingError, .lineTooLong(limit: 4))
        }

        XCTAssertEqual(try framer.accept(Data("OK\r\n".utf8)), [.line("OK")])
    }

    func testFlushPendingEmitsUnterminatedLineOnce() throws {
        var framer = ATLineFramer()

        _ = try framer.accept(Data("  OK  ".utf8))
        XCTAssertTrue(framer.hasPendingLine)
        XCTAssertEqual(framer.flushPending(), .line("OK"))
        XCTAssertFalse(framer.hasPendingLine)
        XCTAssertNil(framer.flushPending())
    }

    func testFlushPendingDropsWhitespaceOnlyRemainder() throws {
        var framer = ATLineFramer()

        _ = try framer.accept(Data("OK\r\n   ".utf8))

        XCTAssertNil(framer.flushPending())
    }
}
