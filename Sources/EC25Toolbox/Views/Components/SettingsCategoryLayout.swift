import SwiftUI

/// Metadata the shared category layout derives its navigation from, so one
/// composition serves every categorized page on both surfaces.
protocol SettingsCategoryItem: Hashable, Identifiable {
    /// Stable raw value used by sidebar-search deep links.
    var rawValue: String { get }
    /// Localization key of the category title.
    var title: String { get }
    /// Optional shorter label used only by the standalone window's top tab
    /// strip. Full titles remain available to page headers and search.
    var tabTitle: String { get }
    /// Localization key of the one-line description shown on landing rows.
    var description: String { get }
    /// SF Symbol name shown in the navigation rail and pickers.
    var systemImage: String { get }
}

extension SettingsCategoryItem {
    var tabTitle: String { title }
}

/// Shared category-detail composition for categorized feature pages.
///
/// The popover keeps the large-icon left rail its compact width expects. The
/// standalone window keeps peer categories in a native Liquid Glass `TabView`
/// inside the right detail column above the workspace. Switching a primary
/// sidebar item never auto-pushes a secondary page or requires a Back action
/// to reach the other categories.
struct SettingsCategoryLayout<Category: SettingsCategoryItem, Header: View, Content: View>: View {
    var categories: [Category]
    /// Tab whose page this layout composes. Scopes sidebar-search deep links
    /// so identical category raw values on different pages cannot collide.
    var owningTab: PanelTab
    @Binding var selection: Category
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    @Environment(\.presentationSurface) private var surface
    @EnvironmentObject private var presentation: WindowPresentationModel

    init(
        categories: [Category],
        owningTab: PanelTab,
        selection: Binding<Category>,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.categories = categories
        self.owningTab = owningTab
        self._selection = selection
        self.header = header()
        self.content = content()
    }

    var body: some View {
        Group {
            switch surface {
            case .popover:
                popoverBody
            case .standaloneWindow:
                windowBody
            }
        }
        .onChange(of: presentation.pendingCategoryRoute, initial: false) { _, route in
            guard let route, route.tab == owningTab,
                  let match = categories.first(where: { $0.rawValue == route.category })
            else { return }
            presentation.pendingCategoryRoute = nil
            selection = match
        }
    }

    private var popoverBody: some View {
        GeometryReader { geometry in
            let compactSidebar = geometry.size.width < 680

            HStack(spacing: 0) {
                rail(compact: compactSidebar)
                    .frame(width: compactSidebar ? 62 : 185)

                Divider().opacity(0.55)

                detail(spacing: compactSidebar ? 14 : 18, padding: compactSidebar ? 14 : 18, maxWidth: nil)
            }
        }
    }

    /// Window workspace: peer categories are real tabs rather than a
    /// segmented Picker. The tab-bar-only style supplies the current native
    /// Liquid Glass capsule while the enclosing NavigationSplitView scopes its
    /// titlebar geometry to the right-hand detail column.
    private var windowBody: some View {
        TabView(selection: $selection) {
            ForEach(categories) { category in
                Tab(
                    localized(category.tabTitle),
                    systemImage: category.systemImage,
                    value: category
                ) {
                    windowDetail
                        // The native TabView owns the top safe-area inset. Do
                        // not opt its page out or the first information surface
                        // will be laid out underneath the tab strip.
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Selected peer category workspace, centered at a readable width.
    private var windowDetail: some View {
        // Keep a compact but positive separation below the native capsule.
        // Negative offsets place the first section under the tab's hit region
        // on some window/safe-area geometries and cause visible text overlap.
        detail(spacing: 10, padding: 24, topPadding: 12, maxWidth: 860)
    }

    /// Left category rail for the popover surface.
    private func rail(compact: Bool) -> some View {
        ScrollView {
            VStack(spacing: 5) {
                ForEach(categories) { category in
                    SettingsSidebarButton(
                        title: category.title,
                        systemImage: category.systemImage,
                        isSelected: selection == category,
                        compact: compact
                    ) {
                        selection = category
                    }
                }
            }
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, 10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }

    private func detail(
        spacing: CGFloat,
        padding: CGFloat,
        topPadding: CGFloat = 10,
        maxWidth: CGFloat?
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                header
                content
            }
            .padding(.horizontal, padding)
            .padding(.top, topPadding)
            .padding(.bottom, padding)
            .frame(maxWidth: maxWidth ?? .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }
}

/// Responsive category button shared by Settings-style sidebars.
private struct SettingsSidebarButton: View {
    var title: String
    var systemImage: String
    var isSelected: Bool
    var compact: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if compact {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 48, height: 48, alignment: .center)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 24, height: 24)
                    Text(localized(title))
                        .font(.body)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 42)
            }
        }
        .buttonStyle(.plain)
        // Use the system's semantic source-list selection colors instead of
        // the raw accent color inherited through TabView. The latter becomes
        // overly bright when sampled by Liquid Glass in dark appearance.
        .foregroundStyle(
            isSelected
                ? Color(nsColor: .alternateSelectedControlTextColor)
                : Color.primary.opacity(0.78)
        )
        .background(
            isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .help(localized(title))
        .accessibilityLabel(localized(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
