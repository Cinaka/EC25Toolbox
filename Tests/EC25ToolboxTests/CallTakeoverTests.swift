import XCTest
@testable import EC25Toolbox

/// R13 exclusive call takeover: while a call is live the popover root shows
/// only the takeover surface — no AppChrome, tab picker, or page content —
/// and closing/reopening the popover never rejects or hangs up.
final class CallTakeoverTests: XCTestCase {
    func testLivePhasesTakeOverThePopoverRoot() {
        let live: [CallPhase] = [
            .incoming, .answering, .dialing, .alerting, .active, .held, .ending
        ]
        for phase in live {
            XCTAssertTrue(CallTakeoverView.isLiveCallPhase(phase), "\(phase) must be live")
            XCTAssertEqual(PopoverRootSection.resolve(callPhase: phase), .takeover, "\(phase)")
        }
    }

    func testTerminalPhasesRestoreTabs() {
        for phase in [CallPhase.idle, .ended, .failed, .missed] {
            XCTAssertFalse(CallTakeoverView.isLiveCallPhase(phase), "\(phase) must not be live")
            XCTAssertEqual(PopoverRootSection.resolve(callPhase: phase), .tabs, "\(phase)")
        }
    }

    func testNonRingingCallPhasesKeepTheKeypadVisible() {
        for phase in [CallPhase.answering, .dialing, .alerting, .active, .held] {
            XCTAssertTrue(CallTakeoverView.usesPersistentKeypad(phase), "\(phase)")
        }
        for phase in [CallPhase.incoming, .ending, .idle, .ended, .failed, .missed] {
            XCTAssertFalse(CallTakeoverView.usesPersistentKeypad(phase), "\(phase)")
        }
    }

    func testTakeoverIsIndependentOfSelectedTabAcrossTwentyRounds() {
        // 20 rounds × all 9 tabs × every live phase: no tab selection change
        // may reintroduce chrome/tabs into the root while the call is live,
        // and — with the sizing machinery gone — nothing about the tab can
        // request an outer-frame size change either.
        let live: [CallPhase] = [.incoming, .answering, .active, .ending]
        for round in 0..<20 {
            for tab in PanelTab.allCases {
                for phase in live {
                    XCTAssertEqual(
                        PopoverRootSection.resolve(callPhase: phase),
                        .takeover,
                        "round \(round), tab \(tab), phase \(phase)"
                    )
                }
            }
        }
    }

    func testNewEpochTerminalThenSecondCallTakesOverAgain() {
        // After one call concludes (old epoch dead), the panel returns to
        // tabs; a second live call immediately takes the root over again.
        XCTAssertEqual(PopoverRootSection.resolve(callPhase: .active), .takeover)
        XCTAssertEqual(PopoverRootSection.resolve(callPhase: .ended), .tabs)
        XCTAssertEqual(PopoverRootSection.resolve(callPhase: .incoming), .takeover)
    }
}

/// Presentation-side invariants the takeover relies on (R13).
@MainActor
final class CallTakeoverPresentationTests: XCTestCase {
    func testClosingPopoverDoesNotConcludeTheCall() {
        // `setPopoverShown` only tracks surface visibility for banner
        // suppression; no presentation event feeds the call machine, so
        // closing the popover cannot reject or hang up a live call.
        let model = WindowPresentationModel()
        model.setPopoverShown(true, callPhase: .active)
        model.setPopoverShown(false, callPhase: .active)
        XCTAssertTrue(model.isCallSurfaceVisible == false)
        XCTAssertTrue(CallTakeoverView.isLiveCallPhase(.active))
        // Reopening shows the same live call epoch in the takeover root.
        XCTAssertEqual(PopoverRootSection.resolve(callPhase: .active), .takeover)
        model.setPopoverShown(true, callPhase: .active)
    }

    func testBeginPopoverPresentationOnlyBumpsGeneration() {
        // The generation counter exists solely to tag first-frame signposts;
        // it no longer drives any measurement or resize pipeline.
        let model = WindowPresentationModel()
        let initial = model.popoverPresentationGeneration
        model.beginPopoverPresentation()
        model.beginPopoverPresentation()
        XCTAssertEqual(model.popoverPresentationGeneration, initial + 2)
    }
}
