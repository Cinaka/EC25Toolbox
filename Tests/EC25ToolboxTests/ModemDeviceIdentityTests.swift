import XCTest
@testable import EC25Toolbox

final class ModemDeviceIdentityTests: XCTestCase {
    func testSerialIdentitySurvivesUSBPortMove() {
        let firstPort = USBModemDescriptor(
            vendorID: 0x2c7c,
            productID: 0x0125,
            serialNumber: "EC25-SERIAL-A",
            locationID: 0x0010_0000
        )
        let secondPort = USBModemDescriptor(
            vendorID: 0x2c7c,
            productID: 0x0125,
            serialNumber: "EC25-SERIAL-A",
            locationID: 0x0020_0000
        )
        let otherModule = USBModemDescriptor(
            vendorID: 0x2c7c,
            productID: 0x0125,
            serialNumber: "EC25-SERIAL-B",
            locationID: 0x0010_0000
        )

        XCTAssertEqual(firstPort.id, secondPort.id)
        XCTAssertNotEqual(firstPort.id, otherModule.id)
    }

    func testLocationFallbackSeparatesModulesWithoutUSBSerial() {
        let first = USBModemDescriptor(
            vendorID: 0x2ca3,
            productID: 0x4006,
            serialNumber: nil,
            locationID: 1
        )
        let second = USBModemDescriptor(
            vendorID: 0x2ca3,
            productID: 0x4006,
            serialNumber: nil,
            locationID: 2
        )
        XCTAssertNotEqual(first.id, second.id)
    }

    func testIMEIBecomesStableModuleIdentityAcrossUSBDescriptors() {
        let first = USBModemDescriptor(
            vendorID: 0x2c7c,
            productID: 0x0125,
            serialNumber: "USB-A",
            locationID: 1,
            imei: "867530900000001"
        )
        let second = USBModemDescriptor(
            vendorID: 0x2ca3,
            productID: 0x4006,
            serialNumber: "USB-B",
            locationID: 2,
            imei: "867530900000001"
        )

        XCTAssertNotEqual(first.id, second.id, "transport locators remain USB-specific")
        XCTAssertEqual(first.moduleID, second.moduleID, "the long-lived module index follows IMEI")
        XCTAssertNotEqual(first.moduleID, first.id)
    }
}
