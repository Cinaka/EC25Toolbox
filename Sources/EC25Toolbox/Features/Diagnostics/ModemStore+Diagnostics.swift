import AVFAudio
import Foundation
import UserNotifications

@MainActor
extension ModemStore {
    /// Assembles a redacted diagnostics snapshot (R0) for support export.
    ///
    /// Phone numbers, SMS bodies, PINs, and APDU payloads never enter the
    /// snapshot by construction; command mirrors reuse the redacted
    /// `ATLogPrivacy` pipeline output. Notification and microphone
    /// permissions are read here because they need the guarded center and
    /// TCC state the pure builder cannot reach.
    func makeDiagnosticsSnapshot() async -> DiagnosticsSnapshot {
        let notificationAuthorizationStatus: String?
        if AppNotificationCenter.isAvailable {
            let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
            notificationAuthorizationStatus = String(describing: notificationSettings.authorizationStatus)
        } else {
            notificationAuthorizationStatus = "unavailable"
        }

        return DiagnosticsSnapshot.build(
            from: state,
            smsRefreshMode: SMSDiagnosticsRefreshMode(smsPDUModeUsable: smsPDUModeUsable),
            autoCleanEnabled: settings.smsAutoCleanAfterArchive ?? false,
            notificationAuthorizationStatus: notificationAuthorizationStatus,
            microphonePermissionStatus: String(describing: AVAudioApplication.shared.recordPermission),
            generatedAt: Date()
        )
    }
}
