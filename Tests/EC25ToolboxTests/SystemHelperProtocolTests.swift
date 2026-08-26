import EC25SystemHelperProtocol
import Foundation
import XCTest

final class SystemHelperProtocolTests: XCTestCase {
    private let channelID = UUID(uuidString: "4D5B6C7D-8E9F-40A1-B2C3-D4E5F6071829")!
    private let serviceID = UUID(uuidString: "1A2B3C4D-5E6F-47A8-B9C0-D1E2F3041526")!

    // MARK: - Envelope round-trips

    func testIKEOpenChannelRoundTrip() throws {
        let request = EC25SystemHelperRequest.ikeOpenChannel(
            IKEOpenChannelRequest(host: "203.0.113.10", remotePort: 500, localPort: 500)
        )
        try assertRequestRoundTrip(request)
    }

    func testIKESendRoundTrip() throws {
        let request = EC25SystemHelperRequest.ikeSend(
            IKESendRequest(channelID: channelID, payload: Data([0x01, 0x02, 0xFF]))
        )
        try assertRequestRoundTrip(request)
    }

    func testIKEReceiveRoundTrip() throws {
        let request = EC25SystemHelperRequest.ikeReceive(
            IKEReceiveRequest(channelID: channelID, timeout: 2.5)
        )
        try assertRequestRoundTrip(request)
    }

    func testIKECloseRoundTrip() throws {
        let request = EC25SystemHelperRequest.ikeClose(IKECloseRequest(channelID: channelID))
        try assertRequestRoundTrip(request)
    }

    func testNetworkRequestsRoundTrip() throws {
        let requests: [EC25SystemHelperRequest] = [
            .networkCreateService(NetworkServiceCreateRequest(
                interface: NetworkInterfaceReference(bsdName: "en5"),
                serviceName: "EC25 Cellular"
            )),
            .networkSetServiceEnabled(NetworkServiceStateRequest(serviceID: serviceID, enabled: true)),
            .networkRenewDHCP(NetworkDHCPRenewRequest(serviceID: serviceID)),
            .networkForceInterfaceRefresh(NetworkInterfaceReference(bsdName: "en5"))
        ]
        for request in requests {
            try assertRequestRoundTrip(request)
        }
    }

    func testResponsesRoundTrip() throws {
        let responses: [EC25SystemHelperResponse] = [
            .ikeChannelOpened(channelID: channelID),
            .ikeSent,
            .ikeReceived(payload: Data([0xDE, 0xAD, 0xBE, 0xEF])),
            .ikeClosed,
            .networkOperationCompleted,
            .failure(message: "validation failed")
        ]
        for response in responses {
            let data = try EC25SystemHelperCoding.encodeResponse(response)
            XCTAssertEqual(try EC25SystemHelperCoding.decodeResponse(data), response)
        }
    }

    func testMalformedEnvelopeRejected() {
        XCTAssertThrowsError(try EC25SystemHelperCoding.decodeRequest(Data([0x00, 0x01]))) { error in
            XCTAssertTrue(error is DecodingError)
        }
        let unknownOperation = #"{"operation":"dropDatabase","payload":""}"#.data(using: .utf8)!
        XCTAssertThrowsError(try EC25SystemHelperCoding.decodeRequest(unknownOperation)) { error in
            XCTAssertEqual(error as? EC25SystemHelperEnvelopeError, .malformedEnvelope)
        }
        let unknownResponse = #"{"operation":"shellOut","payload":""}"#.data(using: .utf8)!
        XCTAssertThrowsError(try EC25SystemHelperCoding.decodeResponse(unknownResponse)) { error in
            XCTAssertEqual(error as? EC25SystemHelperEnvelopeError, .malformedEnvelope)
        }
    }

    // MARK: - Validator accepts

