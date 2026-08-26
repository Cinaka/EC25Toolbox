@testable import EC25Toolbox
import XCTest

final class ModemNetworkDecisionTests: XCTestCase {
    private let nic = ModemNICInfo(
        usbVID: 0x2c7c,
        usbPID: 0x0125,
        bsdName: "en7",
        macAddress: "0a:1b:2c:3d:4e:5f"
    )

    private func service(
        _ name: String,
        bsdName: String,
        enabled: Bool = true,
        ipv4: String? = "DHCP",
        id: UUID = UUID()
    ) -> ModemNetworkServiceInfo {
        ModemNetworkServiceInfo(
            serviceID: id,
            name: name,
            enabled: enabled,
            bsdName: bsdName,
            ipv4Method: ipv4
        )
    }

    // MARK: - Service plan

    func testPlanWithoutNICRequestsNothing() {
        XCTAssertEqual(
            ModemNetworkPlan.servicePlan(nic: nil, services: [], preferredName: "EC25 4G"),
            .noInterface
        )
    }

    func testPlanReusesEnabledBoundService() {
        let bound = service("EC25 4G", bsdName: "en7")
        let others = [
            service("Wi-Fi", bsdName: "en0"),
            service("Thunderbolt", bsdName: "bridge0")
        ]
        XCTAssertEqual(
            ModemNetworkPlan.servicePlan(nic: nic, services: others + [bound], preferredName: "EC25 4G"),
            .useExisting(bound)
        )
    }

    func testPlanReusesDisabledBoundServiceInsteadOfCreatingDuplicate() {
        let bound = service("EC25 4G", bsdName: "en7", enabled: false)
        let plan = ModemNetworkPlan.servicePlan(
            nic: nic,
            services: [service("Wi-Fi", bsdName: "en0"), bound],
            preferredName: "EC25 4G"
        )
        XCTAssertEqual(plan, .useExisting(bound))
    }

    func testPlanCreatesServiceWhenInterfaceIsUnbound() {
        let existing = [service("Wi-Fi", bsdName: "en0")]
        XCTAssertEqual(
            ModemNetworkPlan.servicePlan(nic: nic, services: existing, preferredName: "EC25 4G"),
            .create(bsdName: "en7", serviceName: "EC25 4G")
        )
    }

    // MARK: - Service name uniquing

    func testPlanAvoidsCollidingServiceName() {
        let existing = [service("EC25 4G", bsdName: "en0")]
        XCTAssertEqual(
            ModemNetworkPlan.servicePlan(nic: nic, services: existing, preferredName: "EC25 4G"),
            .create(bsdName: "en7", serviceName: "EC25 4G 2")
        )
    }

    func testUniqueServiceNameSkipsTakenSuffixes() {
        XCTAssertEqual(
            ModemNetworkPlan.uniqueServiceName(
                preferred: "EC25 4G",
                existingNames: ["EC25 4G", "EC25 4G 2"]
            ),
            "EC25 4G 3"
        )
        XCTAssertEqual(
            ModemNetworkPlan.uniqueServiceName(preferred: "EC25 4G", existingNames: []),
            "EC25 4G"
        )
        XCTAssertEqual(
            ModemNetworkPlan.uniqueServiceName(preferred: "", existingNames: ["EC25 4G"]),
            ""
        )
    }

    // MARK: - NIC matching helpers

    func testVendorMatching() {
        XCTAssertTrue(ModemNICMatcher.isModuleVendor(0x2c7c))
        XCTAssertTrue(ModemNICMatcher.isModuleVendor(0x2ca3))
        XCTAssertFalse(ModemNICMatcher.isModuleVendor(0x05ac))
        XCTAssertTrue(ModemNICMatcher.isModuleVendor(0x1234, vendorID: 0x1234))
        XCTAssertTrue(ModemNICMatcher.isSupportedIdentity(usbVID: 0x2c7c, usbPID: 0x0125))
        XCTAssertTrue(ModemNICMatcher.isSupportedIdentity(usbVID: 0x2ca3, usbPID: 0x4006))
        XCTAssertFalse(ModemNICMatcher.isSupportedIdentity(usbVID: 0x2ca3, usbPID: 0x0125))
    }

    func testMACFormatting() {
        XCTAssertEqual(
            ModemNICMatcher.formatMAC([0x0A, 0x1B, 0x2C, 0x3D, 0x4E, 0x5F]),
            "0a:1b:2c:3d:4e:5f"
        )
        XCTAssertNil(ModemNICMatcher.formatMAC([0x00, 0x01, 0x02]))
        XCTAssertNil(ModemNICMatcher.formatMAC([]))
    }

    func testUSBIdentityFormatting() {
        XCTAssertEqual(nic.usbIdentity, "2c7c:0125")
        XCTAssertEqual(
            ModemNICInfo(usbVID: 0x2c7c, usbPID: 0x0800, bsdName: "en5", macAddress: "").usbIdentity,
            "2c7c:0800"
        )
    }

    // MARK: - Service snapshot semantics

    func testServiceDHCPSemantics() {
        XCTAssertTrue(service("a", bsdName: "en7").usesDHCP)
        XCTAssertFalse(service("a", bsdName: "en7", ipv4: nil).usesDHCP)
        XCTAssertFalse(service("a", bsdName: "en7", ipv4: "Manual").usesDHCP)
    }

    func testStatusDedicatedServicePresence() {
        XCTAssertFalse(ModemNetworkStatus(nic: nil, service: nil).hasDedicatedService)
        let bound = service("EC25 4G", bsdName: "en7")
        XCTAssertTrue(ModemNetworkStatus(nic: nic, service: bound).hasDedicatedService)
        XCTAssertFalse(ModemNetworkStatus(nic: nic, service: nil).hasDedicatedService)
    }
}
