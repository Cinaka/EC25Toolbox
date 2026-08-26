import SwiftUI

/// "Date & Time" settings (R6): the single surface controlling every
/// user-visible date-time string. Pickers commit immediately; custom LDML
/// patterns and custom zone identifiers are only persisted once they
/// validate. An invalid draft stays local, shows an inline error, and the
/// saved preferences keep rendering with their last valid pattern, so a bad
/// value can never blank the UI.
struct DateTimeSettingsCard: View {
    @EnvironmentObject private var store: ModemStore

    @State private var draftFull = ""
    @State private var draftDateOnly = ""
    @State private var draftTimeOnly = ""
    @State private var draftCompact = ""
    @State private var draftTimeZone = ""

    private var preferences: DateTimeDisplayPreferences {
        store.settings.effectiveDateTimeDisplay
    }

    /// Fixed SMS sample instant: `2026-07-10 09:40:48 +08:00` (the R5 SCTS
    /// reference vector), so the preview demonstrates the zone policy on a
    /// timestamp whose source offset is known.
    private static let smsSampleDate = Date(timeIntervalSince1970: 1_783_647_648)
    private static let smsSampleOffsetSeconds = 8 * 3_600
    private static let ldmlReferenceURL = URL(string: "https://unicode.org/reports/tr35/tr35-dates.html")

    var body: some View {
        VStack(spacing: 18) {
            displayGroup
            if preferences.mode == .custom {
                patternGroup
            }
            previewGroup
        }
        .onAppear(perform: syncDrafts)
        .onChange(of: store.settings.dateTimeDisplay) { _, _ in
            syncDrafts()
        }
    }

    // MARK: - Display mode & zone

