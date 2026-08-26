import AppKit

/// Narrow AppKit bridge for the standalone window's native chrome. It only
/// configures full-size content, the unified titlebar/toolbar, and native
/// window behavior (position restore, fixed size); it renders no custom header
/// or titlebar placeholder. The SwiftUI root owns the exactly constrained
/// native sidebar/detail split, while categorized detail pages place their own
/// native Liquid Glass TabView at the top of the detail workspace.
@MainActor
enum WindowChromeConfigurator {
    static let frameAutosaveName = "EC25ToolboxStandaloneWindow"
    /// Matches the user's accepted System Settings-style canvas. The window
    /// remains movable, but its content geometry must not drift between opens.
    static let fixedSize = NSSize(width: 993, height: 827)

    /// Centers the fixed System Settings-style frame in the visible screen.
    static func defaultFrame(visibleFrame: NSRect) -> NSRect {
        return NSRect(
            x: visibleFrame.midX - fixedSize.width / 2,
            y: visibleFrame.midY - fixedSize.height / 2,
            width: fixedSize.width,
            height: fixedSize.height
        )
    }

    /// Keeps a restored origin on-screen while discarding any previously
    /// persisted size. This makes frame restoration position-only.
    static func fixedFrame(origin: NSPoint, visibleFrame: NSRect) -> NSRect {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - fixedSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - fixedSize.height)
        return NSRect(
            x: min(max(origin.x, visibleFrame.minX), maximumX),
            y: min(max(origin.y, visibleFrame.minY), maximumY),
            width: fixedSize.width,
            height: fixedSize.height
        )
    }

    /// Makes the standalone window with native chrome. The logical window
    /// title is kept for accessibility, the Window menu, and state
    /// restoration, while the duplicate visible title is hidden.
    static func makeWindow(
        contentViewController: NSViewController,
        anchorVisibleFrame: NSRect?,
        restoresFrame: Bool = true
    ) -> NSWindow {
        let visibleFrame = anchorVisibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let window = NSWindow(
            contentRect: defaultFrame(visibleFrame: visibleFrame),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = localized("app.name")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.contentViewController = contentViewController
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = fixedSize
        window.maxSize = fixedSize
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.collectionBehavior = [.participatesInCycle]
        window.tabbingMode = .disallowed
        window.animationBehavior = .documentWindow
        if restoresFrame {
            let restored = window.setFrameUsingName(frameAutosaveName)
            if restored {
                window.setFrame(
                    fixedFrame(origin: window.frame.origin, visibleFrame: visibleFrame),
                    display: false
                )
            } else {
                window.setFrame(defaultFrame(visibleFrame: visibleFrame), display: false)
            }
            window.setFrameAutosaveName(frameAutosaveName)
        }
        return window
    }
}
