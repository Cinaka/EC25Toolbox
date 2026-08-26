import SwiftUI

/// Deep-link from the sidebar search into one `SettingsCategoryLayout`
/// sub-page (R10). The layout that owns `tab` applies and clears the route.
struct SidebarCategoryRoute: Equatable, Sendable {
    var tab: PanelTab
    var category: String
}

/// One row the sidebar search can locate: either a main tab or a sub-page of
/// a categorized page. Titles are localization keys; matching runs against
/// the resolved strings so users search what they read.
struct SidebarSearchEntry: Identifiable, Equatable {
    var tab: PanelTab
    var categoryRawValue: String?
    var titleKey: String
    var systemImage: String
    /// Extra localization keys whose resolved text should also match (e.g.
    /// the "通知" keyword locating the Settings page that hosts notification
    /// toggles).
    var keywordKeys: [String] = []

    var id: String {
        categoryRawValue.map { "\(tab.rawValue)/\($0)" } ?? tab.rawValue
    }

    var route: SidebarCategoryRoute? {
        categoryRawValue.map { SidebarCategoryRoute(tab: tab, category: $0) }
    }
}

/// Static index of searchable navigation entries. Every main tab is present;
/// sub-page entries mirror the `SettingsCategoryItem` enums of the
/// categorized pages.
enum SidebarSearchIndex {
    static let entries: [SidebarSearchEntry] = {
        var all = PanelTab.allCases.map { tab in
            SidebarSearchEntry(
                tab: tab,
                categoryRawValue: nil,
                titleKey: "nav.\(tab.rawValue)",
                systemImage: tab.systemImage
            )
        }

        func subPages(
            keyFormat: (String) -> String,
            tab: PanelTab,
            rawValues: [String],
            systemImages: [String],
            keywordKeys: [String: [String]] = [:]
        ) {
            for (rawValue, systemImage) in zip(rawValues, systemImages) {
                all.append(SidebarSearchEntry(
                    tab: tab,
                    categoryRawValue: rawValue,
                    titleKey: keyFormat(rawValue),
                    systemImage: systemImage,
                    keywordKeys: keywordKeys[rawValue] ?? []
                ))
            }
        }

        subPages(keyFormat: { "overview.category.\($0)" }, tab: .overview, rawValues: ["status", "network", "sim", "parameters"], systemImages: ["gauge.with.dots.needle.50percent", "network", "simcard", "list.bullet.rectangle"])
        subPages(keyFormat: { "phone.\($0).title" }, tab: .phone, rawValues: ["dialer", "history", "contacts", "sim", "recordings"], systemImages: ["circle.grid.3x3", "clock", "person.2", "simcard", "waveform"])
        subPages(keyFormat: { "gnss.category.\($0)" }, tab: .gnss, rawValues: ["status", "map", "details"], systemImages: ["location.circle", "map", "list.bullet.rectangle"])
        subPages(keyFormat: { "network.category.\($0)" }, tab: .network, rawValues: ["interface", "routing", "traffic"], systemImages: ["externaldrive.connected.to.line.below", "arrow.triangle.branch", "chart.xyaxis.line"])
        subPages(keyFormat: { "estk.category.\($0)" }, tab: .estk, rawValues: ["profiles", "download", "euicc", "notifications", "tools"], systemImages: ["rectangle.stack", "square.and.arrow.down", "simcard", "bell.badge", "wrench.and.screwdriver"])
        subPages(keyFormat: { "vowifi.category.\($0)" }, tab: .vowifi, rawValues: ["status", "identity", "connection", "logs"], systemImages: ["dot.radiowaves.forward", "person.text.rectangle", "network.badge.shield.half.filled", "text.alignleft"])
        subPages(
            keyFormat: { "settings.category.\($0)" },
            tab: .settings,
            rawValues: ["general", "calls", "messages", "cellular", "module", "network", "remote", "datetime", "maintenance"],
            systemImages: ["gearshape", "phone", "message.badge", "simcard", "cpu", "network", "network.badge.shield.half.filled", "clock", "wrench.and.screwdriver"],
            keywordKeys: [
                // The notification toggles and call-audio settings live inside
                // these pages; the spec requires search to locate them.
                "messages": ["settings.search.keyword.notifications"],
                "calls": ["settings.search.keyword.audio"],
                "network": ["settings.search.keyword.apn"],
            ]
        )
        return all
    }()

    /// True when the resolved entry text mentions the query (case- and
    /// diacritic-insensitive, token-substring).
    static func matches(
        _ entry: SidebarSearchEntry,
        query: String,
        resolver: (String) -> String
    ) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystacks = ([entry.titleKey] + entry.keywordKeys).map(resolver)
        return haystacks.contains { haystack in
            haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func filter(
        entries: [SidebarSearchEntry] = entries,
        query: String,
        resolver: (String) -> String
    ) -> [SidebarSearchEntry] {
        entries.filter { matches($0, query: query, resolver: resolver) }
    }
}

/// Display strings for the compact sidebar device summary. Pure so the
/// offline-persistence rule ("keep the last known USB identity") stays
/// testable even though the view combines identity and endpoints visually.
struct DeviceSummaryDisplay: Equatable {
    var title: String
    var modeKey: String
    var statusKey: String
    var isOnline: Bool
    /// Remote address (for remote sessions) plus USB VID:PID and the AT
    /// interface number.
    var usbIdentity: String
    /// Bulk endpoint addresses, when the session reported them.
    var endpoints: String?

