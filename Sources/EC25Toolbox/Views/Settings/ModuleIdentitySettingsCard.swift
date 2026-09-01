import SwiftUI

/// Persistent names and hardware identities for every module the app has
/// discovered. Runtime selection remains in the device summary; this card is
/// the durable management surface and keeps disconnected modules editable.
struct ModuleIdentitySettingsCard: View {
    @EnvironmentObject private var coordinator: ModemSessionCoordinator
    @State private var pendingUnbind: USBModemDescriptor?
    @State private var pendingForget: USBModemDescriptor?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MacSettingsGroup("settings.module.identity.group") {
                if coordinator.knownDevices.isEmpty {
                    MacSettingsRow(
                        title: "settings.module.identity.empty",
                        help: "settings.module.identity.help"
                    ) {
                        Text(localized("device.waiting"))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(coordinator.knownDevices.enumerated(), id: \.element.moduleID) { index, descriptor in
                        moduleRow(descriptor)
                        if index < coordinator.knownDevices.count - 1 {
                            MacSettingsDivider()
                        }
                    }
                }
            }

            if !coordinator.unboundDevices.isEmpty {
                MacSettingsGroup("settings.module.unbound.group") {
                    ForEach(coordinator.unboundDevices.enumerated(), id: \.element.moduleID) { index, descriptor in
                        unboundRow(descriptor)
                        if index < coordinator.unboundDevices.count - 1 {
                            MacSettingsDivider()
                        }
                    }
                }
            }
        }
        .alert(
            localized("settings.module.unbind.confirm.title"),
            isPresented: Binding(
                get: { pendingUnbind != nil },
                set: { if !$0 { pendingUnbind = nil } }
            ),
            presenting: pendingUnbind
        ) { descriptor in
            Button(localized("common.cancel"), role: .cancel) {}
            Button(localized("settings.module.unbind.confirm.action"), role: .destructive) {
                coordinator.unbindDevice(descriptor.moduleID)
                pendingUnbind = nil
            }
        } message: { descriptor in
            Text(localizedFormat(
                "settings.module.unbind.confirm.message",
                descriptor.imei ?? descriptor.displaySerial
            ))
        }
        .alert(
            localized("settings.module.forget.confirm.title"),
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            presenting: pendingForget
        ) { descriptor in
            Button(localized("common.cancel"), role: .cancel) {}
            Button(localized("settings.module.forget.confirm.action"), role: .destructive) {
                coordinator.forgetUnboundDevice(descriptor.moduleID)
                pendingForget = nil
            }
        } message: { descriptor in
            Text(localizedFormat(
                "settings.module.forget.confirm.message",
                descriptor.imei ?? descriptor.displaySerial
            ))
        }
    }

    private func moduleRow(_ descriptor: USBModemDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(coordinator.displayName(for: descriptor))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    moduleIdentityView(descriptor, prominent: false)
                    usbIdentityView(descriptor)
                }

                Spacer(minLength: 12)

                Label(
                    localized(coordinator.availableDeviceIDs.contains(descriptor.id)
                        ? "status.online" : "status.offline"),
                    systemImage: coordinator.availableDeviceIDs.contains(descriptor.id)
                        ? "checkmark.circle.fill" : "circle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(coordinator.availableDeviceIDs.contains(descriptor.id)
                    ? Color.accentColor : Color.secondary)
            }

            TextField(
                localized("settings.module.note.placeholder"),
                text: Binding(
                    get: { coordinator.note(for: descriptor.moduleID) },
                    set: { coordinator.setNote($0, for: descriptor.moduleID) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .help(localized("settings.module.note.help"))

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(localized("settings.module.unbind.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(role: .destructive) {
                    pendingUnbind = descriptor
                } label: {
                    Label(localized("settings.module.unbind.action"), systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func unboundRow(_ descriptor: USBModemDescriptor) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                moduleIdentityView(descriptor, prominent: true)
                Text(localized("settings.module.unbound.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                Button(localized("settings.module.rebind.action")) {
                    coordinator.bindDevice(descriptor.moduleID)
                }
                Button(role: .destructive) {
                    pendingForget = descriptor
                } label: {
                    Label(localized("settings.module.forget.action"), systemImage: "trash")
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func moduleIdentityView(_ descriptor: USBModemDescriptor, prominent: Bool) -> some View {
        if let imei = descriptor.imei {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(localized("parameter.imei.label"))
                    .font(prominent ? .body.weight(.medium) : .caption)
                Text(imei)
                    .font((prominent ? Font.body.weight(.medium) : .caption).monospaced())
                    .textSelection(.enabled)
            }
            .foregroundStyle(prominent ? .primary : .secondary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(localized("module.identity.pending.label"))
                    .font(prominent ? .body.weight(.medium) : .caption)
                Text(descriptor.displaySerial)
                    .font((prominent ? Font.body.weight(.medium) : .caption).monospaced())
                    .textSelection(.enabled)
            }
            .foregroundStyle(prominent ? .primary : .secondary)
        }
    }

    private func usbIdentityView(_ descriptor: USBModemDescriptor) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("USB")
                .font(.caption2)
            Text(descriptor.displaySerial)
                .font(.caption2.monospaced())
            Text("·")
                .font(.caption2)
            Text(descriptor.usbIdentity)
                .font(.caption2.monospaced())
        }
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
}
