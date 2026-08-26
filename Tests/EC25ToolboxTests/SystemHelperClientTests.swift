@testable import EC25Toolbox
import ServiceManagement
import XCTest

final class SystemHelperClientTests: XCTestCase {
    // MARK: - SMAppService.Status mapping

    func testAvailabilityMapping() {
        XCTAssertEqual(SystemHelperAvailability(.enabled), .enabled)
        XCTAssertEqual(SystemHelperAvailability(.requiresApproval), .requiresApproval)
        XCTAssertEqual(SystemHelperAvailability(.notRegistered), .notRegistered)
        XCTAssertEqual(SystemHelperAvailability(.notFound), .plistMissing)
    }

    // MARK: - Migration plan matrix

    func testEnabledSystemHelperWinsRegardlessOfLegacy() {
        XCTAssertEqual(
            SystemHelperMigrationPlan.action(system: .enabled, legacyInstalled: true),
            .useSystemHelper
        )
        XCTAssertEqual(
            SystemHelperMigrationPlan.action(system: .enabled, legacyInstalled: false),
            .useSystemHelper
        )
    }

    func testApprovalGateBeatsRegistrationAndLegacy() {
        XCTAssertEqual(
            SystemHelperMigrationPlan.action(system: .requiresApproval, legacyInstalled: true),
            .promptApproval
        )
        XCTAssertEqual(
            SystemHelperMigrationPlan.action(system: .requiresApproval, legacyInstalled: false),
            .promptApproval
        )
    }

    func testNotRegisteredRequestsRegistration() {
        XCTAssertEqual(
            SystemHelperMigrationPlan.action(system: .notRegistered, legacyInstalled: true),
            .register
        )
    }

    func testUnavailableSystemHelperFallsBackOnlyWhenLegacyExists() {
        for availability in [SystemHelperAvailability.plistMissing, .registrationFailed] {
            XCTAssertEqual(
                SystemHelperMigrationPlan.action(system: availability, legacyInstalled: true),
                .useLegacyFallback
            )
            XCTAssertEqual(
                SystemHelperMigrationPlan.action(system: availability, legacyInstalled: false),
                .unavailable
            )
        }
    }

    // MARK: - Error surface

    func testSystemHelperErrorEquatable() {
        XCTAssertEqual(SystemHelperError.approvalRequired, .approvalRequired)
        XCTAssertEqual(SystemHelperError.helperRejected("x"), .helperRejected("x"))
        XCTAssertNotEqual(SystemHelperError.unavailable("a"), .unavailable("b"))
    }
}
