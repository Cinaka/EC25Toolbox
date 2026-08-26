import Foundation

/// Shared gate for all `UNUserNotificationCenter` access.
enum AppNotificationCenter {
    /// `UNUserNotificationCenter.current()` raises an Objective-C exception
    /// (not a Swift error) when the process has no app-bundle proxy, e.g.
    /// under xctest or a SwiftPM CLI binary. Every notification entry point
    /// must check this before touching the center.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
