import AppKit
import SwiftUI

/// Native macOS pop-up button whose selected value is aligned to the trailing edge.
struct RightAlignedMenuPicker<Value: Hashable>: NSViewRepresentable {
    struct Option {
        var title: String
        var value: Value
    }

    @Binding var selection: Value
    var options: [Option]

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.bezelStyle = .rounded
        button.alignment = .right
        button.cell?.alignment = .right
        button.cell?.lineBreakMode = .byTruncatingTail
        // SwiftUI supplies the row's available width. Let the AppKit control
        // compress within that proposal instead of letting a localized title
        // push its bezel through the settings card's trailing inset.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self

        button.removeAllItems()
        button.addItems(withTitles: options.map(\.title))
        button.alignment = .right
        button.cell?.alignment = .right
        button.cell?.lineBreakMode = .byTruncatingTail

        if let index = options.firstIndex(where: { $0.value == selection }) {
            button.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var parent: RightAlignedMenuPicker

        init(parent: RightAlignedMenuPicker) {
            self.parent = parent
        }

        @MainActor @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }
}

/// Shared rounded surface used by settings rows and richer feature cards.
struct MacSettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.58),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }
}

private struct SettingsGroupCardlessKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set on the window Settings page (R19): groups rendered inside a native
    /// `Form` section drop their own card so exactly one container — the
    /// section — draws the grouped background. Every other surface keeps the
    /// standalone card look.
    var settingsGroupCardless: Bool {
        get { self[SettingsGroupCardlessKey.self] }
        set { self[SettingsGroupCardlessKey.self] = newValue }
    }
}

/// macOS Settings-style group with a small category label and rounded row container.
struct MacSettingsGroup<Content: View>: View {
    @Environment(\.settingsGroupCardless) private var cardless
    var title: String
    @ViewBuilder var content: Content

    init(
        _ title: String,
        systemImage _: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Small section titles are text-only across the app. Category and
            // action icons already communicate hierarchy; repeating another
            // symbol here adds noise without information.
            Text(localized(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, cardless ? 2 : 14)

            if cardless {
                // The enclosing Form section already draws the grouped card;
                // rows render directly against it.
                content
            } else {
                MacSettingsCard {
                    content
                }
            }
        }
    }
}

/// Aligned label/help/control row used by the categorized Settings pages.
struct MacSettingsRow<Control: View>: View {
    var title: String
    var help: String?
    @ViewBuilder var control: Control

    init(
        title: String,
        help: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: help == nil ? 0 : 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(localized(title))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                Spacer(minLength: 10)

                control
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let help {
                Text(localized(help))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
        .help(help.map(localized) ?? localized(title))
    }
}

/// Right-aligned native switch row matching macOS Settings.
struct MacSettingsToggleRow: View {
    var title: String
    var help: String?
    @Binding var isOn: Bool

    var body: some View {
        MacSettingsRow(title: title, help: help) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .tint(AppControlPalette.accent)
        }
    }
}

/// Inset separator aligned with macOS Settings row labels.
struct MacSettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 14)
            .opacity(0.48)
    }
}

