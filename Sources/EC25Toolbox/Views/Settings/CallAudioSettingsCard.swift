import SwiftUI
import UniformTypeIdentifiers

/// Device-page card for call audio (P6): module sound card resolution with
/// manual override, Mac-side input/output device selection, and ringtone
/// import/pick/delete. Selection changes take effect immediately, rebuilding
/// live links when a call is connected.
struct CallAudioSettingsCard: View {
    @EnvironmentObject private var store: ModemStore
    @State private var isImportingRingtone = false
    @State private var importError: String?

    var body: some View {
        MacSettingsGroup("settings.group.call_audio") {
            MacSettingsRow(
                title: "settings.callaudio.module_device.title",
                help: "settings.callaudio.module_device.help"
            ) {
                RightAlignedMenuPicker(
                    selection: Binding(
                        get: { store.settings.callAudioModuleDeviceUID ?? "" },
                        set: { store.selectCallAudioModuleDevice(uid: $0.isEmpty ? nil : $0) }
                    ),
                    options: [.init(title: localized("settings.callaudio.module_device.auto"), value: "")]
                    + store.state.callAudio.moduleCandidates.map { device in
                        .init(title: device.displayName, value: device.uid)
                    }
                )
                .frame(width: 190)
            }

            MacSettingsDivider()

            MacSettingsToggleRow(
                title: "settings.callaudio.auto_record.title",
                help: "settings.callaudio.auto_record.help",
                isOn: Binding(
                    get: { store.settings.effectiveAutoRecordConnectedCalls },
                    set: { enabled in
                        store.updateSettings { $0.autoRecordConnectedCalls = enabled }
                    }
                )
            )

            MacSettingsDivider()

            MacSettingsRow(
                title: "settings.callaudio.input_device.title",
                help: "settings.callaudio.input_device.help"
            ) {
                RightAlignedMenuPicker(
                    selection: Binding(
                        get: { store.settings.callAudioInputDeviceUID ?? "" },
                        set: { store.selectCallAudioInputDevice(uid: $0.isEmpty ? nil : $0) }
                    ),
                    options: [
                        .init(title: localized("settings.callaudio.device.system_default"), value: ""),
                        .init(
                            title: localized(systemAudioInputTitleKey),
                            value: CallAudioInputSource.systemAudioUID
                        ),
                    ]
                    + store.state.callAudio.inputDevices.map { device in
                        .init(title: device.displayName, value: device.uid)
                    }
                )
                .frame(width: 190)
            }

            MacSettingsDivider()

            MacSettingsRow(
                title: "settings.callaudio.output_device.title",
                help: "settings.callaudio.output_device.help"
            ) {
                RightAlignedMenuPicker(
                    selection: Binding(
                        get: { store.settings.callAudioOutputDeviceUID ?? "" },
                        set: { store.selectCallAudioOutputDevice(uid: $0.isEmpty ? nil : $0) }
                    ),
                    options: [.init(title: localized("settings.callaudio.device.system_default"), value: "")]
                    + store.state.callAudio.outputDevices.map { device in
                        .init(title: device.displayName, value: device.uid)
                    }
                )
                .frame(width: 190)
            }

            MacSettingsDivider()

            MacSettingsRow(
                title: "settings.callaudio.module_status.title",
                help: "settings.callaudio.module_status.help"
            ) {
                Text(moduleStatusText)
                    .font(.callout)
                    .foregroundStyle(moduleDevice == nil ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .help(moduleStatusHelp)
            }

            MacSettingsDivider()

            MacSettingsRow(
                title: "settings.callaudio.topology.title",
                help: "settings.callaudio.module_status.help"
            ) {
                Text(topologyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            MacSettingsDivider()

            linkStatusSection

            MacSettingsDivider()

            MacSettingsRow(
                title: "settings.callaudio.ringtone.title",
                help: "settings.callaudio.ringtone.help"
            ) {
                HStack(spacing: 8) {
                    RightAlignedMenuPicker(
                        selection: Binding(
                            get: { store.settings.ringtoneFileName ?? "" },
                            set: { store.selectRingtone($0.isEmpty ? nil : $0) }
                        ),
                        options: ringtoneOptions
                    )
                    .frame(width: 170)

                    Button {
                        isImportingRingtone = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localized("settings.callaudio.ringtone.import"))
                    .help(localized("settings.callaudio.ringtone.import"))
                }
            }

            MacSettingsNoteRow(
                text: "settings.callaudio.boundary_note",
                systemImage: "info.circle"
            )
        }
        .onAppear(perform: store.refreshCallAudioDevices)
        .fileImporter(
            isPresented: $isImportingRingtone,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try store.importRingtone(from: url)
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                // A dismissed picker is user intent, not a failure.
                if !(error is CancellationError) {
                    importError = error.localizedDescription
                }
            }
        }
        .errorAlert(message: $importError)
    }

    /// R14: how the module endpoints were resolved — USB parent identity,
    /// manual override, or name-score fallback.
    private var topologyText: String {
        guard let key = store.state.callAudio.topologyEvidenceKey else {
            return "-"
        }
        return localized(key)
    }

    private var moduleDevice: AudioDeviceSummary? {
        store.state.callAudio.moduleDevice
    }

    private var systemAudioInputTitleKey: String {
        store.settings.effectiveManagementMode == .remote
            ? "settings.callaudio.device.system_audio.local_only"
            : "settings.callaudio.device.system_audio"
    }

    private var linkStatusSection: some View {
        let audio = store.state.callAudio
        let overall = overallLinkState
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(localized("settings.callaudio.link_status.title"))
                    .font(.body)
                Spacer(minLength: 8)
                Label(localized(overall.key), systemImage: overall.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(overall.tint)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    CallAudioInfoChip(
                        systemImage: "cable.connector",
                        text: localized("callaudio.backend.uac.short")
                    )
                    CallAudioInfoChip(
                        systemImage: "mic",
                        text: inputSourceText
                    )
                }
                VStack(alignment: .leading, spacing: 6) {
                    CallAudioInfoChip(
                        systemImage: "cable.connector",
                        text: localized("callaudio.backend.uac.short")
                    )
                    CallAudioInfoChip(systemImage: "mic", text: inputSourceText)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    CallAudioLinkStatusCard(
                        nameKey: "settings.callaudio.uplink",
                        systemImage: "arrow.up",
                        device: audio.moduleOutputDevice,
                        route: audio.uplinkRoute,
                        streaming: audio.uplinkStreaming,
                        engineUp: audio.uplinkRunning,
                        metrics: audio.uplinkMetrics
                    )
                    CallAudioLinkStatusCard(
                        nameKey: "settings.callaudio.downlink",
                        systemImage: "arrow.down",
                        device: audio.moduleInputDevice,
                        route: audio.downlinkRoute,
                        streaming: audio.downlinkStreaming,
                        engineUp: audio.downlinkRunning,
                        metrics: audio.downlinkMetrics
                    )
                }
                VStack(spacing: 8) {
                    CallAudioLinkStatusCard(
                        nameKey: "settings.callaudio.uplink",
                        systemImage: "arrow.up",
                        device: audio.moduleOutputDevice,
                        route: audio.uplinkRoute,
                        streaming: audio.uplinkStreaming,
                        engineUp: audio.uplinkRunning,
                        metrics: audio.uplinkMetrics
                    )
                    CallAudioLinkStatusCard(
                        nameKey: "settings.callaudio.downlink",
                        systemImage: "arrow.down",
                        device: audio.moduleInputDevice,
                        route: audio.downlinkRoute,
                        streaming: audio.downlinkStreaming,
                        engineUp: audio.downlinkRunning,
                        metrics: audio.downlinkMetrics
                    )
                }
            }

            if let lastError = audio.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(localizedFormat("common.full_value_help", lastError))
            }

            Text(localized("settings.callaudio.link_status.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var overallLinkState: (key: String, symbol: String, tint: Color) {
        let audio = store.state.callAudio
        if audio.lastError != nil {
            return ("settings.callaudio.link.attention", "exclamationmark.triangle.fill", .red)
        }
        if audio.uplinkStreaming && audio.downlinkStreaming {
            return ("settings.callaudio.link.streaming", "waveform", .green)
        }
        if audio.uplinkRunning || audio.downlinkRunning {
            return ("settings.callaudio.link.stalled", "exclamationmark.circle", .orange)
        }
        return ("settings.callaudio.link.idle", "pause.circle", .secondary)
    }

    private var inputSourceText: String {
        if store.state.callAudio.micPermissionRaw == CallAudioMicPermission.notRequired.rawValue {
            return localized("settings.callaudio.device.system_audio")
        }
        guard let uid = store.settings.callAudioInputDeviceUID else {
            return localized("settings.callaudio.device.system_default")
        }
        if CallAudioInputSource.isSystemAudio(uid) {
            return localized(systemAudioInputTitleKey)
        }
        return store.state.callAudio.inputDevices.first(where: { $0.uid == uid })?.displayName
            ?? localized("callaudio.device.unavailable")
    }

    private var moduleStatusText: String {
        if let moduleDevice {
            return moduleDevice.displayName
        }
        return localized(
            store.state.capabilities.usbVoice
                ? "settings.callaudio.module_status.missing_voice_capable"
                : "settings.callaudio.module_status.missing"
        )
    }

    private var moduleStatusHelp: String {
        if moduleDevice != nil {
            return localized("settings.callaudio.module_status.found.help")
        }
        return localized("settings.callaudio.module_status.missing.help")
    }

    private var ringtoneOptions: [RightAlignedMenuPicker<String>.Option] {
        let stored = store.ringtoneStore.list()
        var options = [RightAlignedMenuPicker<String>.Option(
            title: localized("settings.callaudio.ringtone.none"),
            value: ""
        )]
        options += stored.map { name in
            RightAlignedMenuPicker<String>.Option(
                title: (name as NSString).deletingPathExtension,
                value: name
            )
        }
        // The selected ringtone may not be imported yet on this machine.
        if let selected = store.settings.ringtoneFileName,
           !selected.isEmpty,
           !stored.contains(selected) {
            options.append(RightAlignedMenuPicker<String>.Option(
                title: (selected as NSString).deletingPathExtension,
                value: selected
            ))
        }
        return options
    }
}

private struct CallAudioInfoChip: View {
    var systemImage: String
    var text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.09), in: Capsule())
            .help(text)
    }
}

