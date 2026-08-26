import AppKit
import SwiftUI

/// Grouped SMS conversation used by the message list.
struct Conversation: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var messages: [SMSMessage]
    var last: SMSMessage
    var unread: Int
}

/// Shared SMS chrome dimensions keep the conversation and thread columns on
/// the same baseline regardless of message count or localized text length.
enum SMSLayoutMetrics {
    static let primaryHeaderHeight: CGFloat = 54
    static let recipientRowHeight: CGFloat = 36
    static let composerControlHeight: CGFloat = 34

    /// Messages keeps bubbles comfortably narrower than the thread instead of
    /// stretching long carrier notices across the entire detail pane.
    static func bubbleMaxWidth(for threadWidth: CGFloat) -> CGFloat {
        min(360, max(190, threadWidth * 0.72))
    }
}

@MainActor
extension SMSMessage {
    /// Unified display label for this message's service time; messages whose
    /// timestamp never parsed show "时间未知" instead of a raw modem string.
    func displayTime(role: DateTimeDisplayRole) -> String {
        guard let instant else { return localized("sms.time.unknown") }
        return AppDateTimeFormatter.shared.string(
            from: instant, role: role, sourceTimeZoneOffsetSeconds: sourceTimeZoneOffsetSeconds
        )
    }

    /// Hover text describing the captured source time zone. The raw SCTS
    /// itself is never shown; only the derived offset label is.
    var sourceZoneHelp: String {
        guard instant != nil else { return localized("sms.time.unknown") }
        guard let seconds = sourceTimeZoneOffsetSeconds else {
            return localized("sms.time.source_zone_unknown")
        }
        let sign = seconds >= 0 ? "+" : "-"
        let label = String(format: "UTC%@%02d:%02d", sign, abs(seconds) / 3600, abs(seconds) / 60 % 60)
        return localizedFormat("sms.time.source_zone_tooltip", label)
    }
}

/// Apple Messages-style SMS center with a conversation sidebar and persistent thread detail.
struct SMSView: View {
    @EnvironmentObject private var store: ModemStore
    @EnvironmentObject private var presentation: WindowPresentationModel
    @Environment(\.presentationSurface) private var surface
    @State private var activeSender: String?
    @State private var draftTo = ""
    @State private var draftBody = ""
    @State private var searchQuery = ""

    private var conversations: [Conversation] {
        let groups = Dictionary(grouping: store.state.messages) { message in
            message.sender.isEmpty || message.sender == "-" ? localized("common.unknown") : message.sender
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

    private var filteredConversations: [Conversation] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return conversations }
        return conversations.filter { conversation in
            conversation.key.localizedCaseInsensitiveContains(needle)
                || conversation.messages.contains { $0.body.localizedCaseInsensitiveContains(needle) }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                conversationSidebar
                    .frame(width: sidebarWidth(for: geometry.size.width))
                    .background(.regularMaterial)

                Divider().opacity(0.45)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: selectInitialConversation)
        .onChange(of: conversations.map(\.id)) { _, _ in
            keepSelectionValid()
        }
        .onAppear(perform: consumePendingRecipient)
        .onChange(of: presentation.pendingSMSRecipient) { _, _ in
            consumePendingRecipient()
        }
    }

    /// Stable widths avoid a resizable split view becoming another source of
    /// popover state restoration. The window gets a slightly wider Messages
    /// sidebar while the 640 pt popover keeps enough room for the thread.
    private func sidebarWidth(for workspaceWidth: CGFloat) -> CGFloat {
        switch surface {
        case .popover:
            260
        case .standaloneWindow:
            min(320, max(260, workspaceWidth * 0.34))
        }
    }

    /// Adopts a recipient handed over from the contacts browser by opening a
    /// fresh draft addressed to it.
    private func consumePendingRecipient() {
        guard let recipient = presentation.pendingSMSRecipient else { return }
        presentation.pendingSMSRecipient = nil
        draftTo = recipient
        draftBody = ""
        activeSender = ""
    }

