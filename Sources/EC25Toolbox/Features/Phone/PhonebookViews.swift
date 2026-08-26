import SwiftUI

/// Read-only SIM phonebook capability card. Probing issues only `AT+CPBS=?`,
/// `AT+CPBS?`, and `AT+CPBR=?` queries; the app never selects a storage and
/// never imports, overwrites, or writes card contacts.
struct SIMPhonebookContent: View {
    @EnvironmentObject private var store: ModemStore

    private var snapshot: PhonebookState { store.state.phonebook }

    var body: some View {
        VStack(spacing: 10) {
            if snapshot.lastProbedAt == nil {
                EmptyState(
                    title: "phonebook.unprobed.title",
                    subtitle: "phonebook.unprobed.description",
                    systemImage: "simcard"
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else if snapshot.isSupported {
                capabilityCard
            } else {
                unsupportedCard
            }

            Text(localized("phonebook.note.readonly"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(localized("phonebook.note.readonly"))
        }
        .frame(maxWidth: .infinity)
    }

    private var capabilityCard: some View {
        MacSettingsContentCard {
            VStack(spacing: 0) {
                if let probedAt = snapshot.lastProbedAt {
                    MacSettingsRow(title: "phonebook.probed_at") {
                        Text(AppDateTimeFormatter.shared.string(from: probedAt, role: .timeOnly))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    MacSettingsDivider()
                }
                valueRow("phonebook.row.storages", help: "phonebook.row.storages.help", value: storagesText)
                MacSettingsDivider()
                valueRow("phonebook.row.selected", help: "phonebook.row.selected.help", value: snapshot.selectedStorage ?? "-")
                MacSettingsDivider()
                valueRow("phonebook.row.capacity", help: "phonebook.row.capacity.help", value: capacityText)
                MacSettingsDivider()
                valueRow("phonebook.row.range", help: "phonebook.row.range.help", value: rangeText)
                MacSettingsDivider()
                valueRow("phonebook.row.lengths", help: "phonebook.row.lengths.help", value: lengthsText)
            }
        }
    }

    private func valueRow(_ title: String, help: String, value: String) -> some View {
        MacSettingsRow(title: title, help: help) {
            Text(value)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var unsupportedCard: some View {
        VStack(spacing: 10) {
            EmptyState(
                title: "phonebook.unsupported.title",
                subtitle: "phonebook.unsupported.description",
                systemImage: "simcard"
            )
            .frame(maxWidth: .infinity, minHeight: 200)
            if let error = snapshot.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var storagesText: String {
        snapshot.supportedStorages.isEmpty ? "-" : snapshot.supportedStorages.joined(separator: ", ")
    }

    private var capacityText: String {
        switch (snapshot.usedSlots, snapshot.totalSlots) {
        case let (used?, total?): "\(used) / \(total)"
        case let (nil, total?): "- / \(total)"
        case let (used?, nil): "\(used) / -"
        default: "-"
        }
    }

    private var rangeText: String {
        guard let range = snapshot.recordRange else { return "-" }
        return "\(range.lowerBound)–\(range.upperBound)"
    }

    private var lengthsText: String {
        switch (snapshot.maxNumberLength, snapshot.maxNameLength) {
        case let (number?, name?): "\(number) / \(name)"
        case let (number?, nil): "\(number) / -"
        case let (nil, name?): "- / \(name)"
        default: "-"
        }
    }
}
