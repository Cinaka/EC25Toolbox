import MapKit
import SwiftUI

extension GNSSPhase {
    var localizationKey: String { "gnss.phase.\(rawValue)" }
}

extension GNSSFix {
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private enum GNSSCategory: String, CaseIterable, Identifiable, SettingsCategoryItem {
    case status
    case map
    case details

    var id: String { rawValue }
    var title: String { "gnss.category.\(rawValue)" }
    var description: String { "gnss.category.\(rawValue).description" }

    var systemImage: String {
        switch self {
        case .status: "location.circle"
        case .map: "map"
        case .details: "list.bullet.rectangle"
        }
    }
}

/// GNSS page: explicit engine controls, a MapKit position display, and the
/// raw fix metrics. Position data never leaves the Mac — the map tiles are
/// the only network-bound content and they carry no coordinates.
struct GNSSView: View {
    @EnvironmentObject private var store: ModemStore
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var visibleSpan: MKCoordinateSpan?
    @State private var lastCenteredCoordinate: CLLocationCoordinate2D?
    @State private var selectedCategory: GNSSCategory = .status

    private var gnss: GNSSStatus { store.state.gnss }
    private var capability: GNSSCapability { store.state.capabilities.gnss }

    var body: some View {
        SettingsCategoryLayout(
            categories: GNSSCategory.allCases,
            owningTab: .gnss,
            selection: $selectedCategory
        ) {
            SettingsCategoryHeader(
                title: selectedCategory.title,
                description: selectedCategory.description,
                systemImage: selectedCategory.systemImage
            ) {
                engineButton
            }
        } content: {
            categoryContent
        }
        .onChange(of: gnss.lastFix?.acquiredAt) { _, _ in
            recenterOnFix()
        }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .status:
            VStack(spacing: 14) {
                if capability != .supported { capabilityCard }
                statusCard
            }
        case .map:
            mapCard
        case .details:
            metricsCard
        }
    }