    private var conversationSidebar: some View {
        Group {
            if conversations.isEmpty {
                EmptyState(title: "sms.empty.title", subtitle: "sms.empty.description", systemImage: "message")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                if filteredConversations.isEmpty {
                    SearchNoResultsState()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: selectedConversation) {
                        ForEach(filteredConversations) { conversation in
                            ConversationRow(conversation: conversation)
                                .tag(conversation.key)
                        }
                    }
                    .listStyle(.sidebar)
                    // Messages keeps its conversation rows close to the
                    // sidebar edges; the native List otherwise adds a second
                    // horizontal content margin inside this already-bounded
                    // column.
                    .contentMargins(.horizontal, 2, for: .scrollContent)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            conversationToolbar
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }

    private var conversationToolbar: some View {
        HStack(spacing: 6) {
            CompactSearchField(text: $searchQuery, promptKey: "sms.search.placeholder")
                .frame(minWidth: 0)
                .layoutPriority(1)

            Button(action: beginNewMessage) {
                Image(systemName: "square.and.pencil")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(localized("sms.new_message"))

            Menu {
                Button {
                    store.markAllRead()
                } label: {
                    Label(localized("sms.mark_all_read"), systemImage: "envelope.open")
                }
                .disabled(store.state.unreadCount == 0 || store.state.busy)

                Button {
                    store.refreshMessages()
                } label: {
                    Label(localized("sms.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.state.busy)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(localized("sms.actions.more"))
        }
        .padding(.horizontal, 10)
        .frame(height: SMSLayoutMetrics.primaryHeaderHeight)
    }

    private func beginNewMessage() {
        draftTo = ""
        draftBody = ""
        activeSender = ""
    }

    @ViewBuilder
    private var detail: some View {
        if let sender = activeSender {
            ThreadView(
                sender: sender,
                conversation: conversations.first { $0.key == sender },
                draftTo: $draftTo,
                draftBody: $draftBody
            )
        } else {
            EmptyState(
                title: "sms.select_conversation.title",
                subtitle: "sms.select_conversation.description",
                systemImage: "message"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedConversation: Binding<String?> {
        Binding {
            activeSender
        } set: { newValue in
            guard let sender = newValue else {
                activeSender = nil
                return
            }
            activeSender = sender
            draftTo = sender
            if conversations.first(where: { $0.key == sender })?.unread ?? 0 > 0 {
                store.markConversationRead(sender: sender)
            }
        }
    }

    private func selectInitialConversation() {
        guard activeSender == nil, let first = conversations.first else { return }
        activeSender = first.key
        draftTo = first.key
        if first.unread > 0 {
            store.markConversationRead(sender: first.key)
        }
    }

    private func keepSelectionValid() {
        guard let activeSender else {
            selectInitialConversation()
            return
        }
        if activeSender.isEmpty { return }
        guard conversations.contains(where: { $0.key == activeSender }) else {
            self.activeSender = conversations.first?.key
            draftTo = conversations.first?.key ?? ""
            return
        }
    }
}

struct ConversationRow: View {
    var conversation: Conversation

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(conversation.unread > 0 ? AppControlPalette.accent.opacity(0.16) : Color.secondary.opacity(0.12))
                Text(avatarText(conversation.key))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(conversation.unread > 0 ? AppControlPalette.accent : Color.secondary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(localized(conversation.key))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(localizedFormat("common.full_value_help", localized(conversation.key)))

                Text(conversation.last.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(localizedFormat("common.full_value_help", conversation.last.body))

                HStack(spacing: 6) {
                    Text(conversation.last.displayTime(role: .compact))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help(conversation.last.sourceZoneHelp)

                    Spacer(minLength: 4)

                    Text(conversation.unread > 0 ? "\(conversation.unread)" : "\(conversation.messages.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(conversation.unread > 0 ? AppControlPalette.accent : Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    private func avatarText(_ name: String) -> String {
        let digits = name.filter(\.isNumber)
        if digits.count >= 2 { return String(digits.suffix(2)) }
        return String(name.prefix(2)).uppercased()
    }
}

struct ThreadView: View {
    @EnvironmentObject private var store: ModemStore
    var sender: String
    var conversation: Conversation?
    @Binding var draftTo: String
    @Binding var draftBody: String

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 9) {
                    if let conversation {
                        ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                            if shouldShowDateSeparator(at: index, messages: conversation.messages) {
                                Text(message.displayTime(role: .dateOnly))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 5)
                            }
                            MessageBubble(
                                message: message,
                                maxWidth: SMSLayoutMetrics.bubbleMaxWidth(for: geometry.size.width)
                            )
                        }
                    } else {
                        EmptyState(title: "sms.compose.empty_title", subtitle: "sms.compose.empty_description", systemImage: "square.and.pencil")
                            .frame(height: 220)
                    }
                }
                .padding(12)
            }
        }
        // Long conversations still open at the newest message and follow
        // appended content. Omitting the `.alignment` role keeps a short
        // conversation top-aligned instead of creating a large empty header.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .safeAreaBar(edge: .top, spacing: 0) {
            threadHeader
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            ComposerCard(draftTo: $draftTo, draftBody: $draftBody, sender: sender)
                .padding(10)
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }

    private var threadHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppControlPalette.accent.opacity(0.14))
                    Image(systemName: "person.fill")
                        .foregroundStyle(AppControlPalette.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(sender.isEmpty ? localized("sms.new_message") : sender)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(conversation.map { localizedFormat("sms.messages_count", $0.messages.count) } ?? localized("sms.new_conversation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                if let conversation {
                    Button {
                        conversation.messages.forEach { store.deleteSMS($0) }
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(localized("sms.clear_conversation"))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: SMSLayoutMetrics.primaryHeaderHeight)

            if sender.isEmpty {
                Divider().opacity(0.35)
                HStack(spacing: 8) {
                    Text(localized("sms.recipient.label"))
                        .foregroundStyle(.secondary)
                    TextField(localized("sms.recipient.placeholder"), text: $draftTo)
                        .textFieldStyle(.plain)
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(height: SMSLayoutMetrics.recipientRowHeight)
            }
        }
    }

    private func shouldShowDateSeparator(at index: Int, messages: [SMSMessage]) -> Bool {
        guard let current = messages[index].instant else { return index == 0 }
        guard index > 0, let previous = messages[index - 1].instant else { return true }
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }
}

struct ComposerCard: View {
    @EnvironmentObject private var store: ModemStore
    @Binding var draftTo: String
    @Binding var draftBody: String
    var sender: String

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(localized("sms.body.placeholder"), text: $draftBody, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minHeight: SMSLayoutMetrics.composerControlHeight)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                    .help(localized("sms.body.help"))

                Button {
                    store.sendSMS(to: draftTo, body: draftBody)
                    draftBody = ""
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .frame(
                    width: SMSLayoutMetrics.composerControlHeight,
                    height: SMSLayoutMetrics.composerControlHeight
                )
                .tint(AppControlPalette.accent)
                .help(localized("action.send"))
                .disabled(store.state.busy || trimmed(draftTo).isEmpty || trimmed(draftBody).isEmpty)
            }
        }
    }
}

struct MessageBubble: View {
    @EnvironmentObject private var store: ModemStore
    var message: SMSMessage
    var maxWidth: CGFloat = 360

    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 42) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 6) {
                if let binaryKind = message.binaryKind {
                    Label(localized(binaryKind.localizationKey), systemImage: "exclamationmark.shield")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .help(localized("sms.binary.help"))
                } else {
                    Text(SMSRichTextDetector.attributedString(for: message.body))
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction(handler: handleURL))
                }
                Text(message.displayTime(role: .timeOnly))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(message.sourceZoneHelp)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(message.outgoing ? AppControlPalette.accent.opacity(0.16) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: maxWidth, alignment: message.outgoing ? .trailing : .leading)
            .contextMenu {
                Button(localized("action.delete"), role: .destructive) {
                    store.deleteSMS(message)
                }
            }
            if !message.outgoing { Spacer(minLength: 42) }
        }
    }

    private func handleURL(_ url: URL) -> OpenURLAction.Result {
        if let code = SMSRichTextDetector.copiedCode(from: url) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            return .handled
        }

        NSWorkspace.shared.open(url)
        return .handled
    }
}