/// Full-width explanatory row aligned with ordinary Settings rows. Keeping
/// notes inside the row container prevents bottom text from colliding with
/// a group's rounded border at narrow widths.
struct MacSettingsNoteRow: View {
    var text: String
    var systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Label(localized(text), systemImage: systemImage)
            } else {
                Text(localized(text))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings-style rounded content group for feature pages that need richer layouts than a single row.
struct MacSettingsContentGroup<Content: View>: View {
    var title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    init(
        _ title: String,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        MacSettingsGroup(title, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Rich settings-style content without a second section title.
struct MacSettingsContentCard<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        MacSettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Section label plus parameter tiles without an additional enclosing card.
/// This avoids a visually heavy card-within-card hierarchy.
struct MacSettingsParameterGroup: View {
    var title: String
    var values: [ParameterValue]
    var columnCount = 2
    var fullValueDisplay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(localized(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 7)

            ParameterGrid(
                values: values,
                columnCount: columnCount,
                fullValueDisplay: fullValueDisplay
            )
        }
    }
}

/// Category introduction shown at the top of popover detail content.
///
/// The standalone window already presents the selected category in native
/// navigation chrome, so it keeps only a stable inline action row. The popover
/// keeps the explanatory card; individual pages omit only a directly repeated
/// section label below it.
struct SettingsCategoryHeader<Actions: View>: View {
    @Environment(\.presentationSurface) private var surface

    var title: String
    var description: String
    var systemImage: String
    @ViewBuilder var actions: Actions

    init(
        title: String,
        description: String,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        Group {
            if surface == .standaloneWindow {
                if Actions.self != EmptyView.self {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        actions
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                // Keep the same 14×12 pt insets as the information cards,
                // but let macOS draw this introductory surface as real Liquid
                // Glass. Reusing MacSettingsContentCard here would reapply its
                // controlBackgroundColor fill and make the header look opaque.
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: systemImage)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(localized(title))
                                .font(.headline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(localized(description))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        HStack(spacing: 6) {
                            actions
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
        }
    }

}

extension SettingsCategoryHeader where Actions == EmptyView {
    init(title: String, description: String, systemImage: String) {
        self.init(title: title, description: description, systemImage: systemImage) {
            EmptyView()
        }
    }
}

/// Compact checkbox cell used by the overview field picker.
struct FieldToggleCell: View {
    var label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(localized(label), isOn: $isOn)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .help(ParameterHelp.text(for: label))
    }
}

/// Labeled row that hosts a native picker, stepper, or other AppKit-style control.
struct SettingsPickerRow<Control: View>: View {
    var title: String
    var help: String?
    @ViewBuilder var control: Control

    init(title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(localized(title))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .layoutPriority(1)
            Spacer(minLength: 12)
            control
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
        .help(help.map(localized) ?? localized(title))
    }
}

/// Compact number plus native stepper used in trailing settings controls.
struct CompactNumericStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 6) {
            Text(String(value))
                .monospacedDigit()
                .frame(minWidth: 28, alignment: .trailing)

            Stepper(value: $value, in: range) {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
        }
        .fixedSize()
    }
}

/// Fixed-size apply button used by settings rows.
struct ApplyButton: View {
    var help: String
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .frame(width: 46)
        .help(localized(help))
        .disabled(disabled)
    }
}

/// Reusable in-page header with an SF Symbol, title, subtitle, and optional
/// actions. Keeping this inside the page prevents uncategorized views from
/// creating a separate window-toolbar row above otherwise full-size content.
struct PageHeader<Actions: View>: View {
    var title: String
    var subtitle: String
    var systemImage: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(localized(title))
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .help(localizedFormat("common.full_value_help", localized(title)))
                Text(localized(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(localizedFormat("common.full_value_help", localized(subtitle)))
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                actions
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
    }
}

/// Lightweight section container for grouped panel content.
struct SectionCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    var fillHeight: Bool
    @ViewBuilder var content: Content

    init(
        title: String? = nil,
        systemImage: String? = nil,
        fillHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.fillHeight = fillHeight
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let title, let systemImage {
                    Label(localized(title), systemImage: systemImage)
                        .font(.subheadline.weight(.semibold))
                }
                content
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: fillHeight ? .infinity : nil,
                alignment: .topLeading
            )
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: fillHeight ? .infinity : nil,
            alignment: .topLeading
        )
    }
}

/// Native label used for connectivity and progress status.
struct StatusLabel: View {
    var text: String
    var color: Color

    var body: some View {
        Label {
            Text(localized(text))
        } icon: {
            Image(systemName: systemImage)
                .symbolEffect(.pulse, value: isBusy)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .lineLimit(1)
        .help(localized("status.help"))
    }

    private var isBusy: Bool {
        text == "status.working" || text == "status.connecting"
    }

    private var systemImage: String {
        switch text {
        case "status.online": "checkmark.circle.fill"
        case "status.offline": "xmark.circle"
        default: "arrow.triangle.2.circlepath"
        }
    }
}

/// SF Symbol based signal visualization for radio quality cards.
struct SignalBars: View {
    var level: Int
    var color: Color

    var body: some View {
        Image(systemName: "cellularbars", variableValue: Double(normalizedLevel) / 4.0)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(color)
        .accessibilityLabel(localizedFormat("accessibility.signal_bars", level))
    }

    private var normalizedLevel: Int {
        min(max(level, 0), 4)
    }
}

/// Standard two-column label/value row.
struct KeyValueRow: View {
    var label: String
    var value: String
    var labelWidth: CGFloat = 88

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(localized(label))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .trailing)
                .help(ParameterHelp.text(for: label))
            Text(localized(value.isEmpty ? "-" : value))
                .font(PanelTypography.technicalValue)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(localizedFormat(
                    "common.full_value_help",
                    localized(value.isEmpty ? "-" : value)
                ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One value in a compact multi-column parameter grid.
struct ParameterValue: Identifiable {
    var id: String { label }
    var label: String
    var value: String
}

/// Dense label-over-value grid used for at-a-glance modem data.
struct ParameterGrid: View {
    var values: [ParameterValue]
    var columnCount = 2
    var fullValueDisplay = false
    var showsCellBackground = true

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .topLeading), count: columnCount)
    }

    var body: some View {
        let compactValues = values.filter { !requiresFullWidth($0) }
        let expandedValues = values.filter(requiresFullWidth)

        VStack(alignment: .leading, spacing: 6) {
            if !compactValues.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(compactValues) { item in
                        parameterCell(item, expanded: false)
                    }
                }
            }