private struct CallAudioLinkStatusCard: View {
    var nameKey: String
    var systemImage: String
    var device: AudioDeviceSummary?
    var route: AudioRoutePlan?
    var streaming: Bool
    var engineUp: Bool
    var metrics: CallAudioLinkMetrics?

    private var stateKey: String {
        streaming
            ? "settings.callaudio.link.streaming"
            : (engineUp ? "settings.callaudio.link.stalled" : "settings.callaudio.link.idle")
    }

    private var stateTint: Color {
        streaming ? .green : (engineUp ? .orange : .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(localized(nameKey), systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(localized(stateKey))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateTint)
            }

            Text(device?.displayName ?? "-")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(device?.displayName ?? "-")

            if let route {
                Text(localizedFormat(
                    "settings.callaudio.rate",
                    route.sourceRate / 1_000,
                    route.targetRate / 1_000
                ))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }

            if let metrics {
                Text(localizedFormat(
                    "settings.callaudio.metrics",
                    Self.clampedCount(metrics.inputFrames),
                    Self.clampedCount(metrics.droppedFrames),
                    Self.clampedCount(metrics.underruns)
                ))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if streaming, metrics.peakLevel != nil {
                    Label(
                        localized(
                            AudioSignalDetector.hasSignal(peak: metrics.peakLevel)
                                ? "settings.callaudio.signal.present"
                                : "settings.callaudio.signal.silent"
                        ),
                        systemImage: "waveform"
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 218, maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(10)
        .background(
            Color.secondary.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private static func clampedCount(_ value: UInt64) -> Int {
        Int(min(value, UInt64(Int.max)))
    }
}
