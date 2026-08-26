import SwiftUI

/// Standalone window root. The native split restores detail-scoped titlebar
/// geometry and system material while equal min/ideal/max constraints keep the
/// primary sidebar at one non-resizable width on every launch.
struct SystemSettingsWindowView: View {
    @EnvironmentObject private var store: ModemStore
    @EnvironmentObject private var presentation: WindowPresentationModel

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            AppSidebar(selection: $presentation.windowSelectedTab)
                .navigationSplitViewColumnWidth(
                    min: AppSidebar.fixedColumnWidth,
                    ideal: AppSidebar.fixedColumnWidth,
                    max: AppSidebar.fixedColumnWidth
                )
        } detail: {
            StandaloneDetailColumn(selectedTab: presentation.windowSelectedTab)
            }
            .navigationSplitViewStyle(.balanced)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Full-size content only enlarges the AppKit content view; SwiftUI
            // still keeps interactive sidebar controls below the titlebar safe
            // area. Extend only the sidebar material behind that safe area so
            // the traffic lights sit on the same continuous sidebar surface.
            .background(alignment: .leading) {
                Rectangle()
                    .fill(.regularMaterial)
                    .frame(width: AppSidebar.fixedColumnWidth)
                    .ignoresSafeArea(.container, edges: .top)
                    .accessibilityHidden(true)
            }
            // Keep the standard traffic lights and drag region while allowing
            // sidebar/detail material and scrolling content to show beneath a
            // completely transparent unified titlebar.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // The primary sidebar is a permanent part of the window shell.
            // Remove SwiftUI's automatic titlebar toggle; the constant
            // visibility binding also rejects menu, shortcut, and responder-
            // chain attempts to collapse it.
            .toolbar(removing: .sidebarToggle)
            // Searches belong to the selected page below its peer-category
            // tabs, never beside those tabs in the window title bar.
            .environment(\.prefersInlineSearch, true)
            .environment(\.presentationSurface, .standaloneWindow)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            // Native controls cache localized titles; recreate the hosted
            // subtree on language change so navigation chrome and pages update together.
            .id(store.settings.preferredLanguage ?? "")
    }
}

/// Each categorized page owns its secondary TabView in the Detail column's
/// titlebar geometry. Single-page destinations still receive a one-item
/// native tab-bar-only TabView so every destination preserves the same
/// Liquid Glass navigation baseline.
private struct StandaloneDetailColumn: View {
    var selectedTab: PanelTab

    @ViewBuilder
    var body: some View {
        switch selectedTab {
        case .sms, .terminal:
            TabView(selection: .constant(selectedTab)) {
                Tab(selectedTab.title, systemImage: selectedTab.systemImage, value: selectedTab) {
                    PanelContent(selectedTab: selectedTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .tabViewStyle(.tabBarOnly)
        default:
            PanelContent(selectedTab: selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
