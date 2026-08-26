import AppKit
import SwiftUI

/// Shared font choices for the compact menu-bar panel.
enum PanelTypography {
    static let metricLabel = Font.caption.weight(.semibold)
    static let metricValue = Font.callout.weight(.semibold)
    static let rowLabel = Font.subheadline
    static let technicalValue = Font.subheadline.weight(.medium).monospaced()
    static let compactTechnicalValue = Font.caption.weight(.medium).monospaced()
    static let secondary = Font.caption
    static let control = Font.body
}

/// Dynamic system control colors shared by custom surfaces and native controls.
/// Reading AppKit's semantic accent avoids inheriting a sampled glass tint from
/// a containing TabView while still following the user's macOS accent choice.
enum AppControlPalette {
    static var accent: Color { Color(nsColor: .controlAccentColor) }
}

/// Top-level panel sections.
enum PanelTab: String, CaseIterable, Identifiable {
    case overview
    case phone
    case sms
    case gnss
    case network
    case estk
    case vowifi
    case terminal
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: localized("nav.overview")
        case .phone: localized("nav.phone")
        case .sms: localized("nav.sms")
        case .gnss: localized("nav.gnss")
        case .network: localized("nav.network")
        case .estk: localized("nav.estk")
        case .vowifi: localized("nav.vowifi")
        case .terminal: localized("nav.terminal")
        case .settings: localized("nav.settings")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "antenna.radiowaves.left.and.right"
        case .phone: "phone"
        case .sms: "message"
        case .gnss: "location"
        case .network: "network"
        case .estk: "simcard.2"
        case .vowifi: SFSymbolAvailability.resolvedName(
            preferred: "phone.badge.waveform",
            fallback: "wifi"
        )
        case .terminal: "terminal"
        case .settings: "gearshape"
        }
    }

}

/// Resolves SF Symbol names against the current SDK with a semantic fallback
/// (R19 spec §3.3): `wifi.badge.shield` resolves to nil on the current SDK,
/// so names that carry meaning but may not exist everywhere go through this
/// check. Results are cached behind a lock — the lookup runs on every sidebar
/// and tab-render pass.
enum SFSymbolAvailability {
    private static let cache = SymbolNameCache()

    private final class SymbolNameCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func resolvedName(preferred: String, fallback: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[preferred] { return cached }
            let resolved = NSImage(
                systemSymbolName: preferred,
                accessibilityDescription: nil
            ) != nil ? preferred : fallback
            storage[preferred] = resolved
            return resolved
        }
    }

    static func resolvedName(preferred: String, fallback: String) -> String {
        cache.resolvedName(preferred: preferred, fallback: fallback)
    }
}

/// Root for the menu-bar popover. The popover uses a native top-level
/// `TabView`; the standalone window has its own
/// system-settings shell in `SystemSettingsWindowView` (R15), so the two
/// surfaces navigate the way their size class expects while sharing one tab
/// model with independent selection values.
///
/// Every main tab is always offered on every surface (R10): capability,
/// connection, SIM, GNSS and NIC states are explained inside the page, never
/// by hiding navigation entries.
struct StatusWindowView: View {
    @EnvironmentObject private var store: ModemStore
    @EnvironmentObject private var coordinator: ModemSessionCoordinator
    @EnvironmentObject private var presentation: WindowPresentationModel

    var body: some View {
        popoverLayout
            // Recreate the SwiftUI subtree when the user changes language so
            // every native tab title updates in the same transaction.
            .id(store.settings.preferredLanguage ?? "")
            // NSPopover owns the menu-bar panel width. Keep the SwiftUI root
            // free of a second popover-width constraint so there is one source
            // of truth.
            .environment(\.presentationSurface, .popover)
    }

