import AppKit
import SwiftUI
import XCTest
@testable import EC25Toolbox

/// Popover canvas single ownership: with a real `NSPopover` and the real
/// production hosting controller, flipping through every tab, changing
/// language and appearance, and moving through every call phase must not
/// move the outer AppKit frame. The fixed 640×700 canvas survives all
/// content changes; only the pre-show clamp (or the shrink-only
/// screen-parameter path) may write it.
/// Lock-protected counter: `NotificationCenter` observer closures are
/// Sendable but not MainActor-isolated under Swift 6, so the frame-change
/// tally lives behind a lock instead of mutating test state directly.
private final class FrameChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        count = 0
    }
}

@MainActor
final class PopoverCanvasOwnershipTests: XCTestCase {
    private func makeCanvas() -> (
        popover: NSPopover,
        controller: NSViewController,
        store: ModemStore,
        presentation: WindowPresentationModel
    ) {
        let store = ModemStore()
        let presentation = WindowPresentationModel()
        let controller = PresentationHostingFactory.makeController(
            surface: .popover,
            store: store,
            contactStore: ContactStore(),
            presentation: presentation
        )
        let popover = NSPopover()
        popover.contentViewController = controller
        return (popover, controller, store, presentation)
    }

    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private var fullCanvas: CGSize {
        CGSize(
            width: PanelPresentationSpec.popoverWidth,
            height: PanelPresentationSpec.popoverHeight
        )
    }

    func testPopoverHostingControllerDisablesEveryAutomaticSizingBehavior() {
        // The popover hosting controller must never write SwiftUI's
        // intrinsic/preferred size back into AppKit: NSPopover is the single
        // outer-frame owner (R17).
        let controller = makeCanvas().controller as? PopoverMaterialHostingController
        XCTAssertNotNil(controller)
        XCTAssertTrue(controller?.hostingView.sizingOptions.isEmpty == true)
    }

    func testPopoverHostingControllerUsesSystemPopoverBackdropAndVibrancy() {
        let controller = makeCanvas().controller as? PopoverMaterialHostingController
        XCTAssertNotNil(controller)
        XCTAssertTrue(controller?.view === controller?.hostingView)
        XCTAssertFalse(controller?.view is NSVisualEffectView)
        XCTAssertFalse(controller?.hostingView.isOpaque == true)
        XCTAssertTrue(controller?.hostingView.allowsVibrancy == true)
    }

    func testStandaloneWindowControllerKeepsDefaultSizing() {
        // The window surface keeps AppKit's default hosting sizing — the
        // NSWindow frame autosave owns that geometry instead.
        let controller = PresentationHostingFactory.makeController(
            surface: .standaloneWindow,
            store: ModemStore(),
            contactStore: ContactStore(),
            presentation: WindowPresentationModel()
        )
        let hostingController = controller as? NSHostingController<AnyView>
        XCTAssertNotNil(hostingController)
        XCTAssertFalse(hostingController?.sizingOptions.isEmpty == true)
    }

    func testCanvasSyncRewritesEveryLayerEvenWhenContentSizeAlreadyMatches() {
        // R17 deleted the equality early-exit: a stale preferredContentSize
        // or hosting-view frame must be repaired even when contentSize is
        // already correct.
        let canvas = makeCanvas()
        canvas.popover.contentSize = fullCanvas
        canvas.controller.preferredContentSize = NSSize(width: 2, height: 2)
        canvas.controller.view.frame = CGRect(x: 5, y: 6, width: 3, height: 4)
        canvas.controller.view.bounds = CGRect(x: 7, y: 8, width: 3, height: 4)

        PopoverCanvasSync.apply(fullCanvas, to: canvas.popover)

        XCTAssertEqual(canvas.popover.contentSize, fullCanvas)
        XCTAssertEqual(canvas.controller.preferredContentSize, fullCanvas)
        XCTAssertEqual(
            canvas.controller.view.frame,
            CGRect(origin: .zero, size: fullCanvas)
        )
        XCTAssertEqual(
            canvas.controller.view.bounds,
            CGRect(origin: .zero, size: fullCanvas)
        )
    }

    func testCanvasSyncRepairsDriftedInPopoverContentSize() {
        // A second size owner leaving drift in `contentSize` itself (the
        // R13→R17 regression shape) is also repaired by the same sync.
        let canvas = makeCanvas()
        canvas.popover.contentSize = NSSize(width: 1, height: 1)

        PopoverCanvasSync.apply(fullCanvas, to: canvas.popover)

        XCTAssertEqual(canvas.popover.contentSize, fullCanvas)
        XCTAssertEqual(canvas.controller.preferredContentSize, fullCanvas)
        XCTAssertEqual(
            canvas.controller.view.frame,
            CGRect(origin: .zero, size: fullCanvas)
        )
    }