    func testValidatorAcceptsWellFormedRequests() throws {
        let requests: [EC25SystemHelperRequest] = [
            .ikeOpenChannel(IKEOpenChannelRequest(host: "203.0.113.10", remotePort: 500, localPort: 500)),
            .ikeOpenChannel(IKEOpenChannelRequest(host: "2001:db8::1", remotePort: 4_500, localPort: 4_500)),
            .ikeSend(IKESendRequest(channelID: channelID, payload: Data([0x01]))),
            .ikeReceive(IKEReceiveRequest(channelID: channelID, timeout: 0.001)),
            .ikeReceive(IKEReceiveRequest(channelID: channelID, timeout: 300)),
            .ikeClose(IKECloseRequest(channelID: channelID)),
            .networkCreateService(NetworkServiceCreateRequest(
                interface: NetworkInterfaceReference(bsdName: "en5"),
                serviceName: "EC25 Cellular"
            )),
            .networkSetServiceEnabled(NetworkServiceStateRequest(serviceID: serviceID, enabled: false)),
            .networkRenewDHCP(NetworkDHCPRenewRequest(serviceID: serviceID)),
            .networkForceInterfaceRefresh(NetworkInterfaceReference(bsdName: "ppp0"))
        ]
        for request in requests {
            XCTAssertEqual(try EC25SystemHelperValidator.validated(request), request)
        }
    }

    // MARK: - Validator rejects

    func testValidatorRejectsDNSHostnames() {
        for host in ["epdg.example.com", "localhost", "example.com; rm -rf /", ""] {
            assertRejected(
                .ikeOpenChannel(IKEOpenChannelRequest(host: host, remotePort: 500, localPort: 500)),
                equals: .invalidHost
            )
        }
    }

    func testValidatorRejectsNonPublicHosts() {
        for host in ["127.0.0.1", "127.1.2.3", "0.0.0.0", "::1", "::"] {
            assertRejected(
                .ikeOpenChannel(IKEOpenChannelRequest(host: host, remotePort: 500, localPort: 500)),
                equals: .nonPublicHost
            )
        }
    }

    func testValidatorRejectsNonIKEPorts() {
        assertRejected(
            .ikeOpenChannel(IKEOpenChannelRequest(host: "203.0.113.10", remotePort: 5_000, localPort: 5_000)),
            equals: .unsupportedPort
        )
        assertRejected(
            .ikeOpenChannel(IKEOpenChannelRequest(host: "203.0.113.10", remotePort: 500, localPort: 4_500)),
            equals: .mismatchedPorts
        )
    }

    func testValidatorRejectsBadPayloadsAndTimeouts() {
        assertRejected(
            .ikeSend(IKESendRequest(channelID: channelID, payload: Data())),
            equals: .invalidPayloadLength
        )
        assertRejected(
            .ikeSend(IKESendRequest(channelID: channelID, payload: Data(repeating: 0, count: 65_536))),
            equals: .invalidPayloadLength
        )
        assertRejected(
            .ikeReceive(IKEReceiveRequest(channelID: channelID, timeout: 0)),
            equals: .invalidTimeout
        )
        assertRejected(
            .ikeReceive(IKEReceiveRequest(channelID: channelID, timeout: 301)),
            equals: .invalidTimeout
        )
    }

    func testValidatorRejectsBadInterfaceNames() {
        for name in ["", "en5; reboot", "../etc/passwd", "en 5", "en-5", "a123456789012345", "en五"] {
            assertRejected(
                .networkForceInterfaceRefresh(NetworkInterfaceReference(bsdName: name)),
                equals: .invalidInterfaceName
            )
        }
    }

    func testValidatorRejectsBadServiceNames() {
        for name in ["", "  padded", "trailing ", "line\nbreak", String(repeating: "x", count: 129)] {
            assertRejected(
                .networkCreateService(NetworkServiceCreateRequest(
                    interface: NetworkInterfaceReference(bsdName: "en5"),
                    serviceName: name
                )),
                equals: .invalidServiceName
            )
        }
    }

    // MARK: - Helpers

    private func assertRequestRoundTrip(_ request: EC25SystemHelperRequest) throws {
        let data = try EC25SystemHelperCoding.encodeRequest(request)
        XCTAssertEqual(try EC25SystemHelperCoding.decodeRequest(data), request)
    }

    private func assertRejected(
        _ request: EC25SystemHelperRequest,
        equals expected: EC25SystemHelperValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try EC25SystemHelperValidator.validated(request)
            XCTFail("Expected \(expected) for \(request)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}
