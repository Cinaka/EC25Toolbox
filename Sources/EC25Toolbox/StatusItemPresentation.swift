import AppKit

enum MenuBarEventIndicator: Equatable {
    case unreadMessages(Int)
    case missedCalls(Int)
    case incomingCall
}

/// Native status-item projection: the cellular symbol remains the leading
/// image, while event-only SF Symbol attachments and counts appear beside it.
/// No event icon is shown permanently when its count/state is empty.
enum StatusItemPresentation {
    static func indicators(for state: ModemState) -> [MenuBarEventIndicator] {
        var result: [MenuBarEventIndicator] = []
        if state.unreadCount > 0 {
            result.append(.unreadMessages(state.unreadCount))
        }
        let missed = state.callLog.filter(\.isUnacknowledgedMissedCall).count
        if missed > 0 {
            result.append(.missedCalls(missed))
        }
        if state.call.phase == .incoming || state.call.phase == .answering {
            result.append(.incomingCall)
        }
        return result
    }

    static func attributedTitle(for indicators: [MenuBarEventIndicator]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, indicator) in indicators.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  "))
            }
            let (symbol, count): (String, Int?) = switch indicator {
            case let .unreadMessages(value): ("message.fill", value)
            case let .missedCalls(value): ("phone.arrow.down.left.fill", value)
            case .incomingCall: ("phone.fill", nil)
            }
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let configured = image.withSymbolConfiguration(
                    .init(pointSize: 12, weight: .medium)
                ) ?? image
                configured.isTemplate = true
                let attachment = NSTextAttachment()
                attachment.image = configured
                attachment.bounds = CGRect(x: 0, y: -2, width: 13, height: 13)
                result.append(NSAttributedString(attachment: attachment))
            }
            if let count {
                result.append(NSAttributedString(
                    string: "\(min(count, 99))",
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)]
                ))
            }
        }
        return result
    }
}