    func testFreshControllerInstallationDropsPreviousHostedGeometry() {
        let canvas = makeCanvas()
        PopoverCanvasSync.apply(fullCanvas, to: canvas.popover)
        canvas.controller.view.bounds.origin = CGPoint(x: 18, y: 27)

        let replacement = PresentationHostingFactory.makeController(
            surface: .popover,
            store: canvas.store,
            contactStore: ContactStore(),
            presentation: canvas.presentation
        )
        PopoverCanvasSync.install(replacement, size: fullCanvas, on: canvas.popover)

        XCTAssertFalse(canvas.popover.contentViewController === canvas.controller)
        XCTAssertTrue(canvas.popover.contentViewController === replacement)
        XCTAssertEqual(replacement.preferredContentSize, fullCanvas)
        XCTAssertEqual(replacement.view.frame, CGRect(origin: .zero, size: fullCanvas))
        XCTAssertEqual(replacement.view.bounds, CGRect(origin: .zero, size: fullCanvas))
    }

    func testTabsLanguageAppearanceAndCallPhasesNeverChangeTheOuterCanvas() {
        let store = ModemStore()
        let presentation = WindowPresentationModel()
        let contactStore = ContactStore()
        let frameChanges = FrameChangeCounter()

        // The popover keeps its own production controller — the canvas
        // invariance of `contentSize`/`preferredContentSize` is asserted on
        // it. A second controller from the same factory shares the stores
        // and is hosted in a real offscreen window for genuine AppKit
        // frame-change observation; one view controller must never have two
        // parents.
        let popover = NSPopover()
        let popoverController = PresentationHostingFactory.makeController(
            surface: .popover,
            store: store,
            contactStore: contactStore,
            presentation: presentation
        )
        popover.contentViewController = popoverController

        let fixed = fullCanvas
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: fixed),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Programmatic NSWindows release themselves on close by default;
        // the test owns the window's lifetime instead.
        window.isReleasedWhenClosed = false
        let observedController = PresentationHostingFactory.makeController(
            surface: .popover,
            store: store,
            contactStore: contactStore,
            presentation: presentation
        )
        window.contentViewController = observedController
        observedController.view.postsFrameChangedNotifications = true
        let frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: observedController.view,
            queue: .main
        ) { [weak frameChanges] note in
            guard note.object is NSView else { return }
            frameChanges?.record()
        }
        defer { NotificationCenter.default.removeObserver(frameObserver) }
        window.orderFrontRegardless()
        // The production sync writes the hosting view frame explicitly (the
        // popover path does the same); a borderless window in the xctest
        // environment does not lay out its content on its own.
        observedController.view.frame = CGRect(origin: .zero, size: fixed)
        observedController.view.layoutSubtreeIfNeeded()
        PopoverCanvasSync.apply(fixed, to: popover)
        pump()
        XCTAssertEqual(popover.contentSize, fixed)
        XCTAssertEqual(
            observedController.view.frame,
            CGRect(origin: .zero, size: fixed)
        )
        // The attach/layout settle belongs to presentation, not to the
        // shown period; the mutation matrix below is what must be quiet.
        frameChanges.reset()

        // All nine tabs.
        for tab in PanelTab.allCases {
            presentation.popoverSelectedTab = tab
            pump()
        }
        // Language rebuild (nil → en → zh-Hans) and appearance changes.
        store.settings.preferredLanguage = "en"
        pump()
        store.settings.preferredLanguage = nil
        pump()
        store.settings.preferredLanguage = "zh-Hans"
        pump()
        store.settings.appearance = AppAppearance.dark.rawValue
        pump()
        store.settings.appearance = nil
        pump()
        // Every call phase — takeover and terminal both.
        let phases: [CallPhase] = [
            .incoming, .answering, .dialing, .alerting, .active, .held,
            .ending, .ended, .failed, .missed, .idle,
        ]
        for phase in phases {
            store.state.call.phase = phase
            pump()
        }

        XCTAssertEqual(
            frameChanges.value,
            0,
            "no tab/language/appearance/call-phase change may move the hosting view frame"
        )
        XCTAssertEqual(popover.contentSize, fixed)
        XCTAssertEqual(popoverController.preferredContentSize, fixed)
        XCTAssertEqual(
            observedController.view.frame,
            CGRect(origin: .zero, size: fixed)
        )
    }
}

/// Fixed popover canvas and native tab presentation rules.
final class PanelPresentationSpecTests: XCTestCase {
    func testFixedLogicalCanvas() {
        XCTAssertEqual(PanelPresentationSpec.popoverWidth, 640)
        XCTAssertEqual(PanelPresentationSpec.popoverHeight, 700)
        XCTAssertEqual(PanelPresentationSpec.screenMargin, 24)
    }

    func testClampKeepsFullCanvasOnScreensThatFit() {
        XCTAssertEqual(
            PanelPresentationSpec.clampedSize(
                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
            ),
            CGSize(width: 640, height: 700)
        )
        XCTAssertEqual(
            PanelPresentationSpec.clampedSize(
                visibleFrame: CGRect(x: 0, y: 0, width: 664, height: 724)
            ),
            CGSize(width: 640, height: 700)
        )
    }

