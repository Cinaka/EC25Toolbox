import XCTest
@testable import EC25Toolbox

/// R2 visibility coordinator: the banner is suppressed only while an operable
/// call surface is actually on screen and the call still rings or connects.
@MainActor
final class CallVisibilityTests: XCTestCase {
    func testSuppressedOnlyWhileSurfaceVisibleAndRinging() {
        let model = WindowPresentationModel()
        XCTAssertFalse(model.isCallSurfaceVisible)

        model.setPopoverShown(true, callPhase: .incoming)
        XCTAssertTrue(model.isCallSurfaceVisible)

        // The call connected or ended: no surface, banner path returns.
        model.recomputeCallSurfaceVisible(callPhase: .active)
        XCTAssertFalse(model.isCallSurfaceVisible)
        model.recomputeCallSurfaceVisible(callPhase: .idle)
        XCTAssertFalse(model.isCallSurfaceVisible)

        // Answering still counts as an operable surface.
        model.recomputeCallSurfaceVisible(callPhase: .answering)
        XCTAssertTrue(model.isCallSurfaceVisible)

        // Either presentation alone keeps the surface operable.
        model.setStandaloneWindowVisible(true, callPhase: .incoming)
        XCTAssertTrue(model.isCallSurfaceVisible)
        model.setPopoverShown(false, callPhase: .incoming)
        XCTAssertTrue(model.isCallSurfaceVisible)

        model.setStandaloneWindowVisible(false, callPhase: .incoming)
        XCTAssertFalse(model.isCallSurfaceVisible)
    }

    func testNoCallsLeaveSurfaceHidden() {
        let model = WindowPresentationModel()
        model.setPopoverShown(true, callPhase: .idle)
        model.setStandaloneWindowVisible(true, callPhase: .idle)
        XCTAssertFalse(model.isCallSurfaceVisible)
    }
}

/// Raw `UNAuthorizationStatus` values map onto the models-layer enum.
final class NotificationAuthorizationStateTests: XCTestCase {
    func testMapsRawStatusValues() {
        XCTAssertEqual(NotificationAuthorizationState(status: 0), .notDetermined)
        XCTAssertEqual(NotificationAuthorizationState(status: 1), .denied)
        XCTAssertEqual(NotificationAuthorizationState(status: 2), .authorized)
        XCTAssertEqual(NotificationAuthorizationState(status: 3), .provisional)
        // Unknown future values degrade to notDetermined, never crash.
        XCTAssertEqual(NotificationAuthorizationState(status: 99), .notDetermined)
    }

    func testLocalizationKeysAreDistinct() {
        let keys = [
            NotificationAuthorizationState.notDetermined.localizationKey,
            NotificationAuthorizationState.denied.localizationKey,
            NotificationAuthorizationState.authorized.localizationKey,
            NotificationAuthorizationState.provisional.localizationKey
        ]
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("settings.notification.status.") })
    }
}
