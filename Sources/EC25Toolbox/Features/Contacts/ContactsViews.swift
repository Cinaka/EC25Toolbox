import SwiftUI

/// Contacts browser inside the Phone page: authorization states first, then a
/// searchable list whose rows expand to per-number call and message actions.
struct ContactsContent: View {
    @EnvironmentObject private var contactStore: ContactStore
    @EnvironmentObject private var presentation: WindowPresentationModel
    @Environment(\.prefersInlineSearch) private var prefersInlineSearch
    @State private var query = ""
    @State private var expandedContactID: String?

    var body: some View {
        switch contactStore.authorization {
        case .notDetermined:
            authorizationCard(
                title: "contacts.access.undetermined.title",
                description: "contacts.access.undetermined.description",
                systemImage: "person.crop.circle.badge.questionmark",
                actionTitle: "contacts.access.allow"
            ) {
                Task { await contactStore.requestAccessIfNeeded() }
            }
        case .restricted:
            authorizationCard(
                title: "contacts.access.restricted.title",
                description: "contacts.access.restricted.description",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        case .denied:
            authorizationCard(
                title: "contacts.access.denied.title",
                description: "contacts.access.denied.description",
                systemImage: "person.crop.circle.badge.xmark",
                actionTitle: "contacts.access.open_settings"
            ) {
                ContactsSettingsOpener.openPrivacyPane()
            }
        case .authorized, .limited:
            contactList
        }
    }

    private func authorizationCard(
        title: String,
        description: String,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 14) {
            EmptyState(title: title, subtitle: description, systemImage: systemImage)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(localized(actionTitle))
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var contactList: some View {
        let filtered = contactStore.search(query)
        let content = VStack(spacing: 10) {
            if contactStore.authorization == .limited {
                Text(localized("contacts.access.limited_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = contactStore.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if prefersInlineSearch {
                CompactSearchField(text: $query, promptKey: "contacts.search.placeholder")
            }

            HStack(spacing: 8) {
                if contactStore.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                    Text(localized("contacts.refreshing"))
                } else {
                    Text(localizedFormat("contacts.summary", filtered.count))
                }
                Spacer()
                Button {
                    Task { await contactStore.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(contactStore.isRefreshing)
                .help(localized("action.refresh_status"))
                .accessibilityLabel(localized("action.refresh_status"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if filtered.isEmpty {
                let empty = query.trimmingCharacters(in: .whitespaces).isEmpty
                EmptyState(
                    title: empty ? "contacts.empty.title" : "contacts.no_matches.title",
                    subtitle: empty ? "contacts.empty.description" : "contacts.no_matches.description",
                    systemImage: "person.2"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacSettingsContentCard {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { contact in
                                ContactRow(
                                    contact: contact,
                                    isExpanded: expandedContactID == contact.id
                                ) {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        expandedContactID = expandedContactID == contact.id ? nil : contact.id
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity)
        return Group {
            if prefersInlineSearch {
                content
            } else {
                content.surfaceSearch(text: $query, promptKey: "contacts.search.placeholder")
            }
        }
    }
}

/// One contact row; expanding reveals every number with call and message
/// actions. Tapping a number action hands off to the Phone dialer or the SMS
/// composer through the shared presentation model.
private struct ContactRow: View {
    @EnvironmentObject private var presentation: WindowPresentationModel
    @Environment(\.presentationSurface) private var surface
    let contact: ContactRecord
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    ContactAvatar(contact: contact)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if !contact.organizationName.isEmpty, !contact.personName.isEmpty {
                            Text(contact.organizationName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                numberList
                    .padding(.leading, 44)
                    .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.quaternary.opacity(0.6))
                .frame(height: 1)
                .padding(.leading, 44)
        }
    }

    private var displayName: String {
        contact.displayName.isEmpty ? localized("contacts.unnamed") : contact.displayName
    }

    @ViewBuilder
    private var numberList: some View {
        if contact.phoneNumbers.isEmpty {
            Text(localized("contacts.no_numbers"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 7) {
                ForEach(contact.phoneNumbers) { entry in
                    HStack(spacing: 8) {
                        Text(entry.label.isEmpty ? localized("contacts.phone") : entry.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                            .lineLimit(1)
                        Text(entry.value)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            presentation.pendingDialNumber = entry.value
                            presentation.select(.phone, on: surface)
                        } label: {
                            Image(systemName: "phone")
                        }
                        .buttonStyle(.borderless)
                        .help(localizedFormat("contacts.call", entry.value))
                        .accessibilityLabel(localizedFormat("contacts.call", entry.value))

                        Button {
                            presentation.pendingSMSRecipient = entry.value
                            presentation.select(.sms, on: surface)
                        } label: {
                            Image(systemName: "message")
                        }
                        .buttonStyle(.borderless)
                        .help(localizedFormat("contacts.message", entry.value))
                        .accessibilityLabel(localizedFormat("contacts.message", entry.value))
                    }
                }
            }
        }
    }
}

/// Contact avatar with the system thumbnail when available and an initials
/// circle otherwise.
struct ContactAvatar: View {
    let contact: ContactRecord
    var size: CGFloat = 34

    var body: some View {
        if let data = contact.thumbnailData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: size, height: size)
                .overlay {
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
        }
    }

    private var initials: String {
        let base = contact.displayName.isEmpty
            ? localized("contacts.unnamed")
            : contact.displayName
        let first = base.first.map(String.init) ?? "?"
        return first.uppercased()
    }
}
