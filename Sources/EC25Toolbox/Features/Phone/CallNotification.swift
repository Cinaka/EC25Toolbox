import AppKit
import Foundation
import UserNotifications

/// System notifications for incoming calls: a dedicated category with
/// “answer”, “decline”, and “open” actions. Authorization is requested early
/// (launch/settings) — never mid-ring — and the banner only posts when the
/// system can actually deliver it.
enum CallNotification {
    static let categoryID = "ing.fuyaoskyrocket.ec25toolbox.call"
    static let answerActionID = categoryID + ".answer"
    static let declineActionID = categoryID + ".decline"
    static let openActionID = categoryID + ".open"
    static let incomingRequestID = categoryID + ".incoming"
    static let defaultModuleID = "default"
    static let moduleUserInfoKey = "moduleID"

    /// Why an incoming-call banner is being removed (R8). Retraction is a
    /// user- or modem-attributable event — a raw CLCC anomaly never retracts.
    enum RetractReason: String, Sendable {
        /// The user accepted the call; the answering surface takes over.
        case userAnswered
        /// The user rejected the call or hung up while answering.
        case userEnded
        /// The call genuinely concluded (remote hang-up, missed, timeout).
        case callEnded
        /// The posting call epoch was superseded by a newer call.
        case epochSuperseded
    }

    /// Epoch of the call whose banner is currently posted, if any. Binds
    /// retraction to the posting call so a stale transition can never remove
    /// a newer call's banner (R8). MainActor because post/retract only run
    /// on the UI actor that owns the call machine.
    @MainActor private static var postedCallEpochs: [String: Int] = [:]

    /// Epoch whose banner is currently posted, for tests and diagnostics.
    @MainActor static var postedBannerEpoch: Int? { postedCallEpochs[defaultModuleID] }

    @MainActor static func postedBannerEpoch(for moduleID: String) -> Int? {
        postedCallEpochs[moduleID]
    }

    /// Last banner body posted or replaced, and how many in-place content
    /// replacements happened — test observability for R12 (same identifier,
    /// no second banner).
    @MainActor private(set) static var lastBannerBody: String?
    @MainActor private(set) static var bannerReplaceCount = 0

    /// Resets the R12 test-observability counters. Tests only.
    @MainActor static func resetTestObservability() {
        postedCallEpochs.removeAll()
        lastBannerBody = nil
        bannerReplaceCount = 0
    }

    /// Registers the call category. Safe to call before authorization.
    static func registerCategory() {
        guard AppNotificationCenter.isAvailable else { return }
        let answer = UNNotificationAction(
            identifier: answerActionID,
            title: localized("action.answer"),
            options: []
        )
        let decline = UNNotificationAction(
            identifier: declineActionID,
            title: localized("action.decline"),
            options: []
        )
        let open = UNNotificationAction(
            identifier: openActionID,
            title: localized("action.open_window"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [answer, decline, open],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Requests alert+sound authorization once, while nothing rings. Calling
    /// again after a decision (granted or denied) is a no-op — the system only
    /// prompts from `.notDetermined`.
    static func requestAuthorizationIfNeeded() async -> NotificationAuthorizationState? {
        guard AppNotificationCenter.isAvailable else { return nil }
        let center = UNUserNotificationCenter.current()
        let initial = await center.notificationSettings()
        if initial.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                // Authorization failures must never disturb modem operation.
                return nil
            }
        }
        let resolved = await center.notificationSettings()
        return NotificationAuthorizationState(status: resolved.authorizationStatus.rawValue)
    }

    /// Current authorization, or nil when the notification center is
    /// unreachable (non-app processes).
    static func authorizationStatus() async -> NotificationAuthorizationState? {
        guard AppNotificationCenter.isAvailable else { return nil }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationAuthorizationState(status: settings.authorizationStatus.rawValue)
    }

    /// Opens the system Notifications preference pane so a user who denied
    /// authorization can grant it without hunting for System Settings.
    static func openSystemNotificationSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        )
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Posts one incoming-call banner for the given call epoch. The content
    /// comes from the shared caller-identity derivator (R12). Authorization
    /// is checked first — a call is never the moment to raise a permission
    /// prompt.
    @MainActor static func postIncomingCall(
        title: String,
        body: String,
        epoch: Int,
        moduleID: String = defaultModuleID,
        moduleName: String? = nil
    ) {
        postedCallEpochs[moduleID] = epoch
        lastBannerBody = body
        guard AppNotificationCenter.isAvailable else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.subtitle = moduleName ?? ""
            content.sound = .default
            content.categoryIdentifier = categoryID
            content.userInfo[moduleUserInfoKey] = moduleID

            let request = UNNotificationRequest(
                identifier: requestID(for: moduleID),
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                // Notification delivery failure must not affect modem operation.
            }
        }
    }

    /// Replaces the posted banner's content in place (R12): the same stable
    /// request identifier, the same category, and the same epoch-bound
    /// answer/decline actions — a late CLIP number or contact name only
    /// changes the text, never the call semantics. A stale epoch never
    /// touches a newer call's banner.
    @MainActor static func replaceIncomingCallContent(
        title: String,
        body: String,
        epoch: Int,
        moduleID: String = defaultModuleID,
        moduleName: String? = nil
    ) {
        guard postedCallEpochs[moduleID] == epoch else { return }
        lastBannerBody = body
        bannerReplaceCount += 1
        guard AppNotificationCenter.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let requestID = requestID(for: moduleID)
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.subtitle = moduleName ?? ""
            content.sound = nil
            content.categoryIdentifier = categoryID
            content.userInfo[moduleUserInfoKey] = moduleID

            let request = UNNotificationRequest(
                identifier: requestID,
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                // Replacement failure must not affect modem operation.
            }
        }
    }

    /// Removes the incoming-call banner. Only a retract addressed to the
    /// epoch that posted the banner acts; a stale epoch from an older call
    /// leaves a newer call's banner in place (R8). The reason is recorded by
    /// the caller in the call timeline.
    @MainActor static func retractIncomingCall(
        reason: RetractReason,
        epoch: Int,
        moduleID: String = defaultModuleID
    ) {
        guard postedCallEpochs[moduleID] == epoch else { return }
        postedCallEpochs.removeValue(forKey: moduleID)
        guard AppNotificationCenter.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let requestID = requestID(for: moduleID)
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    static func requestID(for moduleID: String) -> String {
        moduleID == defaultModuleID ? incomingRequestID : incomingRequestID + "." + moduleID
    }

    static func moduleID(from notification: UNNotification) -> String {
        notification.request.content.userInfo[moduleUserInfoKey] as? String ?? defaultModuleID
    }
}

