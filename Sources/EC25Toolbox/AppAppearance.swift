import AppKit

/// User-selectable interface appearance, persisted in `ModemSettings`.
enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .system: "settings.appearance.system"
        case .light: "settings.appearance.light"
        case .dark: "settings.appearance.dark"
        }
    }

    /// The NSAppearance applied to NSApp; nil follows the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Applies the appearance app-wide; the popover and standalone window both
/// inherit NSApp's appearance.
@MainActor
func applyAppAppearance(_ appearance: AppAppearance) {
    NSApp?.appearance = appearance.nsAppearance
}