    func testClampLowersEachDimensionIndependently() {
        XCTAssertEqual(
            PanelPresentationSpec.clampedSize(
                visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 900)
            ),
            CGSize(width: 476, height: 700)
        )
        XCTAssertEqual(
            PanelPresentationSpec.clampedSize(
                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 500)
            ),
            CGSize(width: 640, height: 476)
        )
        let fractional = PanelPresentationSpec.clampedSize(
            visibleFrame: CGRect(x: 0, y: 0, width: 320.5, height: 600)
        )
        XCTAssertEqual(fractional.width, 296.5, accuracy: 0.001)
        XCTAssertEqual(fractional.height, 576, accuracy: 0.001)
    }

    func testClampWithoutUsableScreenKeepsFullCanvas() {
        XCTAssertEqual(
            PanelPresentationSpec.clampedSize(visibleFrame: nil),
            CGSize(width: 640, height: 700)
        )
        XCTAssertEqual(
            PanelPresentationSpec.clampedSize(
                visibleFrame: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 900)
            ),
            CGSize(width: 640, height: 700)
        )
        XCTAssertEqual(
            PanelPresentationSpec.clampedSize(
                visibleFrame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 600)
            ),
            CGSize(width: 640, height: 576)
        )
    }

    @MainActor
    func testNativeTabViewReceivesEveryFullEnglishTabTitle() {
        setAppLocale("en")
        defer { setAppLocale("") }

        let titles = PanelTab.allCases.map(\.title)
        XCTAssertEqual(titles.count, 9)
        XCTAssertEqual(Set(titles).count, 9)
        XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })
    }
}

final class StatusItemPresentationTests: XCTestCase {
    func testNoPermanentEventIndicator() {
        XCTAssertEqual(StatusItemPresentation.indicators(for: ModemState()), [])
    }

    func testEveryEventIndicatorSymbolExistsInCurrentSDK() {
        XCTAssertNotNil(NSImage(systemSymbolName: "message.fill", accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: "phone.arrow.down.left.fill", accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil))
    }

    func testUnreadMissedAndIncomingIndicatorsComposeBesideSignal() {
        var state = ModemState()
        state.unreadCount = 4
        state.callLog = [
            CallEvent(title: "phone.call.missed", detail: "13800138000"),
            CallEvent(
                title: "phone.call.missed",
                detail: "13900139000",
                acknowledgedAt: Date()
            ),
        ]
        state.call.phase = .incoming

        XCTAssertEqual(StatusItemPresentation.indicators(for: state), [
            .unreadMessages(4),
            .missedCalls(1),
            .incomingCall,
        ])
    }

    func testAcknowledgedMissedCallsDisappearWithoutHidingUnreadSMS() {
        var state = ModemState()
        state.unreadCount = 2
        state.callLog = [CallEvent(
            title: "phone.call.missed",
            detail: "13800138000",
            acknowledgedAt: Date()
        )]
        XCTAssertEqual(StatusItemPresentation.indicators(for: state), [.unreadMessages(2)])
    }
}

/// Standalone window chrome integrates the split view and toolbar beneath the
/// traffic lights without an app-drawn titlebar layer.
final class WindowChromeTests: XCTestCase {
    @MainActor
    private func makeWindow() -> NSWindow {
        let host = NSViewController()
        host.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        return WindowChromeConfigurator.makeWindow(
            contentViewController: host,
            anchorVisibleFrame: nil,
            restoresFrame: false
        )
    }

    @MainActor
    func testWindowUsesFullSizeContentView() {
        let window = makeWindow()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    }

    @MainActor
    func testWindowHidesDuplicateVisibleTitleButKeepsLogicalTitle() {
        let window = makeWindow()
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertFalse(window.title.isEmpty)
        XCTAssertTrue(window.titlebarAppearsTransparent)
    }

    @MainActor
    func testWindowHasNoTitlebarSeparatorStrip() {
        let window = makeWindow()
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertEqual(window.toolbarStyle, .unified)
    }

    @MainActor
    func testWindowUsesAcceptedFixedSizingBehavior() {
        let window = makeWindow()
        XCTAssertEqual(window.minSize, WindowChromeConfigurator.fixedSize)
        XCTAssertEqual(window.maxSize, WindowChromeConfigurator.fixedSize)
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.standardWindowButton(.zoomButton)?.isEnabled ?? true)
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.isReleasedWhenClosed)
    }

    @MainActor
    func testDefaultFrameUsesFixedSizeAndCenters() {
        let large = WindowChromeConfigurator.defaultFrame(
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        XCTAssertEqual(large.size, WindowChromeConfigurator.fixedSize)
        XCTAssertEqual(large.midX, 960, accuracy: 0.5)
        XCTAssertEqual(large.midY, 540, accuracy: 0.5)
    }

    @MainActor
    func testRestoredFrameKeepsOriginOnScreenButDiscardsOldSize() {
        let visibleFrame = NSRect(x: 40, y: 50, width: 1_920, height: 1_080)
        let frame = WindowChromeConfigurator.fixedFrame(
            origin: NSPoint(x: 5_000, y: -500),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(frame.size, WindowChromeConfigurator.fixedSize)
        XCTAssertEqual(frame.maxX, visibleFrame.maxX, accuracy: 0.5)
        XCTAssertEqual(frame.minY, visibleFrame.minY, accuracy: 0.5)
    }
}