    /// Popover root (R17): while a call is live the takeover surface is the
    /// only content — no AppChrome, TabView, or page content is laid out.
    /// Terminal phases restore the tab the user was on; closing the popover
    /// never rejects or hangs up. The popover's outer canvas is fixed
    /// (640×700, clamped once pre-show) and owned solely by AppKit; the root
    /// just fills the hosting view's frame, so no content-driven resize path
    /// exists here — the generation only tags first-frame signposts.
    private var popoverLayout: some View {
        let generation = presentation.popoverPresentationGeneration
        return Group {
            if let liveSession = coordinator.focusedLiveSession {
                CallTakeoverView(placement: .popoverRoot)
                    .environmentObject(liveSession.store)
            } else {
                PopoverPanelShell(selection: $presentation.popoverSelectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // R17 fixed canvas: the root unconditionally claims the hosting
        // view's full bounds instead of proposing its own intrinsic size, so
        // both the tabs tree and the call takeover fill the same 640×700
        // canvas and content only ever scrolls internally.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .onAppear {
            PresentationSignpost.swiftuiFirstFrame(generation: generation)
        }
        .onChange(of: presentation.popoverPresentationGeneration) { _, newGeneration in
            // The hosted subtree observed the new presentation generation —
            // its first committed frame for this popover presentation.
            PresentationSignpost.swiftuiFirstFrame(generation: newGeneration)
        }
    }

}

/// Three-layer popover composition: global chrome, primary tabs, then the
/// selected page workspace. Keeping `AppChrome` outside the `TabView` prevents
/// SwiftUI from merging the tab bar into the titlebar divider. Page-owned
/// sidebars and detail panes therefore begin below the tab strip instead of
/// extending behind either global navigation layer.
private struct PopoverPanelShell: View {
    @Binding var selection: PanelTab

    var body: some View {
        VStack(spacing: 0) {
            AppChrome()
            PopoverPanelTabView(selection: $selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Status tint used by the popover chrome.
extension ModemState {
    var panelStatusColor: Color {
        connected || busy || refreshing ? .accentColor : .secondary
    }
}

/// Popover-only header area containing device status and panel actions; the
/// standalone window keeps its status and global refresh in the sidebar.
struct AppChrome: View {
    @EnvironmentObject private var store: ModemStore
    @EnvironmentObject private var coordinator: ModemSessionCoordinator
    @EnvironmentObject private var presentation: WindowPresentationModel

    var body: some View {
        HStack(spacing: 10) {
            if coordinator.sessions.count > 1 {
                Menu {
                    ForEach(coordinator.sessions) { session in
                        Button {
                            coordinator.selectDevice(session.id)
                        } label: {
                            Label(
                                coordinator.notificationName(for: session.id),
                                systemImage: session.store.state.connected
                                    ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }
                } label: {
                    deviceIdentity
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(localized("module.switch.help"))
            } else {
                deviceIdentity
            }

            Spacer(minLength: 8)

            if store.state.gnss.phase != .off {
                GNSSMenuBarChip(phase: store.state.gnss.phase)
            }

            StatusLabel(text: store.statusText, color: store.state.panelStatusColor)

            Button {
                presentation.togglePopoverPinned()
            } label: {
                Image(systemName: presentation.isPopoverPinned ? "pin.slash" : "pin")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(localized(
                presentation.isPopoverPinned ? "action.unpin_popover" : "action.pin_popover"
            ))

            Button {
                presentation.openStandaloneWindow()
            } label: {
                Image(systemName: "macwindow")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(localized("action.open_standalone_window"))

            Button {
                store.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, value: store.state.refreshing)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(localized("action.refresh_status"))
            .disabled(store.state.busy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var deviceIdentity: some View {
        HStack(spacing: 8) {
            Image(systemName: store.state.remoteManagement.mode == .remote
                ? "network.badge.shield.half.filled"
                : "antenna.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(store.moduleDisplayName)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Text(localized(store.state.remoteManagement.mode.localizationKey))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(store.state.connected ? store.state.usbDescription : localized("device.waiting"))
                    .font(store.state.connected ? .caption.monospaced() : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(localizedFormat(
                        "common.full_value_help",
                        store.state.connected ? store.state.usbDescription : localized("device.waiting")
                    ))
            }
        }
        .contentShape(Rectangle())
    }
}

/// Native top-level navigation for the menu-bar popover. The tab-bar-only
/// style opts into the current SwiftUI tab-bar presentation and automatic
/// Liquid Glass treatment; each tab keeps the full localized title and the
/// binding remains scoped to the popover presentation model.
struct PopoverPanelTabView: View {
    @Binding var selection: PanelTab

    var body: some View {
        TabView(selection: $selection) {
            ForEach(PanelTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    PanelContent(selectedTab: tab)
                        // The information workspace is the third popover
                        // layer. Do not extend its left rail, backgrounds, or
                        // separators behind the native tab strip above it.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .accessibilityLabel(localized("nav.view"))
        .help(selection.title)
    }
}

/// Selected panel page content.
struct PanelContent: View {
    var selectedTab: PanelTab

    var body: some View {
        switch selectedTab {
        case .overview:
            OverviewView()
        case .phone:
            PhoneView()
        case .sms:
            SMSView()
        case .gnss:
            GNSSView()
        case .network:
            NetworkView()
        case .estk:
            ESTKView()
        case .vowifi:
            VoWiFiView()
        case .terminal:
            TerminalView()
        case .settings:
            SettingsView()
        }
    }
}
