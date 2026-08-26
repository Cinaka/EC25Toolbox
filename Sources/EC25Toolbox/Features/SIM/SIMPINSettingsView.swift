import SwiftUI

/// Settings page for SIM lock, PIN changes, and guarded automatic unlocking.
struct SIMPINSettingsCard: View {
    @EnvironmentObject private var store: ModemStore
    @State private var pin = ""
    @State private var autoUnlock = false
    @State private var lockEnabled = false
    @State private var currentPIN = ""
    @State private var newPIN = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("settings.group.sim_status") {
                VStack(alignment: .leading, spacing: 10) {
                    ParameterGrid(values: [
                        ParameterValue(label: "sim_pin.status.label", value: statusValue),
                        ParameterValue(label: "sim_pin.lock.label", value: lockValue),
                        ParameterValue(label: "sim_pin.retries.pin", value: retryValue(store.state.simSecurity.pinRetries)),
                        ParameterValue(label: "sim_pin.retries.puk", value: retryValue(store.state.simSecurity.pukRetries))
                    ], columnCount: 2, showsCellBackground: false)

                    if store.state.simSecurity.requiresPUK {
                        Label(localized("sim_pin.puk_warning"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if store.state.simSecurity.requiresPIN {
                        Label(
                            localized("sim_pin.service_warning.description"),
                            systemImage: "antenna.radiowaves.left.and.right.slash"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error = store.state.simSecurity.lastError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }

            MacSettingsGroup("settings.group.sim_lock") {
                MacSettingsRow(
                    title: "sim_pin.current.placeholder",
                    help: "sim_pin.current.help"
                ) {
                    HStack(spacing: 7) {
                        SecureField(localized("sim_pin.current.placeholder"), text: $pin)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: store.state.simSecurity.requiresPIN ? 112 : 150)

                        if store.state.simSecurity.requiresPIN {
                            Button(localized("sim_pin.action.unlock")) {
                                store.unlockSIM(
                                    pin: pin,
                                    rememberForAutomaticUnlock: autoUnlock
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(actionDisabled)
                        }
                    }
                }

                MacSettingsDivider()

                MacSettingsRow(
                    title: "sim_pin.lock_control.title",
                    help: "sim_pin.lock_control.help"
                ) {
                    Toggle("", isOn: Binding(
                        get: { lockEnabled },
                        set: { enabled in
                            lockEnabled = enabled
                            store.setSIMLockEnabled(enabled, pin: pin)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(AppControlPalette.accent)
                    .disabled(
                        store.state.busy
                            || !store.state.simSecurity.isReady
                            || !isValidPIN(pin)
                    )
                }

                MacSettingsDivider()

                MacSettingsRow(
                    title: "sim_pin.auto_unlock.title",
                    help: "sim_pin.auto_unlock.help"
                ) {
                    Toggle("", isOn: Binding(
                        get: { autoUnlock },
                        set: { enabled in
                            autoUnlock = enabled
                            store.configureSIMAutoUnlock(enabled: enabled, pin: pin)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(AppControlPalette.accent)
                    .disabled(
                        store.state.busy
                            || store.state.simSecurity.iccid.isEmpty
                            || (!autoUnlock && !isValidPIN(pin))
                    )
                }
            }

            MacSettingsGroup("settings.group.sim_change") {
                MacSettingsRow(title: "sim_pin.change.current") {
                    SecureField(localized("sim_pin.change.current"), text: $currentPIN)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }

                MacSettingsDivider()

                MacSettingsRow(title: "sim_pin.change.new") {
                    SecureField(localized("sim_pin.change.new"), text: $newPIN)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }

                MacSettingsDivider()

                MacSettingsRow(title: "sim_pin.change.confirm") {
                    SecureField(localized("sim_pin.change.confirm"), text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }

                MacSettingsDivider()

                MacSettingsRow(
                    title: "sim_pin.action.change",
                    help: "sim_pin.change.help"
                ) {
                    Button(localized("sim_pin.action.change")) {
                        store.changeSIMPIN(
                            currentPIN: currentPIN,
                            newPIN: newPIN,
                            confirmation: confirmation
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        store.state.busy
                            || !store.state.simSecurity.isReady
                            || !isValidPIN(currentPIN)
                            || !isValidPIN(newPIN)
                            || newPIN != confirmation
                    )
                }
            }
        }
        .onAppear {
            autoUnlock = store.settings.simAutoUnlock ?? false
            lockEnabled = store.state.simSecurity.lockEnabled ?? false
        }
        .onChange(of: store.settings.simAutoUnlock) { _, value in
            autoUnlock = value ?? false
        }
        .onChange(of: store.state.simSecurity.lockEnabled) { _, value in
            if let value {
                lockEnabled = value
            }
        }
        .onChange(of: store.state.simSecurity.status) { _, value in
            if value.caseInsensitiveCompare("READY") == .orderedSame {
                pin = ""
            }
        }
    }

    private var actionDisabled: Bool {
        store.state.busy || !isValidPIN(pin)
    }

    private var statusValue: String {
        switch store.state.simSecurity.status.uppercased() {
        case "READY": "sim_pin.status.ready"
        case "SIM PIN": "sim_pin.status.pin_required"
        case "SIM PUK": "sim_pin.status.puk_required"
        case "-": "-"
        default: store.state.simSecurity.status
        }
    }

    private var lockValue: String {
        switch store.state.simSecurity.lockEnabled {
        case true: "sim_pin.lock.enabled"
        case false: "sim_pin.lock.disabled"
        case nil: "common.unknown"
        }
    }

    private func retryValue(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }

    private func isValidPIN(_ value: String) -> Bool {
        (try? normalizedSIMPIN(value)) != nil
    }
}
