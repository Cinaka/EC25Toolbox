import SwiftUI

private enum VoWiFiCategory: String, CaseIterable, Identifiable, SettingsCategoryItem {
    case status
    case identity
    case connection
    case logs

    var id: String { rawValue }
    var title: String { "vowifi.category.\(rawValue)" }
    var description: String { "vowifi.category.\(rawValue).description" }

    var systemImage: String {
        switch self {
        case .status: "dot.radiowaves.forward"
        case .identity: "person.text.rectangle"
        case .connection: "network.badge.shield.half.filled"
        case .logs: "text.alignleft"
        }
    }
}

struct VoWiFiView: View {
    @EnvironmentObject private var store: ModemStore
    @State private var selectedCategory: VoWiFiCategory = .status
    @State private var enabled = false
    @State private var autoConnect = true
    @State private var epdgAddress = ""
    @State private var pcscfAddress = ""
    @State private var realm = ""
    @State private var privateIdentity = ""
    @State private var publicIdentity = ""
    @State private var loaded = false

    var body: some View {
        SettingsCategoryLayout(
            categories: VoWiFiCategory.allCases,
            owningTab: .vowifi,
            selection: $selectedCategory
        ) {
            SettingsCategoryHeader(
                title: selectedCategory.title,
                description: selectedCategory.description,
                systemImage: selectedCategory.systemImage
            )
        } content: {
            categoryContent
        }
        .onAppear { load() }
        .onChange(of: enabled) { _, value in
            guard loaded else { return }
            store.setVoWiFiEnabled(value)
        }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .status:
            VStack(spacing: 18) {
                serviceGroup
                if let error = store.state.vowifi.lastError {
                    MacSettingsContentGroup("vowifi.error.title") {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                statusCard
            }
        case .identity:
            identityCard
        case .connection:
            settingsCard
        case .logs:
            logCard
        }
    }

    private var serviceGroup: some View {
        MacSettingsGroup("vowifi.group.service") {
            MacSettingsToggleRow(
                title: "vowifi.enable",
                help: "vowifi.enable.help",
                isOn: $enabled
            )

            MacSettingsDivider()

            MacSettingsRow(
                title: "vowifi.reconnect",
                help: "vowifi.reconnect.help"
            ) {
                Button {
                    store.reconnectVoWiFi()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, value: store.state.vowifi.phase.isWorking)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .disabled(!enabled || !store.state.connected)
                .help(localized("vowifi.reconnect"))
            }
        }
    }

    private var statusCard: some View {
        MacSettingsParameterGroup(
            title: "vowifi.status.title",
            values: [
                ParameterValue(
                    label: "vowifi.status.phase",
                    value: store.state.vowifi.phase.localizationKey
                ),
                ParameterValue(
                    label: "vowifi.status.received",
                    value: String(store.state.vowifi.receivedSMSCount)
                ),
                ParameterValue(
                    label: "vowifi.status.epdg",
                    value: store.state.vowifi.tunnel.resolvedAddress
                ),
                ParameterValue(
                    label: "vowifi.status.inner_address",
                    value: store.state.vowifi.tunnel.innerAddress
                ),
                ParameterValue(
                    label: "vowifi.status.pcscf",
                    value: store.state.vowifi.tunnel.pcscfAddress
                ),
                ParameterValue(
                    label: "vowifi.status.reconnect",
                    value: String(store.state.vowifi.reconnectAttempt)
                )
            ],
            columnCount: 2
        )
    }

    @ViewBuilder
    private var identityCard: some View {
        if let identity = store.state.vowifi.identity {
            MacSettingsCard {
                identityRow("vowifi.identity.source", value: identity.source.localizationKey)
                MacSettingsDivider()
                identityRow("vowifi.identity.impi", value: identity.impi)
                MacSettingsDivider()
                identityRow("vowifi.identity.impu", value: identity.impu)
                MacSettingsDivider()
                identityRow("vowifi.identity.realm", value: identity.realm)
            }
        } else {
            EmptyState(
                title: "vowifi.identity.empty.title",
                subtitle: "vowifi.identity.empty.description",
                systemImage: "person.text.rectangle"
            )
            .frame(height: 220)
        }
    }

    private var settingsCard: some View {
        MacSettingsGroup("vowifi.settings.title") {
            MacSettingsToggleRow(
                title: "vowifi.settings.auto_connect",
                help: "vowifi.settings.auto_connect.help",
                isOn: $autoConnect
            )

            settingsDividerAndField("vowifi.settings.epdg", text: $epdgAddress)
            settingsDividerAndField("vowifi.settings.pcscf", text: $pcscfAddress)
            settingsDividerAndField("vowifi.settings.realm", text: $realm)
            settingsDividerAndField("vowifi.settings.impi", text: $privateIdentity)
            settingsDividerAndField("vowifi.settings.impu", text: $publicIdentity)

            MacSettingsDivider()

            MacSettingsRow(
                title: "vowifi.settings.save",
                help: "vowifi.settings.derived_hint"
            ) {
                Button(localized("vowifi.settings.save")) {
                    store.saveVoWiFiSettings(
                        autoConnect: autoConnect,
                        epdgAddress: epdgAddress,
                        pcscfAddress: pcscfAddress,
                        realm: realm,
                        privateIdentity: privateIdentity,
                        publicIdentity: publicIdentity
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.state.busy)
            }
        }
    }

    private var logCard: some View {
        MacSettingsContentCard {
            if store.state.vowifi.logs.isEmpty {
                Text(localized("vowifi.logs.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.state.vowifi.logs.reversed()) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: logIcon(entry.kind))
                                .foregroundStyle(logColor(entry.kind))
                            Text(AppDateTimeFormatter.shared.string(from: entry.date, role: .timeOnly))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.caption)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func settingsDividerAndField(_ title: String, text: Binding<String>) -> some View {
        Group {
            MacSettingsDivider()
            MacSettingsRow(title: title, help: title + ".help") {
                TextField(localized("vowifi.settings.auto_placeholder"), text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, idealWidth: 220, maxWidth: 260)
                    .help(localized(title + ".help"))
            }
        }
    }

    private func identityRow(_ title: String, value: String) -> some View {
        let displayValue = localized(value.isEmpty ? "-" : value)
        return VStack(alignment: .leading, spacing: 5) {
            Text(localized(title))
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(displayValue)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(localizedFormat("common.full_value_help", displayValue))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }

    private func load() {
        guard !loaded else { return }
        enabled = store.settings.effectiveVoWiFiEnabled
        autoConnect = store.settings.effectiveVoWiFiAutoConnect
        epdgAddress = store.settings.vowifiEPDGAddress ?? ""
        pcscfAddress = store.settings.vowifiPCSCFAddress ?? ""
        realm = store.settings.vowifiIMSRealm ?? ""
        privateIdentity = store.settings.vowifiPrivateIdentity ?? ""
        publicIdentity = store.settings.vowifiPublicIdentity ?? ""
        loaded = true
    }

    private func logIcon(_ kind: VoWiFiLogEntry.Kind) -> String {
        switch kind {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .failure: "xmark.circle"
        }
    }

    private func logColor(_ kind: VoWiFiLogEntry.Kind) -> Color {
        switch kind {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}