    static func make(
        state: ModemState,
        statusTextKey: String,
        rememberedDetail: String?
    ) -> DeviceSummaryDisplay {
        let isRemote = state.remoteManagement.mode == .remote
        // While offline the card keeps its position and shows the last known
        // USB identity instead of collapsing to a placeholder row.
        let detail = state.connected
            ? state.usbDescription
            : (rememberedDetail ?? state.usbDescription)
        let lines = summaryLines(from: detail)
        return DeviceSummaryDisplay(
            title: localized("app.name"),
            modeKey: isRemote ? "remote.mode.remote" : "remote.mode.direct",
            statusKey: statusTextKey,
            isOnline: state.connected,
            usbIdentity: lines.identity,
            endpoints: lines.endpoints
        )
    }

    /// Splits a transport session description into the summary's short lines
    /// (spec §3.2: no ellipsis, normal wrapping allowed). Direct sessions
    /// read `USB 2c7c:0125 if2 out=0x03 in=0x84`; remote sessions prefix the
    /// server address before the same USB description.
    static func summaryLines(from description: String) -> (identity: String, endpoints: String?) {
        let fullRange = NSRange(description.startIndex..., in: description)
        guard let match = Self.usbPattern.firstMatch(in: description, range: fullRange),
              let vidpidRange = Range(match.range(at: 1), in: description)
        else { return (identity: description, endpoints: nil) }

        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: description) else { return nil }
            return String(description[range])
        }

        var identity = "USB \(description[vidpidRange])"
        if let interface = group(3) {
            identity += " · if\(interface)"
        }
        // Remote descriptions prefix the server address; keep it on the
        // identity line so the card never hides where the session points.
        if match.range.location > 0,
           let prefixRange = Range(NSRange(location: 0, length: match.range.location), in: description) {
            let address = description[prefixRange]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
            if !address.isEmpty {
                identity = "\(address) · \(identity)"
            }
        }

        var endpointParts: [String] = []
        if let out = group(4) { endpointParts.append("out=0x\(out)") }
        if let input = group(5) { endpointParts.append("in=0x\(input)") }
        return (identity: identity, endpoints: endpointParts.isEmpty ? nil : endpointParts.joined(separator: " · "))
    }

    private static let usbPattern: NSRegularExpression = {
        // USB VID:PID, optional AT interface number, optional bulk endpoints.
        try! NSRegularExpression(
            pattern: "USB ([0-9a-fA-F]{4}:[0-9a-fA-F]{4})(?: serial=([^ ]+))?(?: if(\\d+))?(?: out=0x([0-9a-fA-F]+))?(?: in=0x([0-9a-fA-F]+))?"
        )
    }()
}

/// Device summary card at the macOS System Settings "Apple Account" position:
/// below the sidebar search, above the main navigation. Never removed on
/// disconnect; clicking it selects the Overview page.
struct DeviceSummaryRow: View {
    @EnvironmentObject private var store: ModemStore
    @EnvironmentObject private var coordinator: ModemSessionCoordinator
    @Binding var selection: PanelTab
    @State private var rememberedDetail: String?

    private var display: DeviceSummaryDisplay {
        DeviceSummaryDisplay.make(
            state: store.state,
            statusTextKey: store.statusText,
            rememberedDetail: rememberedDetail
        )
    }

