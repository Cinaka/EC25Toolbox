import AppKit
import SwiftUI

struct RemoteManagementSettingsCard: View {
    @EnvironmentObject private var store: ModemStore

    @State private var mode = ManagementMode.direct
    @State private var sharingEnabled = true
    @State private var lanPort = String(RemoteDefaults.lanPort)
    @State private var tailscalePort = String(RemoteDefaults.tailscalePort)
    @State private var remoteHost = ""
    @State private var remotePort = String(RemoteDefaults.lanPort)
    @State private var pairingKey = ""
    @State private var loaded = false
    @State private var confirmingRotation = false

    var body: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("settings.group.connection") {
                MacSettingsRow(
                    title: "remote.mode.title",
                    help: "settings.category.remote.description"
                ) {
                    RightAlignedMenuPicker(
                        selection: $mode,
                        options: ManagementMode.allCases.map { value in
                            .init(
                                title: localized(value.localizationKey),
                                value: value
                            )
                        }
                    )
                    .frame(width: 140, height: 26, alignment: .trailing)
                }
            }

            if mode == .direct {
                directSettings
            } else {
                remoteSettings
            }

            if let error = store.state.remoteManagement.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { loadIfNeeded() }
        .alert(localized("remote.rotate.title"), isPresented: $confirmingRotation) {
            Button(localized("remote.rotate.action"), role: .destructive) {
                store.rotateRemotePairingKey()
            }
            Button(localized("estk.action.cancel"), role: .cancel) {}
        } message: {
            Text(localized("remote.rotate.message"))
        }
    }

    private var directSettings: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("settings.group.listener") {
                MacSettingsToggleRow(
                    title: "remote.sharing.enabled",
                    help: "remote.sharing.help",
                    isOn: $sharingEnabled
                )

                MacSettingsDivider()

                MacSettingsRow(title: "remote.lan_port", help: "remote.lan_port.help") {
                    TextField("", text: $lanPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 118)
                        .accessibilityLabel(localized("remote.lan_port"))
                }

                MacSettingsDivider()

                MacSettingsRow(title: "remote.tailscale_port", help: "remote.tailscale_port.help") {
                    TextField("", text: $tailscalePort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 118)
                        .accessibilityLabel(localized("remote.tailscale_port"))
                }

                MacSettingsDivider()

                MacSettingsRow(
                    title: "remote.direct.apply",
                    help: "remote.direct.apply_help"
                ) {
                    Button(localized("common.apply")) {
                        store.configureDirectMode(
                            lanPort: Int(lanPort) ?? 0,
                            tailscalePort: Int(tailscalePort) ?? 0,
                            sharingEnabled: sharingEnabled
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.state.busy)
                }
            }

            MacSettingsGroup("remote.endpoints.title") {
                if store.state.remoteManagement.listeningEndpoints.isEmpty {
                    MacSettingsRow(
                        title: "remote.endpoints.status",
                        help: "remote.endpoints.help"
                    ) {
                        Text(localized("remote.endpoints.unavailable"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    ForEach(store.state.remoteManagement.listeningEndpoints.indices, id: \.self) { index in
                        let endpoint = store.state.remoteManagement.listeningEndpoints[index]
                        if index > 0 {
                            MacSettingsDivider()
                        }
                        MacSettingsRow(
                            title: endpointTitle(endpoint),
                            help: endpointHelp(endpoint)
                        ) {
                            Text(endpoint)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(localizedFormat("common.full_value_help", endpoint))
                        }
                    }
                }

                if store.state.remoteManagement.sharingActive {
                    MacSettingsDivider()

                    MacSettingsRow(
                        title: "remote.pairing.current",
                        help: "remote.pairing.current_help"
                    ) {
                        HStack(spacing: 7) {
                            Text(store.state.remoteManagement.pairingKey)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .privacySensitive()
                                .frame(width: 112)
                            Button {
                                copy(store.state.remoteManagement.pairingKey)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help(localized("remote.pairing.copy"))
                        }
                    }
                }

                MacSettingsDivider()

                MacSettingsRow(
                    title: "remote.listener.actions",
                    help: "remote.security.description"
                ) {
                    HStack(spacing: 6) {
                        Button {
                            store.restartRemoteSharing()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help(localized("remote.listener.refresh"))

                        Button {
                            confirmingRotation = true
                        } label: {
                            Image(systemName: "key.horizontal")
                        }
                        .help(localized("remote.rotate.open"))
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.state.busy)
                }
            }
        }
    }

    private var remoteSettings: some View {
        MacSettingsGroup("settings.group.remote_target") {
            MacSettingsRow(title: "remote.host") {
                TextField("", text: $remoteHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .accessibilityLabel(localized("remote.host"))
            }

            MacSettingsDivider()

            MacSettingsRow(title: "remote.port") {
                TextField("", text: $remotePort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 118)
                    .accessibilityLabel(localized("remote.port"))
            }

            MacSettingsDivider()

            MacSettingsRow(
                title: "remote.pairing_key",
                help: "remote.pairing.hint"
            ) {
                SecureField("", text: $pairingKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .privacySensitive()
                    .accessibilityLabel(localized("remote.pairing_key"))
            }

            MacSettingsDivider()

            MacSettingsRow(title: "remote.connect", help: connectedEndpointHelp) {
                Button(localized("remote.connect")) {
                    store.configureRemoteMode(
                        host: remoteHost,
                        port: Int(remotePort) ?? 0,
                        pairingKey: pairingKey
                    )
                    pairingKey = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.state.busy || trimmed(remoteHost).isEmpty)
            }
        }
    }

    private var connectedEndpointHelp: String? {
        guard !store.state.remoteManagement.connectedEndpoint.isEmpty else { return nil }
        return localizedFormat(
            "remote.connected_endpoint",
            store.state.remoteManagement.connectedEndpoint
        )
    }

    private func endpointTitle(_ endpoint: String) -> String {
        endpoint.hasPrefix("100.") ? "remote.endpoint.tailscale" : "remote.endpoint.lan"
    }

    private func endpointHelp(_ endpoint: String) -> String {
        endpoint.hasPrefix("100.") ? "remote.endpoint.tailscale.help" : "remote.endpoint.lan.help"
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        mode = store.settings.effectiveManagementMode
        sharingEnabled = store.settings.effectiveRemoteSharingEnabled
        lanPort = String(store.settings.effectiveRemoteLANPort)
        tailscalePort = String(store.settings.effectiveRemoteTailscalePort)
        remoteHost = store.settings.remoteHost ?? ""
        remotePort = String(store.settings.effectiveRemotePort)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
