import SwiftUI

private enum OverviewCategory: String, CaseIterable, Identifiable, SettingsCategoryItem {
    case status
    case network
    case sim
    case parameters

    var id: String { rawValue }
    var title: String { "overview.category.\(rawValue)" }
    var description: String { "overview.category.\(rawValue).description" }

    var systemImage: String {
        switch self {
        case .status: "gauge.with.dots.needle.50percent"
        case .network: "network"
        case .sim: "simcard"
        case .parameters: "list.bullet.rectangle"
        }
    }
}

/// Overview page that keeps only the parameters needed for a quick health check.
struct OverviewView: View {
    @EnvironmentObject private var store: ModemStore
    @State private var selectedCategory: OverviewCategory = .status

    var body: some View {
        SettingsCategoryLayout(
            categories: OverviewCategory.allCases,
            owningTab: .overview,
            selection: $selectedCategory
        ) {
            SettingsCategoryHeader(
                title: selectedCategory.title,
                description: selectedCategory.description,
                systemImage: selectedCategory.systemImage
            )
        } content: {
            categoryContent
        }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .status:
            VStack(spacing: 18) {
                SummaryCard()
                if store.state.simSecurity.requiresPIN {
                    SIMPINServiceWarning()
                }
                PrimaryParametersCard()
            }
        case .network:
            VStack(spacing: 18) {
                NetworkCard()
                RadioQualityCard()
                ServingCellCard()
            }
        case .sim:
            VStack(spacing: 18) {
                if store.state.simSecurity.requiresPIN {
                    SIMPINServiceWarning()
                }
                IdentityCard()
            }
        case .parameters:
            allParametersContent
        }
    }

    private var allParametersContent: some View {
        VStack(spacing: 18) {
            MacSettingsContentGroup("overview.all_parameters.modem") {
                ParameterGrid(
                    values: allParameterValues,
                    columnCount: 2,
                    fullValueDisplay: true,
                    showsCellBackground: false
                )
            }

            if !rawDiagnostics.isEmpty {
                MacSettingsContentGroup("overview.all_parameters.raw") {
                    Text(rawDiagnostics)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var allParameterValues: [ParameterValue] {
        fieldCatalog.map {
            ParameterValue(label: $0.label, value: $0.value(store.state.info))
        }
    }

    private var rawDiagnostics: String {
        [
            store.state.info.carrierAggregation,
            store.state.info.servingCell
        ]
            .filter { !isPlaceholder($0) }
            .joined(separator: "\n")
    }
}

/// Visible explanation for the connected-modem/no-service state caused by SIM PIN lock.
struct SIMPINServiceWarning: View {
    var body: some View {
        MacSettingsContentGroup("sim_pin.service_warning.title") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "simcard.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                Text(localized("sim_pin.service_warning.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The small set of operational values kept on the first page.
struct PrimaryParametersCard: View {
    @EnvironmentObject private var store: ModemStore

    private var values: [ParameterValue] {
        let info = store.state.info
        return [
            ParameterValue(label: "parameter.registration.label", value: registrationText),
            ParameterValue(label: "parameter.band.label", value: info.band),
            ParameterValue(label: "parameter.rsrp.label", value: info.rsrp),
            ParameterValue(label: "parameter.sinr.label", value: info.sinr),
            ParameterValue(label: "parameter.current_apn.label", value: info.currentApn),
            ParameterValue(label: "parameter.pdp_address.label", value: info.pdpAddress),
            ParameterValue(label: "parameter.usb_networking.label", value: info.usbNetworkMode),
            ParameterValue(label: "parameter.temperature.label", value: info.temperatureAvg)
        ]
    }

    var body: some View {
        MacSettingsContentGroup("overview.section.primary_parameters") {
            ParameterGrid(
                values: values,
                columnCount: 2,
                showsCellBackground: false
            )
        }
    }

    private var registrationText: String {
        firstPresent(store.state.info.epsRegistration)
            ?? firstPresent(store.state.info.gprsRegistration)
            ?? firstPresent(store.state.info.registration)
            ?? "-"
    }
}

/// Connection verdict plus the four values most useful at a glance.
struct SummaryCard: View {
    @EnvironmentObject private var store: ModemStore

    private var values: [ParameterValue] {
        [
            ParameterValue(label: "parameter.signal.label", value: signalText),
            ParameterValue(label: "parameter.network.label", value: networkText),
            ParameterValue(label: "parameter.operator.label", value: operatorText),
            ParameterValue(label: "parameter.updated.label", value: updatedText)
        ]
    }

    var body: some View {
        MacSettingsContentGroup("overview.section.network") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(signalColor.opacity(0.12))
                        SignalBars(level: store.state.info.signal.bars, color: signalColor)
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized(headline))
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Text(localized(subtitle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Divider().opacity(0.45)
                ParameterGrid(
                    values: values,
                    columnCount: 4,
                    showsCellBackground: false
                )
            }
        }
    }

    private var headline: String {
        guard store.state.connected else { return "overview.headline.disconnected" }
        let operatorName = firstPresent(store.state.info.operatorName)
        let tech = firstPresent(store.state.info.tech)
        let parts = [operatorName, tech].compactMap(\.self).map(localized)
        return parts.isEmpty ? "overview.headline.online" : parts.joined(separator: " · ")
    }

    private var subtitle: String {
        guard store.state.connected else { return "overview.subtitle.disconnected" }
        if let dataType = firstPresent(store.state.info.dataNetworkType) {
            return dataType
        }
        if let cell = firstPresent(store.state.info.band) {
            return localizedFormat("overview.current_band", cell)
        }
        return store.state.usbDescription
    }

    private var signalText: String {
        let info = store.state.info
        if let rsrp = firstPresent(info.rsrp) { return rsrp }
        if let dbm = info.signal.dbm { return "\(dbm) dBm" }
        return "-"
    }

    private var networkText: String {
        firstPresent(store.state.info.networkLabel) ?? firstPresent(store.state.info.tech) ?? "-"
    }

    private var operatorText: String {
        firstPresent(store.state.info.operatorName) ?? "-"
    }

    private var updatedText: String {
        guard let date = store.state.lastUpdated else { return "-" }
        return AppDateTimeFormatter.shared.string(from: date, role: .timeOnly)
    }

    private var signalColor: Color {
        store.state.connected ? .accentColor : .secondary
    }
}

struct NetworkCard: View {
    @EnvironmentObject private var store: ModemStore

    private var values: [ParameterValue] {
        [
            ParameterValue(label: "parameter.operator.label", value: store.state.info.operatorName),
            ParameterValue(label: "parameter.plmn.label", value: store.state.info.plmn),
            ParameterValue(label: "parameter.radio_access.label", value: store.state.info.tech),
            ParameterValue(label: "parameter.registration.label", value: registrationText),
            ParameterValue(label: "parameter.packet_attach.label", value: attachedText),
            ParameterValue(label: "parameter.pdp_activation.label", value: store.state.info.activePdp),
            ParameterValue(label: "parameter.pdp_address.label", value: store.state.info.pdpAddress),
            ParameterValue(label: "parameter.usb_networking.label", value: store.state.info.usbNetworkMode),
            ParameterValue(label: "parameter.current_apn.label", value: store.state.info.currentApn)
        ]
    }

    var body: some View {
        MacSettingsContentCard {
            ParameterGrid(
                values: values,
                columnCount: 2,
                showsCellBackground: false
            )
        }
    }

    private var registrationText: String {
        firstPresent(store.state.info.epsRegistration)
            ?? firstPresent(store.state.info.gprsRegistration)
            ?? firstPresent(store.state.info.registration)
            ?? "-"
    }

    private var attachedText: String {
        switch store.state.info.packetAttached {
        case "1": "network.attached"
        case "0": "network.detached"
        default: store.state.info.packetAttached
        }
    }
}

struct RadioQualityCard: View {
    @EnvironmentObject private var store: ModemStore

    private var values: [ParameterValue] {
        [
            ParameterValue(label: "parameter.rsrp.label", value: store.state.info.rsrp),
            ParameterValue(label: "parameter.rsrq.label", value: store.state.info.rsrq),
            ParameterValue(label: "parameter.sinr.label", value: store.state.info.sinr),
            ParameterValue(label: "parameter.rssi.label", value: store.state.info.rssiDbm),
            ParameterValue(label: "parameter.signal.label", value: store.state.info.signal.percent > 0 ? "\(store.state.info.signal.percent)%" : "-"),
            ParameterValue(label: "parameter.band.label", value: store.state.info.band),
            ParameterValue(label: "parameter.duplex.label", value: store.state.info.duplexMode),
            ParameterValue(label: "parameter.temperature.label", value: store.state.info.temperatureAvg)
        ]
    }

    var body: some View {
        MacSettingsContentGroup("overview.section.radio_quality") {
            ParameterGrid(
                values: values,
                columnCount: 4,
                showsCellBackground: false
            )
        }
    }
}

/// Identity values remain one click away instead of occupying the first viewport.
struct IdentityCard: View {
    @EnvironmentObject private var store: ModemStore

    private var values: [ParameterValue] {
        [
            ParameterValue(label: "parameter.sim_status.label", value: store.state.info.simStatus),
            ParameterValue(label: "parameter.sim_inserted.label", value: store.state.info.simInserted),
            ParameterValue(label: "parameter.own_number.label", value: store.state.info.ownNumber),
            ParameterValue(label: "parameter.imei.label", value: store.state.info.imei),
            ParameterValue(label: "parameter.imsi.label", value: store.state.info.imsi),
            ParameterValue(label: "parameter.iccid.label", value: store.state.info.iccid)
        ]
    }

    var body: some View {
        MacSettingsContentCard {
            ParameterGrid(
                values: values,
                columnCount: 2,
                showsCellBackground: false
            )
        }
    }
}

/// Serving-cell identifiers. Raw diagnostics remain in the Parameters page.
struct ServingCellCard: View {
    @EnvironmentObject private var store: ModemStore

    private var values: [ParameterValue] {
        [
            ParameterValue(label: "parameter.frequency.label", value: store.state.info.freqMhz),
            ParameterValue(label: "parameter.earfcn.label", value: store.state.info.earfcn),
            ParameterValue(label: "parameter.pci.label", value: store.state.info.pci),
            ParameterValue(label: "parameter.cell_id.label", value: store.state.info.cellId),
            ParameterValue(label: "parameter.tac.label", value: store.state.info.tac),
            ParameterValue(label: "parameter.plmn.label", value: store.state.info.plmn)
        ]
    }

    var body: some View {
        MacSettingsContentGroup("overview.section.serving_cell") {
            ParameterGrid(
                values: values,
                columnCount: 3,
                showsCellBackground: false
            )
        }
    }
}
