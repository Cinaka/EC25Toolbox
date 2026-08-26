import SwiftUI

/// Message polling, notifications, archive cleanup, backup, and index repair
/// live together in Settings instead of occupying the Messages sidebar.
struct MessageManagementSettingsCard: View {
    @EnvironmentObject private var store: ModemStore

    private var notificationAuthorizationKey: String {
        (store.state.callNotificationAuthorization ?? .notDetermined).localizationKey
    }

    var body: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("settings.group.notifications") {
                MacSettingsRow(title: "settings.notification.title", help: "settings.notification.help") {
                    HStack(spacing: 10) {
                        Text(localized(notificationAuthorizationKey))
                            .foregroundStyle(.secondary)
                        if store.state.callNotificationAuthorization == .denied {
                            Button(localized("settings.notification.open_settings")) {
                                CallNotification.openSystemNotificationSettings()
                            }
                        } else {
                            Button(localized("settings.notification.request")) {
                                Task { await store.requestCallNotificationAuthorizationIfNeeded() }
                            }
                        }
                    }
                }
            }

            MacSettingsGroup("settings.messages.delivery") {
                MacSettingsRow(title: "settings.sms_interval.title", help: "settings.sms_interval.help") {
                    RightAlignedMenuPicker(
                        selection: Binding(
                            get: { store.settings.smsPollSeconds },
                            set: { value in store.updateSettings { $0.smsPollSeconds = value } }
                        ),
                        options: [.init(title: localized("common.off"), value: 0)]
                            + [15, 30, 60, 120].map {
                                .init(title: localizedFormat("format.seconds", $0), value: $0)
                            }
                    )
                    .frame(width: 96)
                }
                MacSettingsDivider()
                MacSettingsToggleRow(
                    title: "settings.sms_autoclean.title",
                    help: "settings.sms_autoclean.help",
                    isOn: Binding(
                        get: { store.settings.smsAutoCleanAfterArchive ?? false },
                        set: { value in store.updateSettings { $0.smsAutoCleanAfterArchive = value } }
                    )
                )
            }

            MacSettingsGroup("settings.messages.storage") {
                MacSettingsRow(title: "sms.backup.title", help: "sms.backup.settings_help") {
                    HStack(spacing: 8) {
                        Button(localized("sms.backup.restore")) { store.restoreSMSFromICloudDrive() }
                            .disabled(store.state.busy || store.state.smsBackup.iCloudBackupPath == nil)
                        Button(localized("sms.backup.now")) { store.backupSMSNow() }
                            .disabled(store.state.busy || store.state.smsBackup.iCloudBackupPath == nil)
                    }
                }
                MacSettingsDivider()
                MacSettingsRow(title: "sms.index.title", help: "sms.index.rebuild.note") {
                    Button(localized("sms.index.rebuild")) { store.rebuildSMSIndex() }
                        .disabled(store.state.busy)
                }
            }
        }
    }
}