    /// The tab always stays visible (R10): an unconfirmed, failed or
    /// "unsupported" probe is explained on the page with a retry, never by
    /// hiding the navigation entry.
    private var capabilityCard: some View {
        MacSettingsContentGroup("gnss.capability.card") {
            VStack(alignment: .leading, spacing: 6) {
                Text(localized(capabilityNoteKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if capability != .unsupported {
                    Button(localized("gnss.capability.retry")) {
                        store.refreshGNSSCapability()
                    }
                    .controlSize(.small)
                    .disabled(!store.state.connected)
                }
            }
        }
    }

    private var capabilityNoteKey: String {
        switch capability {
        case .supported: "gnss.capability.note.supported"
        case .unsupported: "gnss.capability.note.unsupported"
        case .error: "gnss.capability.note.error"
        case .unknown: "gnss.capability.note.unknown"
        }
    }

    @ViewBuilder
    private var engineButton: some View {
        if gnss.isEngineRunning {
            Button {
                store.stopGNSS()
            } label: {
                Label(localized("gnss.action.stop"), systemImage: "stop.fill")
            }
            .controlSize(.small)
            .help(localized("gnss.action.stop.help"))
            .disabled(store.state.busy)
        } else {
            Button {
                store.startGNSS()
            } label: {
                Label(localized("gnss.action.start"), systemImage: "play.fill")
            }
            .controlSize(.small)
            .help(localized("gnss.action.start.help"))
            // A definitive firmware verdict without GNSS disables Start;
            // unconfirmed states keep the button available (R10).
            .disabled(store.state.busy || !store.state.connected || capability == .unsupported)
        }
    }

    private var statusCard: some View {
        MacSettingsContentCard {
            HStack(alignment: .center, spacing: 10) {
                GNSSPhaseBadge(phase: gnss.phase)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(gnss.phase.localizationKey))
                        .font(.subheadline.weight(.semibold))
                    if let error = gnss.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(localizedFormat("common.full_value_help", error))
                    } else if gnss.phase == .searching, let elapsed = searchingElapsedText {
                        Text(localizedFormat("gnss.status.searching_elapsed", elapsed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if let acquiredAt = gnss.lastFix?.acquiredAt,
                              acquiredAt != .distantPast {
                        Text(localizedFormat(
                            "gnss.status.last_fix",
                            AppDateTimeFormatter.shared.string(from: acquiredAt, role: .timeOnly)
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(localized("gnss.status.no_fix"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 6)
            }
        }
    }

    @ViewBuilder
    private var mapCard: some View {
        MacSettingsContentCard {
            if let coordinate = gnss.lastFix?.coordinate {
                Map(position: $cameraPosition) {
                    Marker(
                        localized("gnss.map.marker"),
                        systemImage: "location.fill",
                        coordinate: coordinate
                    )
                    .tint(Color.accentColor)
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onMapCameraChange(frequency: .onEnd) { context in
                    // Remember the user's zoom so fix updates only move the
                    // center instead of resetting the whole camera.
                    visibleSpan = context.region.span
                }
            } else {
                EmptyState(
                    title: "gnss.empty.title",
                    subtitle: emptySubtitle,
                    systemImage: "map"
                )
                .frame(height: 190)
            }
        }
    }

    private var emptySubtitle: String {
        switch gnss.phase {
        case .off: "gnss.empty.off"
        case .searching: "gnss.empty.searching"
        case .timeout: "gnss.empty.timeout"
        case .lost: "gnss.empty.lost"
        case .fixed, .weak: "gnss.empty.waiting"
        }
    }

    private var metricsCard: some View {
        MacSettingsContentCard {
            ParameterGrid(
                values: metricValues,
                columnCount: 2,
                showsCellBackground: false
            )
        }
    }

    private var metricValues: [ParameterValue] {
        let fix = gnss.lastFix
        return [
            ParameterValue(label: "gnss.metric.latitude", value: fix?.latitudeRaw ?? format(fix?.latitude, digits: 6)),
            ParameterValue(label: "gnss.metric.longitude", value: fix?.longitudeRaw ?? format(fix?.longitude, digits: 6)),
            ParameterValue(label: "gnss.metric.utc", value: utcText(fix)),
            ParameterValue(label: "gnss.metric.altitude", value: fix?.altitudeMeters.map { localizedFormat("gnss.format.meters", $0.formatted(.number.precision(.fractionLength(0...1)))) } ?? "-"),
            ParameterValue(label: "gnss.metric.hdop", value: format(fix?.hdop, digits: 2)),
            ParameterValue(label: "gnss.metric.speed", value: fix?.speedKmh.map { localizedFormat("gnss.format.kmh", $0.formatted(.number.precision(.fractionLength(0...1)))) } ?? "-"),
            ParameterValue(label: "gnss.metric.course", value: fix?.courseDegrees.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))°" } ?? "-"),
            ParameterValue(label: "gnss.metric.satellites", value: fix?.satelliteCount.map(String.init) ?? "-"),
            ParameterValue(label: "gnss.metric.source", value: gnss.dataSource.map { localized($0.localizationKey) } ?? "-")
        ]
    }

    /// Minutes:seconds since the current search began; refreshed by the poll
    /// ticks while the phase stays `searching`.
    private var searchingElapsedText: String? {
        guard let since = gnss.searchingSince else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(since)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func utcText(_ fix: GNSSFix?) -> String {
        guard let fix, let utc = fix.utc else { return "-" }
        guard let date = fix.date else { return utc }
        return "\(utc) \(date)"
    }

    private func format(_ value: Double?, digits: Int) -> String {
        guard let value else { return "-" }
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    /// Follows the module only while it actually moves. A stationary module
    /// leaves the user's pan and zoom untouched, and the remembered span
    /// keeps the user's zoom level across fix updates.
    private func recenterOnFix() {
        guard let coordinate = gnss.lastFix?.coordinate else { return }
        if let last = lastCenteredCoordinate,
           abs(last.latitude - coordinate.latitude) < 0.000_05,
           abs(last.longitude - coordinate.longitude) < 0.000_05 {
            return
        }
        let span = visibleSpan ?? MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        cameraPosition = .region(MKCoordinateRegion(center: coordinate, span: span))
        lastCenteredCoordinate = coordinate
    }
}

/// Colored phase icon shared by the GNSS status card and the header chip.
struct GNSSPhaseBadge: View {
    var phase: GNSSPhase
    var size: CGFloat = 15
    var frameSize: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: phase == .searching && !reduceMotion)
            .frame(width: frameSize, height: frameSize)
            .background(color.opacity(0.12), in: Circle())
            .help(localized(phase.localizationKey))
            .accessibilityLabel(localized(phase.localizationKey))
    }

    private var systemImage: String {
        switch phase {
        case .off: "location.slash"
        case .searching: "location"
        case .fixed: "location.fill"
        case .weak: "location.fill"
        case .timeout: "clock.badge.exclamationmark"
        case .lost: "location.slash"
        }
    }

    private var color: Color {
        switch phase {
        case .off: .secondary
        case .searching: .accentColor
        case .fixed: .green
        case .weak: .orange
        case .timeout: .orange
        case .lost: .red
        }
    }
}

/// Compact GPS status merged into the panel header while the engine has any
/// non-off state, so the menu-bar panel reflects positioning without a
/// second status item.
struct GNSSMenuBarChip: View {
    var phase: GNSSPhase

    var body: some View {
        GNSSPhaseBadge(phase: phase, size: 11, frameSize: 22)
    }
}
