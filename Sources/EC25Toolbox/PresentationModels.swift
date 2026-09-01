import AppKit
import Combine
import SwiftUI

enum PresentationSurface: Equatable {
    case popover
    case standaloneWindow
}

/// Equatable projection of everything the menu-bar presentation layer
/// derives from coordinator state: the status item, call-surface visibility,
/// and the floating call panel. Unchanged snapshots never re-run that AppKit
/// work, so unrelated store churn (log lines, GNSS ticks) stays free.
struct PresentationSnapshot: Equatable {
    /// Module identity backing the status item (selected store, or the first
    /// connected session when the selected one is offline). Literal twin of
    /// `ModemSessionCoordinator.fallbackDeviceID`; the static is
    /// MainActor-isolated and cannot seed a nonisolated struct default.
    var statusModuleID = "default"
    var statusConnected = false
    var statusSignalBars = 0
    var statusAccessibilityLabel = ""
    /// Any non-off GNSS phase adds the GNSS line to the status-item tooltip.
    var statusHasGNSSActivity = false
    var connectedCount = 0
    var unreadCount = 0
    var missedCallCount = 0
    var hasIncomingCall = false
    /// Ordered live-call session IDs; empty means no floating call panel.
    var liveSessionIDs: [String] = []
}

@MainActor
final class WindowPresentationModel: ObservableObject {
    @Published private(set) var isPopoverPinned = false
    @Published var popoverSelectedTab: PanelTab = .overview
    @Published var windowSelectedTab: PanelTab = .overview
    @Published var pendingDialNumber: String?
    @Published var pendingSMSRecipient: String?
    @Published var pendingCategoryRoute: SidebarCategoryRoute?
    var onPopoverPinnedChange: ((Bool) -> Void)?
    var onOpenStandaloneWindow: (() -> Void)?
    @Published private(set) var popoverPresentationGeneration = 0
    @Published private(set) var isCallSurfaceVisible = false
    private(set) var popoverShown = false
    private(set) var standaloneWindowVisible = false

    func setPopoverShown(_ shown: Bool, callPhase: CallPhase) {
        guard popoverShown != shown else { return }
        popoverShown = shown
        recomputeCallSurfaceVisible(callPhase: callPhase)
    }

    func setPopoverShown(_ shown: Bool, hasIncomingCall: Bool) {
        guard popoverShown != shown else { return }
        popoverShown = shown
        recomputeCallSurfaceVisible(hasIncomingCall: hasIncomingCall)
    }

    func setStandaloneWindowVisible(_ visible: Bool, callPhase: CallPhase) {
        guard standaloneWindowVisible != visible else { return }
        standaloneWindowVisible = visible
        recomputeCallSurfaceVisible(callPhase: callPhase)
    }

    func setStandaloneWindowVisible(_ visible: Bool, hasIncomingCall: Bool) {
        guard standaloneWindowVisible != visible else { return }
        standaloneWindowVisible = visible
        recomputeCallSurfaceVisible(hasIncomingCall: hasIncomingCall)
    }

    func recomputeCallSurfaceVisible(callPhase: CallPhase) {
        let ringing = callPhase == .incoming || callPhase == .answering
        isCallSurfaceVisible = (popoverShown || standaloneWindowVisible) && ringing
    }

    func recomputeCallSurfaceVisible(hasIncomingCall: Bool) {
        isCallSurfaceVisible = (popoverShown || standaloneWindowVisible) && hasIncomingCall
    }

    var hasVisiblePresentation: Bool {
        popoverShown || standaloneWindowVisible
    }

    var isPopoverVisible: Bool { popoverShown }

    var isStandaloneWindowVisible: Bool { standaloneWindowVisible }

    var isSMSSurfaceVisible: Bool {
        (popoverShown && popoverSelectedTab == .sms)
            || (standaloneWindowVisible && windowSelectedTab == .sms)
    }

    func select(_ tab: PanelTab, on surface: PresentationSurface) {
        switch surface {
        case .popover: popoverSelectedTab = tab
        case .standaloneWindow: windowSelectedTab = tab
        }
    }

    func togglePopoverPinned() {
        isPopoverPinned.toggle()
        onPopoverPinnedChange?(isPopoverPinned)
    }

    func openStandaloneWindow() { onOpenStandaloneWindow?() }

    func beginPopoverPresentation() {
        popoverPresentationGeneration += 1
    }
}

@MainActor
enum PresentationHostingFactory {
    static func makeController(
        surface: PresentationSurface,
        coordinator: ModemSessionCoordinator,
        contactStore: ContactStore,
        presentation: WindowPresentationModel
    ) -> NSViewController {
        let rootView = AnyView(
            DeviceScopedPresentationRoot(surface: surface)
                .environmentObject(coordinator)
                .environmentObject(contactStore)
                .environmentObject(presentation)
        )

        switch surface {
        case .popover:
            return PopoverMaterialHostingController(rootView: rootView)
        case .standaloneWindow:
            let controller = NSHostingController(rootView: rootView)
            controller.view.wantsLayer = true
            controller.view.layer?.backgroundColor = NSColor.clear.cgColor
            return controller
        }
    }

    /// Backward-compatible hosting seam for focused presentation tests.
    static func makeController(
        surface: PresentationSurface,
        store: ModemStore,
        contactStore: ContactStore,
        presentation: WindowPresentationModel
    ) -> NSViewController {
        makeController(
            surface: surface,
            coordinator: ModemSessionCoordinator(singleStore: store),
            contactStore: contactStore,
            presentation: presentation
        )
    }
}

/// Injects only the currently selected module into ordinary feature pages.
/// Switching modules rebuilds the presentation subtree, while every other
/// module store continues polling and receiving URCs in the coordinator.
private struct DeviceScopedPresentationRoot: View {
    var surface: PresentationSurface
    @EnvironmentObject private var coordinator: ModemSessionCoordinator

    var body: some View {
        Group {
            switch surface {
            case .popover:
                StatusWindowView()
            case .standaloneWindow:
                SystemSettingsWindowView()
            }
        }
        .environmentObject(coordinator.selectedStore)
        .environmentObject(coordinator.selectedStore.smsConversations)
        .id(coordinator.selectedDeviceID)
    }
}

@MainActor
enum PopoverCanvasSync {
    /// Replaces the transient SwiftUI tree before each presentation. Durable
    /// state lives in the injected stores, while stale safe-area/scroll
    /// geometry from the previously selected tab is deliberately discarded.
    @discardableResult
    static func install(
        _ controller: NSViewController,
        size: NSSize,
        on popover: NSPopover
    ) -> NSViewController {
        popover.contentViewController = controller
        apply(size, to: popover)
        return controller
    }

    static func apply(_ size: NSSize, to popover: NSPopover) {
        popover.contentSize = size
        popover.contentViewController?.preferredContentSize = size
        guard let view = popover.contentViewController?.view else { return }
        // AppKit may preserve a non-zero bounds origin while reusing the
        // popover window. Reassert both frame and bounds before every show;
        // resetting only the frame leaves the SwiftUI canvas visibly shifted.
        view.frame = CGRect(origin: .zero, size: size)
        view.bounds = CGRect(origin: .zero, size: size)
        view.needsLayout = true
    }
}
