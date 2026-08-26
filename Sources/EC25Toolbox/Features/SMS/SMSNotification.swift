import Foundation
import UserNotifications

/// System notifications for newly arrived SMS. Posting happens strictly after
/// the archive write, so a banner never announces a message that failed to
/// persist. Bodies are only ever shown as a short redacted preview.
enum SMSNotification {
    /// Request identifiers are `requestIDPrefix + message.id`; this also lets
    /// the notification delegate route banner taps back to the SMS tab.
    static let requestIDPrefix = "ing.fuyaoskyrocket.ec25toolbox.sms."
    static let moduleUserInfoKey = "moduleID"

    /// Incoming messages in `current` that were absent from `previous`: not
    /// outgoing, still unread, and with a fresh archive id.
    static func freshIncoming(previous: [SMSMessage], current: [SMSMessage]) -> [SMSMessage] {
        let previousIDs = Set(previous.map(\.id))
        return current.filter {
            !$0.outgoing && $0.unread && !previousIDs.contains($0.id)
        }
    }

    /// Short redacted preview: whitespace runs collapse, and at most
    /// `visibleCharacters` characters of the body leak into the banner.
    static func redactedPreview(of body: String, visibleCharacters: Int = 16) -> String {
        let collapsed = body
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else {
            return localized("sms.notification.no_preview")
        }
        guard collapsed.count > visibleCharacters else { return collapsed }
        return String(collapsed.prefix(visibleCharacters)) + "…"
    }

    /// Posts one banner per message. Delivery or permission failure never
    /// affects modem or archive operation.
    static func postNewMessage(
        senderDisplay: String,
        preview: String,
        identifier: String,
        moduleID: String = CallNotification.defaultModuleID,
        moduleName: String? = nil
    ) {
        guard AppNotificationCenter.isAvailable else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }

                let content = UNMutableNotificationContent()
                content.title = senderDisplay
                content.body = preview
                content.subtitle = moduleName ?? ""
                content.sound = .default
                content.userInfo[moduleUserInfoKey] = moduleID

                let request = UNNotificationRequest(
                    identifier: requestIDPrefix + moduleID + "." + identifier,
                    content: content,
                    trigger: nil
                )
                try await center.add(request)
            } catch {
                // Notification permission or delivery failure must not affect modem operation.
            }
        }
    }

    static func moduleID(from notification: UNNotification) -> String {
        notification.request.content.userInfo[moduleUserInfoKey] as? String
            ?? CallNotification.defaultModuleID
    }
}
