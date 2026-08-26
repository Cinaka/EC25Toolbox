import AppKit
import SwiftUI

/// Narrow AppKit owner for the always-available call operation panel. SwiftUI
/// remains the source of truth for call state and actions; AppKit only owns
/// the non-activating floating window lifecycle and screen placement.
@MainActor
final class CallNotificationPanelController {
    private static let panelSize = NSSize(width: 408, height: 164)

    private let coordinator: ModemSessionCoordinator
    private var panel: CallOperationPanel?

    init(coordinator: ModemSessionCoordinator) {
        self.coordinator = coordinator
    }

    func synchronize(on screen: NSScreen?) {
        guard coordinator.focusedLiveSession != nil else {
            panel?.orderOut(nil)
            return
        }

        let panel = panel ?? makePanel()
        guard !panel.isVisible else { return }
        position(panel, on: screen ?? NSScreen.main)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    func isPresenting(deviceID: String) -> Bool {
        panel?.isVisible == true && coordinator.focusedLiveSession?.id == deviceID
    }

    private func makePanel() -> CallOperationPanel {
        let root = AnyView(
            CallNotificationPanelRoot()
                .environmentObject(coordinator)
        )
        let panel = CallOperationPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: root)
        panel.title = localized("call.panel.title")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let margin: CGFloat = 18
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - Self.panelSize.width - margin,
            y: visibleFrame.maxY - Self.panelSize.height - margin
        ))
    }
}

private final class CallOperationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Selects the currently focused live module without duplicating call state
/// in the panel controller. Multiple-module routing remains coordinator-owned.
private struct CallNotificationPanelRoot: View {
    @EnvironmentObject private var coordinator: ModemSessionCoordinator

    var body: some View {
        Group {
            if let session = coordinator.focusedLiveSession {
                CallTakeoverView(placement: .notificationPanel)
                    .environmentObject(session.store)
                    .id("\(session.id)-\(session.store.state.call.epoch)")
            }
        }
        .frame(width: 408, height: 164)
    }
}