    private var displayGroup: some View {
        MacSettingsGroup("settings.group.datetime.display") {
            MacSettingsRow(
                title: "settings.datetime.mode.title",
                help: "settings.datetime.mode.help"
            ) {
                RightAlignedMenuPicker(
                    selection: Binding(
                        get: { preferences.mode },
                        set: { mode in
                            updatePreferences { $0.mode = mode }
                        }
                    ),
                    options: DateTimePatternMode.allCases.map { mode in
                        .init(title: localized(modeTitleKey(mode)), value: mode)
                    }
                )
                .frame(width: 148, height: 26)
            }

            MacSettingsDivider()

            MacSettingsRow(
                title: "settings.datetime.zone.title",
                help: "settings.datetime.zone.help"
            ) {
                RightAlignedMenuPicker(
                    selection: Binding(
                        get: { preferences.zonePolicy },
                        set: { policy in
                            updatePreferences { $0.zonePolicy = policy }
                        }
                    ),
                    options: DateTimeZonePolicy.allCases.map { policy in
                        .init(title: localized(zoneTitleKey(policy)), value: policy)
                    }
                )
                .frame(width: 148, height: 26)
            }

            if preferences.zonePolicy == .custom {
                MacSettingsDivider()

                MacSettingsRow(
                    title: "settings.datetime.timezone.title",
                    help: "settings.datetime.timezone.help"
                ) {
                    VStack(alignment: .trailing, spacing: 3) {
                        TextField(
                            "Asia/Shanghai",
                            text: Binding(
                                get: { draftTimeZone },
                                set: { identifier in
                                    draftTimeZone = identifier
                                    commitTimeZoneDraft(identifier)
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 190)
                        if let issue = timeZoneIssue {
                            Text(issue)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Custom patterns

    private var patternGroup: some View {
        MacSettingsGroup("settings.group.datetime.patterns") {
            patternRow(.full, text: $draftFull)
            MacSettingsDivider()
            patternRow(.dateOnly, text: $draftDateOnly)
            MacSettingsDivider()
            patternRow(.timeOnly, text: $draftTimeOnly)
            MacSettingsDivider()
            patternRow(.compact, text: $draftCompact)
            MacSettingsDivider()

            HStack(spacing: 8) {
                Label(localized("settings.datetime.pattern.ldml_hint"), systemImage: "text.book.closed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let url = Self.ldmlReferenceURL {
                    Link(localized("settings.datetime.pattern.ldml_link"), destination: url)
                        .font(.caption2)
                        .help(url.absoluteString)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private func patternRow(_ role: DateTimeDisplayRole, text: Binding<String>) -> some View {
        MacSettingsRow(
            title: roleTitleKey(role),
            help: "settings.datetime.pattern.help"
        ) {
            VStack(alignment: .trailing, spacing: 3) {
                TextField(
                    DateTimeDisplayPreferences.defaultPatterns[role] ?? "",
                    text: Binding(
                        get: { text.wrappedValue },
                        set: { draft in
                            text.wrappedValue = draft
                            commitPatternDraft(draft, for: role)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 190)
                if let issue = patternIssue(for: role) {
                    Text(issue)
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if text.wrappedValue.isEmpty {
                    Text(localizedFormat(
                        "settings.datetime.pattern.default_hint",
                        DateTimeDisplayPreferences.defaultPatterns[role] ?? ""
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Preview

    private var previewGroup: some View {
        MacSettingsGroup("settings.group.datetime.preview") {
            MacSettingsRow(
                title: "settings.datetime.preview.now",
                help: "settings.datetime.preview.now.help"
            ) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .trailing, spacing: 3) {
                        ForEach(DateTimeDisplayRole.allCases, id: \.rawValue) { role in
                            Text(AppDateTimeFormatter.shared.string(from: context.date, role: role))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            MacSettingsDivider()

            MacSettingsRow(
                title: "settings.datetime.preview.sms",
                help: "settings.datetime.preview.sms.help"
            ) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(AppDateTimeFormatter.shared.string(
                        from: Self.smsSampleDate,
                        role: .full,
                        sourceTimeZoneOffsetSeconds: Self.smsSampleOffsetSeconds
                    ))
                    .font(.caption.monospacedDigit())
                    Text(localized("settings.datetime.preview.sms.caption"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            MacSettingsDivider()

            MacSettingsRow(
                title: "settings.datetime.restore",
                help: "settings.datetime.restore.help"
            ) {
                Button(localized("settings.datetime.restore")) {
                    store.updateSettings { $0.dateTimeDisplay = nil }
                }
                .disabled(store.settings.dateTimeDisplay == nil)
            }
        }
    }

    // MARK: - Draft commit

    /// Materializes the preferences struct on first change so pickers work
    /// even while the persisted value is still `nil` (app defaults).
    private func updatePreferences(_ mutate: (inout DateTimeDisplayPreferences) -> Void) {
        store.updateSettings { settings in
            var display = settings.dateTimeDisplay ?? DateTimeDisplayPreferences()
            mutate(&display)
            settings.dateTimeDisplay = display
        }
    }

    /// Drafts mirror the persisted preferences; they re-sync whenever the
    /// persisted value changes (including this card's own commits) so an
    /// invalid draft is the only way local state can drift.
    private func syncDrafts() {
        draftFull = preferences.customFull ?? ""
        draftDateOnly = preferences.customDateOnly ?? ""
        draftTimeOnly = preferences.customTimeOnly ?? ""
        draftCompact = preferences.customCompact ?? ""
        draftTimeZone = preferences.customTimeZoneIdentifier ?? ""
    }

    /// Persists a custom pattern only when it validates; an empty draft
    /// clears the override so the role falls back to the app default.
    private func commitPatternDraft(_ draft: String, for role: DateTimeDisplayRole) {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard LDMLPatternValidator.validate(trimmed, for: role) == nil else { return }
        updatePreferences { prefs in
            switch role {
            case .full: prefs.customFull = trimmed.isEmpty ? nil : trimmed
            case .dateOnly: prefs.customDateOnly = trimmed.isEmpty ? nil : trimmed
            case .timeOnly: prefs.customTimeOnly = trimmed.isEmpty ? nil : trimmed
            case .compact: prefs.customCompact = trimmed.isEmpty ? nil : trimmed
            }
        }
    }

    /// Persists the custom IANA identifier only when it is recognized.
    private func commitTimeZoneDraft(_ draft: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || TimeZone(identifier: trimmed) != nil else { return }
        updatePreferences { prefs in
            prefs.customTimeZoneIdentifier = trimmed.isEmpty ? nil : trimmed
        }
    }

    private func patternIssue(for role: DateTimeDisplayRole) -> String? {
        let draft = [
            .full: draftFull,
            .dateOnly: draftDateOnly,
            .timeOnly: draftTimeOnly,
            .compact: draftCompact,
        ][role] ?? ""
        guard let reason = LDMLPatternValidator.validate(draft, for: role) else { return nil }
        return LDMLPatternIssue(role: role, reason: reason).localizedMessage()
    }

    private var timeZoneIssue: String? {
        let trimmed = draftTimeZone.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return preferences.zonePolicy == .custom
                ? localizedFormat("datetime.error.invalid_timezone", "")
                : nil
        }
        guard TimeZone(identifier: trimmed) == nil else { return nil }
        return localizedFormat("datetime.error.invalid_timezone", trimmed)
    }

    private func modeTitleKey(_ mode: DateTimePatternMode) -> String {
        switch mode {
        case .appDefault: "settings.datetime.mode.app_default"
        case .followSystem: "settings.datetime.mode.follow_system"
        case .custom: "settings.datetime.mode.custom"
        }
    }

    private func zoneTitleKey(_ policy: DateTimeZonePolicy) -> String {
        switch policy {
        case .source: "settings.datetime.zone.source"
        case .system: "settings.datetime.zone.system"
        case .utc: "settings.datetime.zone.utc"
        case .custom: "settings.datetime.zone.custom"
        }
    }

    private func roleTitleKey(_ role: DateTimeDisplayRole) -> String {
        switch role {
        case .full: "settings.datetime.role.full"
        case .dateOnly: "settings.datetime.role.date_only"
        case .timeOnly: "settings.datetime.role.time_only"
        case .compact: "settings.datetime.role.compact"
        }
    }
}