    var body: some View {
        let summary = display

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 5) {
                Button {
                    selection = .overview
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                    Image(systemName: store.state.remoteManagement.mode == .remote
                        ? "network.badge.shield.half.filled"
                        : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title)
                            .font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)

                        if let descriptor = coordinator.selectedDescriptor {
                            Text(coordinator.displayName(for: descriptor))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(descriptor.imei.map {
                                localizedFormat("module.imei.format", $0)
                            } ?? localizedFormat("module.identity.pending.format", descriptor.displaySerial))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }

                        Text(localized(summary.modeKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(summary.usbIdentity)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)

                        if let endpoints = summary.endpoints {
                            Text(endpoints)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(LocalizedStringKey(String(
                    format: "%@, %@, %@, %@",
                    localized("app.name"),
                    localized(summary.modeKey),
                    summary.usbIdentity,
                    localized(summary.statusKey)
                )))
                .help(localizedFormat(
                    "common.full_value_help",
                    "\(localized("app.name")) · \(localized(summary.modeKey)) · \(summary.usbIdentity)\(summary.endpoints.map { " · \($0)" } ?? "")"
                ))

            }

            if coordinator.sessions.count > 1 {
                Picker(
                    localized("module.current"),
                    selection: Binding(
                        get: { coordinator.selectedDeviceID },
                        set: { coordinator.selectDevice($0) }
                    )
                ) {
                    ForEach(coordinator.sessions) { session in
                        Text(coordinator.notificationName(for: session.id))
                            .tag(session.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 41)
                .help(localized("module.switch.help"))
                .accessibilityLabel(localized("module.current"))
            }

            HStack(spacing: 6) {
                StatusLabel(
                    text: summary.statusKey,
                    color: summary.isOnline ? .accentColor : .secondary
                )
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: true)

                Spacer(minLength: 6)

                Button {
                    store.refreshAll()
                } label: {
                    Image(systemName: store.state.refreshing
                        ? "arrow.triangle.2.circlepath"
                        : "arrow.clockwise")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(localized("action.refresh_status"))
                .accessibilityLabel(localized("action.refresh_status"))
                .disabled(store.state.busy || store.state.refreshing)
            }
            .padding(.leading, 41)
        }
        .onChange(of: store.state.connected) { _, connected in
            guard connected else { return }
            // Remember the identity reported by this session for offline use.
            if rememberedDetail == nil, store.state.usbDescription != "USB 2c7c:0125" {
                rememberedDetail = store.state.usbDescription
            }
        }
        .onChange(of: store.state.usbDescription) { _, newDescription in
            guard store.state.connected, newDescription != "USB 2c7c:0125" else { return }
            rememberedDetail = newDescription
        }
    }
}

/// System-settings-style sidebar: search on top, the compact device summary,
/// then the always-complete main navigation.
struct AppSidebar: View {
    @EnvironmentObject private var coordinator: ModemSessionCoordinator
    @EnvironmentObject private var presentation: WindowPresentationModel
    @Binding var selection: PanelTab
    @State private var query = ""

    /// Matches the compact System Settings-style sidebar geometry. The parent
    /// manual split applies this exact width and exposes no drag handle.
    static let fixedColumnWidth: CGFloat = 216

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredEntries: [SidebarSearchEntry] {
        SidebarSearchIndex.filter(query: query, resolver: localized)
    }

    var body: some View {
        VStack(spacing: 0) {
            CompactSearchField(text: $query, promptKey: "sidebar.search.prompt")
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            List(selection: $selection) {
                if isFiltering {
                    ForEach(filteredEntries) { entry in
                        Button {
                            navigate(to: entry)
                        } label: {
                            SidebarNavigationLabel(
                                title: localized(entry.titleKey),
                                systemImage: entry.systemImage,
                                tint: entry.tab.sidebarIconTint,
                                isSelected: selection == entry.tab
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if filteredEntries.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    Section {
                        DeviceSummaryRow(selection: $selection)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    Section {
                        ForEach(PanelTab.allCases) { tab in
                            SidebarNavigationLabel(
                                title: tab.title,
                                systemImage: tab.systemImage,
                                tint: tab.sidebarIconTint,
                                isSelected: selection == tab
                            )
                            .tag(tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if !coordinator.liveSessions.isEmpty {
                Divider().opacity(0.45)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(coordinator.liveSessions) { session in
                            CallTakeoverView(placement: .sidebarCard)
                                .environmentObject(session.store)
                                .onTapGesture {
                                    coordinator.selectDevice(session.id)
                                    selection = .phone
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: CGFloat(min(coordinator.liveSessions.count, 2)) * 145)
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: Self.fixedColumnWidth)
        .background(.regularMaterial)
    }

    private func navigate(to entry: SidebarSearchEntry) {
        selection = entry.tab
        if let route = entry.route {
            presentation.pendingCategoryRoute = route
        }
    }
}

/// macOS System Settings-style colored icon tile: one adaptive SF Symbol on a
/// semantic color, with a restrained highlight, border, and layered depth.
private struct SidebarIconTile: View {
    var systemImage: String
    var tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.82), tint],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(.white.opacity(0.24), lineWidth: 0.5)
                }

            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 25, height: 25)
        .shadow(color: .black.opacity(0.16), radius: 1.5, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
    }
}

private struct SidebarNavigationLabel: View {
    var title: String
    var systemImage: String
    var tint: Color
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            SidebarIconTile(systemImage: systemImage, tint: tint)
            Text(title)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private extension PanelTab {
    var sidebarIconTint: Color {
        switch self {
        case .overview: Color(nsColor: .systemOrange)
        case .phone: Color(nsColor: .systemGreen)
        case .sms: Color(nsColor: .systemGreen)
        case .gnss: Color(nsColor: .systemBlue)
        case .network: Color(nsColor: .systemBlue)
        case .estk: Color(nsColor: .systemOrange)
        case .vowifi: Color(nsColor: .systemTeal)
        case .terminal: Color(nsColor: .darkGray)
        case .settings: Color(nsColor: .systemGray)
        }
    }
}