            // Values that would wrap are moved after the compact grid and use
            // the entire row. This keeps neighboring short fields dense while
            // guaranteeing long addresses, paths, lists, and raw values are
            // shown without truncation.
            ForEach(expandedValues) { item in
                parameterCell(item, expanded: true)
            }
        }
    }

    private func requiresFullWidth(_ item: ParameterValue) -> Bool {
        let displayValue = localized(item.value.isEmpty ? "-" : item.value)
        guard displayValue != "-" else { return false }
        if displayValue.contains(where: \.isNewline) { return true }

        // A conservative per-column budget prevents a value from becoming a
        // clipped two-line cell before SwiftUI has a concrete grid width.
        let characterBudget = max(22, 84 / max(columnCount, 1))
        return displayValue.count > characterBudget
    }

    private func parameterCell(_ item: ParameterValue, expanded: Bool) -> some View {
        let displayValue = localized(item.value.isEmpty ? "-" : item.value)
        return VStack(alignment: .leading, spacing: 1) {
            Text(localized(item.label))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(fullValueDisplay || expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .help(ParameterHelp.text(for: item.label))
            Text(displayValue)
                .font(PanelTypography.compactTechnicalValue)
                .lineLimit(fullValueDisplay || expanded ? nil : 2)
                .truncationMode(.middle)
                .minimumScaleFactor(fullValueDisplay || expanded ? 1 : 0.82)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(localizedFormat("common.full_value_help", displayValue))
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .padding(.horizontal, showsCellBackground ? 7 : 0)
        .padding(.vertical, showsCellBackground ? 4 : 2)
        .background(
            showsCellBackground
                ? Color(nsColor: .controlBackgroundColor).opacity(0.38)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Placeholder shown when a feature has no rows to display. Backed by the
/// system `ContentUnavailableView` so empty and unavailable states match the
/// platform look. The optional action is the "next step" the spec requires
/// on unavailable pages (R10).
struct EmptyState: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var actionTitleKey: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(localized(title), systemImage: systemImage)
        } description: {
            Text(localized(subtitle))
        } actions: {
            if let actionTitleKey, let action {
                Button(localized(actionTitleKey), action: action)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PrefersInlineSearchKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// True on surfaces whose search belongs inline below the selected peer
    /// category. Both the popover and standalone window use this placement.
    var prefersInlineSearch: Bool {
        get { self[PrefersInlineSearchKey.self] }
        set { self[PrefersInlineSearchKey.self] = newValue }
    }
}

private struct PresentationSurfaceKey: EnvironmentKey {
    static let defaultValue: PresentationSurface = .popover
}

extension EnvironmentValues {
    /// Surface hosting the view. Categorized pages adapt their navigation
    /// (rail vs. native picker) and popover height reporting from this value.
    /// Defaults to the menu-bar popover.
    var presentationSurface: PresentationSurface {
        get { self[PresentationSurfaceKey.self] }
        set { self[PresentationSurfaceKey.self] = newValue }
    }
}

/// Unified detail-page margins (R15, `MACOS_SETTINGS_UI_SPEC` §4/§6): the
/// standalone window uses the 24 pt base margin and centers content at the
/// ~860 pt readable width shared with `SettingsCategoryLayout`; the popover
/// keeps its compact margins. Pages apply this in place of their own
/// horizontal padding so the two surfaces share components but not layout.
private struct DetailPageMarginsModifier: ViewModifier {
    @Environment(\.presentationSurface) private var surface
    var compactPadding: CGFloat

    func body(content: Content) -> some View {
        switch surface {
        case .standaloneWindow:
            content
                .padding(.horizontal, 24)
                .frame(maxWidth: 860, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
        case .popover:
            content.padding(.horizontal, compactPadding)
        }
    }
}

extension View {
    /// Window detail pages share one template: the spec's 24 pt base margin
    /// and readable ~860 pt width centered in the detail column (R15). The
    /// popover keeps the given compact padding unchanged.
    func detailPageMargins(compactPadding: CGFloat = 10) -> some View {
        modifier(DetailPageMarginsModifier(compactPadding: compactPadding))
    }
}

/// Inline search field with the current interactive Liquid Glass treatment.
struct CompactSearchField: View {
    @Binding var text: String
    var promptKey: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(localized(promptKey), text: $text)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(localized("common.clear_search"))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Inline placement is the shared default. A future navigation-only surface
/// may opt out and receive a native toolbar search without duplicating the
/// page's query or filtering state.
private struct SurfaceSearchModifier: ViewModifier {
    @Environment(\.prefersInlineSearch) private var prefersInlineSearch
    @Binding var text: String
    var promptKey: String

    func body(content: Content) -> some View {
        if prefersInlineSearch {
            content
        } else {
            content.searchable(
                text: $text,
                placement: .toolbar,
                prompt: Text(localized(promptKey))
            )
        }
    }
}

extension View {
    /// Shares one search binding between inline and navigation-only surfaces.
    func surfaceSearch(text: Binding<String>, promptKey: String) -> some View {
        modifier(SurfaceSearchModifier(text: text, promptKey: promptKey))
    }
}

/// Shown when an active filter removed every row of a non-empty list.
struct SearchNoResultsState: View {
    var body: some View {
        ContentUnavailableView {
            Label(localized("common.search.no_results.title"), systemImage: "magnifyingglass")
        } description: {
            Text(localized("common.search.no_results.description"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Returns whether a modem value should be treated as missing.
func isPlaceholder(_ value: String) -> Bool {
    let clean = trimmed(value)
    return clean.isEmpty || clean == "-"
}

/// Returns a display value only when it is not a placeholder.
func firstPresent(_ value: String) -> String? {
    isPlaceholder(value) ? nil : value
}