/// Routes call-notification actions back into the app on the main actor.
@MainActor
final class CallNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onAnswer: (() -> Void)?
    var onDecline: (() -> Void)?
    var onOpen: (() -> Void)?
    var onOpenSMS: (() -> Void)?
    var onAnswerDevice: ((String) -> Void)?
    var onDeclineDevice: ((String) -> Void)?
    var onOpenDevice: ((String) -> Void)?
    var onOpenSMSDevice: ((String) -> Void)?
    /// True while an operable in-app call surface is on screen; only then are
    /// foreground banners suppressed (R2). Always evaluated on the main actor.
    var isCallSurfaceVisible: @MainActor (String) -> Bool = { _ in false }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let requestID = response.notification.request.identifier
        let moduleID = response.notification.request.content.userInfo[
            CallNotification.moduleUserInfoKey
        ] as? String ?? CallNotification.defaultModuleID
        Task { @MainActor in
            if requestID.hasPrefix(SMSNotification.requestIDPrefix) {
                if let onOpenSMSDevice = self.onOpenSMSDevice {
                    onOpenSMSDevice(moduleID)
                } else {
                    self.onOpenSMS?()
                }
                return
            }
            guard requestID.hasPrefix(CallNotification.incomingRequestID) else { return }
            switch action {
            case CallNotification.answerActionID:
                if let onAnswerDevice = self.onAnswerDevice {
                    onAnswerDevice(moduleID)
                } else {
                    self.onAnswer?()
                }
            case CallNotification.declineActionID:
                if let onDeclineDevice = self.onDeclineDevice {
                    onDeclineDevice(moduleID)
                } else {
                    self.onDecline?()
                }
            case CallNotification.openActionID, UNNotificationDefaultActionIdentifier:
                if let onOpenDevice = self.onOpenDevice {
                    onOpenDevice(moduleID)
                } else {
                    self.onOpen?()
                }
            default:
                break
            }
        }
        // The routing task never needs to block notification handling.
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard notification.request.identifier.hasPrefix(CallNotification.incomingRequestID) else {
            // Other categories (e.g. SMS) keep their own presentation policy.
            return [.banner, .sound, .list]
        }
        // Suppress only when an operable call surface is actually visible; an
        // active app with no call UI on screen still gets the banner.
        let moduleID = CallNotification.moduleID(from: notification)
        let surfaceVisible = await isCallSurfaceVisible(moduleID)
        return surfaceVisible ? [] : [.banner, .sound, .list]
    }
}
