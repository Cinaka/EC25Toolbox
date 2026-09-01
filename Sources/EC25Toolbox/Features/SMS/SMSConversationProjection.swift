import Combine
import Foundation

/// Grouped SMS conversation used by the message list.
struct Conversation: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var messages: [SMSMessage]
    var last: SMSMessage
    var unread: Int
}

/// Cached conversation projection for one module store.
///
/// Grouping, per-group sorting, and unread counting used to run inside the
/// SMS view's `body`, re-executing on every store invalidation (GNSS ticks,
/// log lines, poll churn). This model recomputes only when the message
/// collection — or the localized unknown-sender label — actually changes, so
/// feature pages observe a narrow, stable value instead of the whole state.
@MainActor
final class SMSConversationProjectionModel: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []

    private var cancellable: AnyCancellable?
    private var fingerprint: Fingerprint?

    private struct Fingerprint: Equatable {
        var messages: [SMSMessage]
        var unknownLabel: String
    }

    /// Binds the projection to its owning store. Called once from the store's
    /// initializer; the subscription holds the store weakly.
    func attach(store: ModemStore) {
        guard cancellable == nil else { return }
        recompute(from: store)
        cancellable = store.objectWillChange.sink { [weak self, weak store] _ in
            guard let self, let store else { return }
            // objectWillChange fires before the mutation lands; re-derive on
            // the next main-queue turn so the projection reads settled state.
            DispatchQueue.main.async {
                self.recompute(from: store)
            }
        }
    }

    private func recompute(from store: ModemStore) {
        let unknownLabel = localized("common.unknown")
        let messages = store.state.messages
        guard messages != fingerprint?.messages || unknownLabel != fingerprint?.unknownLabel else {
            return
        }
        fingerprint = Fingerprint(messages: messages, unknownLabel: unknownLabel)
        conversations = Self.project(messages: messages, unknownLabel: unknownLabel)
    }

    /// Pure projection shared by the live model and tests. The unknown-sender
    /// label is captured at projection time so conversation keys stay stable
    /// within one language and re-localize when the app language changes.
    static func project(messages: [SMSMessage], unknownLabel: String) -> [Conversation] {
        let groups = Dictionary(grouping: messages) { message in
            message.sender.isEmpty || message.sender == "-" ? unknownLabel : message.sender
        }
        return groups.compactMap { key, messages in
            let sorted = messages.sorted {
                let left = $0.instant ?? .distantPast
                let right = $1.instant ?? .distantPast
                if left != right { return left < right }
                return $0.id < $1.id
            }
            guard let last = sorted.last else { return nil }
            return Conversation(key: key, messages: sorted, last: last, unread: sorted.filter(\.unread).count)
        }
        .sorted {
            let left = $0.last.instant ?? .distantPast
            let right = $1.last.instant ?? .distantPast
            if left != right { return left > right }
            return $0.key < $1.key
        }
    }
}
