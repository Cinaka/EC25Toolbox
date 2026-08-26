import AppKit
import SwiftUI

/// `NSPopover` owns one continuous system backdrop for both its arrow and body,
/// while SwiftUI continues to own all navigation and feature state. Keeping the
/// hosting view transparent avoids double-compositing a second popover material
/// over only the rectangular content area.
@MainActor
final class PopoverMaterialHostingController: NSViewController {
    let hostingView: PopoverVibrantHostingView

    init(rootView: AnyView) {
        hostingView = PopoverVibrantHostingView(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = hostingView
    }
}

/// CodexBar applies the same opt-in to its SwiftUI-hosted menu rows. Without
/// it, semantic foreground and control colors are composited as ordinary
/// opaque content and can lose contrast on a highly translucent backdrop.
@MainActor
final class PopoverVibrantHostingView: NSHostingView<AnyView> {
    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { true }
}
