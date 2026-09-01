import SwiftUI
import QuickLook
import AVFAudio
import UniformTypeIdentifiers

/// Compact in-call audio bar: uplink mute, downlink speaker gate and volume,
/// and per-call recording. Shown only while a call is connected.
struct CallAudioControls: View {
    @EnvironmentObject private var store: ModemStore

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                CallAudioIconButton(
                    systemImage: status.muted ? "mic.slash.fill" : "mic.fill",
                    labelKey: status.muted ? "callaudio.mute.off" : "callaudio.mute.on",
                    tint: status.muted ? .red : nil
                ) {
                    store.setCallAudioMuted(!status.muted)
                }

                CallAudioIconButton(
                    systemImage: status.speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    labelKey: status.speakerEnabled ? "callaudio.speaker.off" : "callaudio.speaker.on",
                    tint: status.speakerEnabled ? nil : .orange
                ) {
                    store.setCallAudioSpeakerEnabled(!status.speakerEnabled)
                }

                CallAudioDeviceMenu(kind: .input, presentation: .compact)
                CallAudioDeviceMenu(kind: .output, presentation: .compact)

                Slider(
                    value: Binding(
                        get: { store.state.callAudio.volume },
                        set: { store.setCallAudioVolume($0) }
                    ),
                    in: 0...1
                )
                .disabled(!status.speakerEnabled)
                .help(localized("callaudio.volume.help"))

                CallAudioIconButton(
                    systemImage: status.isRecording ? "stop.circle.fill" : "record.circle",
                    labelKey: status.isRecording ? "callaudio.record.stop" : "callaudio.record.start",
                    tint: status.isRecording ? .red : nil
                ) {
                    store.toggleCallRecording()
                }
            }

            if status.moduleDevice == nil {
                Label(localized("callaudio.hint.no_module_device"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(localized("callaudio.hint.no_module_device.help"))
            } else if let error = status.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(error)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var status: CallAudioStatus { store.state.callAudio }
}

/// Shared in-call device menu. The same safe device inventory and selection
/// actions drive the phone page, focused popover, and compact sidebar card.
struct CallAudioDeviceMenu: View {
    enum Kind: Equatable {
        case input
        case output

        var titleKey: String {
            switch self {
            case .input: "callaudio.input.select"
            case .output: "callaudio.output.select"
            }
        }

        var systemImage: String {
            switch self {
            case .input: "mic.circle"
            case .output: "speaker.circle"
            }
        }
    }

    enum Presentation {
        case compact
        case takeover
        case sidebar
        case notification
    }

    @EnvironmentObject private var store: ModemStore
    var kind: Kind
    var presentation: Presentation

    var body: some View {
        Menu {
            option(
                title: localized("settings.callaudio.device.system_default"),
                uid: nil
            )

            if kind == .input {
                option(
                    title: localized(systemAudioTitleKey),
                    uid: CallAudioInputSource.systemAudioUID,
                    disabled: store.settings.effectiveManagementMode == .remote
                )
            }

            if !devices.isEmpty {
                Divider()
                ForEach(devices) { device in
                    option(title: device.displayName, uid: device.uid)
                }
            }
        } label: {
            menuLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(localizedFormat(
            "callaudio.device.current",
            localized(kind.titleKey),
            selectedDeviceTitle
        ))
        .accessibilityLabel(localized(kind.titleKey))
        .accessibilityValue(selectedDeviceTitle)
    }

    @ViewBuilder
    private var menuLabel: some View {
        switch presentation {
        case .compact:
            Image(systemName: kind.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 30, height: 30)
                .background(
                    Color.secondary.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        case .takeover:
            VStack(spacing: 7) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 72, height: 72)
                    .background(Color.primary.opacity(0.075), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
                Text(localized(kind.titleKey))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 104)
        case .sidebar:
            Image(systemName: kind.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.secondary, in: Circle())
        case .notification:
            Image(systemName: kind.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    @ViewBuilder
    private func option(title: String, uid: String?, disabled: Bool = false) -> some View {
        Button {
            switch kind {
            case .input:
                store.selectCallAudioInputDevice(uid: uid)
            case .output:
                store.selectCallAudioOutputDevice(uid: uid)
            }
        } label: {
            if selectedUID == uid {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .disabled(disabled)
    }

    private var devices: [AudioDeviceSummary] {
        switch kind {
        case .input: store.state.callAudio.inputDevices
        case .output: store.state.callAudio.outputDevices
        }
    }

    private var selectedUID: String? {
        switch kind {
        case .input: store.settings.callAudioInputDeviceUID
        case .output: store.settings.callAudioOutputDeviceUID
        }
    }

    private var selectedDeviceTitle: String {
        guard let selectedUID else {
            return localized("settings.callaudio.device.system_default")
        }
        if kind == .input, CallAudioInputSource.isSystemAudio(selectedUID) {
            return localized(systemAudioTitleKey)
        }
        return devices.first(where: { $0.uid == selectedUID })?.displayName
            ?? localized("callaudio.device.unavailable")
    }

    private var systemAudioTitleKey: String {
        store.settings.effectiveManagementMode == .remote
            ? "settings.callaudio.device.system_audio.local_only"
            : "settings.callaudio.device.system_audio"
    }
}

/// Small square toggle used by the in-call audio bar.
private struct CallAudioIconButton: View {
    var systemImage: String
    var labelKey: String
    var tint: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(localized(labelKey))
        .help(localized(labelKey))
    }
}

/// Shared single-recording player so starting one row stops the previous.
@MainActor
final class RecordingPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?
    /// Surfaces playback failures (unreadable/missing file) to the owning
    /// surface instead of silently stopping.
    var onError: ((String) -> Void)?
    private var player: AVAudioPlayer?

    func toggle(_ entry: RecordingEntry, url: URL) {
        if playingID == entry.id {
            stop()
            return
        }
        stop()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.play()
            player = newPlayer
            playingID = entry.id
        } catch {
            stop()
            onError?(error.localizedDescription)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }
}

enum RecordingExportSupport {
    static var cafType: UTType {
        UTType(filenameExtension: "caf") ?? .audio
    }
}

/// Export-only recording document (macOS 27+): the snapshot is just the
/// source URL and the framework writer turns it into a `FileWrapper` off the
/// main actor, so large recordings never block UI work during export.
@available(macOS 27, *)
@Observable
final class RecordingExportDocument: WritableDocument {
    static var writableContentTypes: [UTType] { [RecordingExportSupport.cafType] }

    let sourceURL: URL
    let suggestedName: String

    init(sourceURL: URL, suggestedName: String) {
        self.sourceURL = sourceURL
        self.suggestedName = suggestedName
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending URL {
        sourceURL
    }

    func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<URL> {
        FileWrapperDocumentWriter(configuration) { sourceURL, _ in
            let data = try Data(contentsOf: sourceURL)
            return FileWrapper(regularFileWithContents: data)
        }
    }
}

/// macOS 26 export fallback: data is pre-read on a detached task so the
/// classic `FileDocument` path also never blocks the main actor.
struct LegacyRecordingExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [RecordingExportSupport.cafType] }

    var data: Data
    var suggestedName: String

    init(data: Data, suggestedName: String) {
        self.data = data
        self.suggestedName = suggestedName
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        suggestedName = "recording.caf"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Export target handed to whichever document pipeline the running OS uses.
struct RecordingExportTarget: Equatable {
    var sourceURL: URL
    var fileName: String
}

/// Recordings browser: per-call files for the current SIM identity with
/// playback, Quick Look, export, and confirmed deletion.
struct CallRecordingsContent: View {
    @EnvironmentObject private var store: ModemStore
    @EnvironmentObject private var contactStore: ContactStore
    @Environment(\.prefersInlineSearch) private var prefersInlineSearch
    @StateObject private var playback = RecordingPlayback()
    @State private var quickLookURL: URL?
    @State private var exportTarget: RecordingExportTarget?
    @State private var legacyExportDocument: LegacyRecordingExportDocument?
    @State private var isExporting = false
    @State private var pendingDelete: RecordingEntry?
    @State private var searchQuery = ""
    @State private var actionError: String?

    private var filteredRecordings: [RecordingEntry] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.state.recordings }
        return store.state.recordings.filter { entry in
            entry.fileName.localizedStandardContains(needle)
                || (entry.number ?? "").localizedCaseInsensitiveContains(needle)
                || (contactStore.displayName(forNumber: entry.number ?? "") ?? "")
                    .localizedStandardContains(needle)
        }
    }

    var body: some View {
        Group {
            if store.state.recordings.isEmpty {
                EmptyState(
                    title: "recordings.empty.title",
                    subtitle: "recordings.empty.description",
                    systemImage: "waveform"
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                VStack(spacing: 10) {
                    if prefersInlineSearch {
                        CompactSearchField(text: $searchQuery, promptKey: "recordings.search.placeholder")
                    }

                    if filteredRecordings.isEmpty {
                        SearchNoResultsState()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        MacSettingsContentCard {
                            VStack(spacing: 12) {
                                ForEach(filteredRecordings) { entry in
                                    RecordingRow(
                                        entry: entry,
                                        contactName: contactStore.displayName(forNumber: entry.number ?? ""),
                                        isPlaying: playback.playingID == entry.id,
                                        onPlay: { play(entry) },
                                        onQuickLook: { quickLook(entry) },
                                        onExport: { export(entry) },
                                        onDelete: { pendingDelete = entry }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        .surfaceSearch(text: $searchQuery, promptKey: "recordings.search.placeholder")
        .onAppear {
            playback.onError = { actionError = $0 }
            store.reloadCallRecordings()
        }
        .quickLookPreview($quickLookURL)
        .modifier(RecordingExportPresenter(
            target: $exportTarget,
            legacyDocument: $legacyExportDocument,
            isPresented: $isExporting,
            onCompletion: handleExportCompletion
        ))
        .modifier(RecordingDeleteConfirmation(
            pendingDelete: $pendingDelete,
            confirm: confirmDelete
        ))
        .errorAlert(message: $actionError)
    }

    private func play(_ entry: RecordingEntry) {
        guard let url = store.callRecordingURL(entry) else {
            actionError = localized("recordings.error.missing_file")
            return
        }
        playback.toggle(entry, url: url)
    }

    private func quickLook(_ entry: RecordingEntry) {
        guard let url = store.callRecordingURL(entry) else {
            actionError = localized("recordings.error.missing_file")
            return
        }
        quickLookURL = url
    }

    private func export(_ entry: RecordingEntry) {
        guard let url = store.callRecordingURL(entry) else {
            actionError = localized("recordings.error.missing_file")
            return
        }
        let target = RecordingExportTarget(sourceURL: url, fileName: entry.fileName)
        exportTarget = target
        if #available(macOS 27, *) {
            isExporting = true
        } else {
            Task { @MainActor in
                await exportLegacyPreRead(target)
            }
        }
    }

    /// macOS 26 FileDocument path: the file read stays off the main actor;
    /// only the state update that presents the save panel returns to it.
    @MainActor
    private func exportLegacyPreRead(_ target: RecordingExportTarget) async {
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: target.sourceURL)
            }.value
            legacyExportDocument = LegacyRecordingExportDocument(
                data: data,
                suggestedName: target.fileName
            )
            isExporting = true
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// A cancelled save panel is user intent, not a failure; only real
    /// read/write errors surface.
    private func handleExportCompletion(_ result: Result<URL, Error>) {
        if case .failure(let error) = result, !(error is CancellationError) {
            actionError = error.localizedDescription
        }
        exportTarget = nil
        legacyExportDocument = nil
    }

    private func confirmDelete(_ entry: RecordingEntry) {
        if playback.playingID == entry.id { playback.stop() }
        store.deleteCallRecording(entry)
        pendingDelete = nil
    }
}

/// Export presentation split by OS: macOS 27 hands the source URL to the
/// `WritableDocument` writer (background read); macOS 26 keeps the classic
/// `FileDocument` shape fed by the pre-read data.
private struct RecordingExportPresenter: ViewModifier {
    @Binding var target: RecordingExportTarget?
    @Binding var legacyDocument: LegacyRecordingExportDocument?
    @Binding var isPresented: Bool
    var onCompletion: (Result<URL, Error>) -> Void

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 27, *) {
                content.modifier(RecordingExportPresenter27(
                    target: $target,
                    isPresented: $isPresented,
                    onCompletion: onCompletion
                ))
            } else {
                content.fileExporter(
                    isPresented: $isPresented,
                    document: legacyDocument,
                    contentType: RecordingExportSupport.cafType,
                    defaultFilename: legacyDocument?.suggestedName,
                    onCompletion: onCompletion
                )
            }
        }
    }
}

@available(macOS 27, *)
private struct RecordingExportPresenter27: ViewModifier {
    @Binding var target: RecordingExportTarget?
    @Binding var isPresented: Bool
    var onCompletion: (Result<URL, Error>) -> Void

    func body(content: Content) -> some View {
        content.fileExporter(
            isPresented: $isPresented,
            document: target.map {
                RecordingExportDocument(sourceURL: $0.sourceURL, suggestedName: $0.fileName)
            },
            contentType: RecordingExportSupport.cafType,
            defaultFilename: target?.fileName,
            onCompletion: onCompletion
        )
    }
}

/// Item-driven delete confirmation: on macOS 27 the pending recording is the
/// single source of truth; macOS 26 falls back to the Bool + `presenting:`
/// form fed from the same optional.
private struct RecordingDeleteConfirmation: ViewModifier {
    @Binding var pendingDelete: RecordingEntry?
    var confirm: (RecordingEntry) -> Void

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 27, *) {
                content.confirmationDialog(
                    localized("recordings.delete.confirm"),
                    item: $pendingDelete,
                    titleVisibility: .visible
                ) { entry in
                    Button(localized("recordings.action.delete"), role: .destructive) {
                        confirm(entry)
                    }
                    Button(localized("common.cancel"), role: .cancel) {}
                } message: { _ in
                    Text(localized("recordings.delete.message"))
                }
            } else {
                content.confirmationDialog(
                    localized("recordings.delete.confirm"),
                    isPresented: Binding(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: pendingDelete
                ) { entry in
                    Button(localized("recordings.action.delete"), role: .destructive) {
                        confirm(entry)
                    }
                    Button(localized("common.cancel"), role: .cancel) {}
                } message: { _ in
                    Text(localized("recordings.delete.message"))
                }
            }
        }
    }
}

private struct RecordingRow: View {
    var entry: RecordingEntry
    var contactName: String?
    var isPlaying: Bool
    var onPlay: () -> Void
    var onQuickLook: () -> Void
    var onExport: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background(Color.accentColor.opacity(0.16), in: Circle())
            .accessibilityLabel(localized(isPlaying ? "recordings.action.stop" : "recordings.action.play"))
            .help(localized(isPlaying ? "recordings.action.stop" : "recordings.action.play"))

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.durationText(entry.duration))
                    Text(Self.sizeText(entry.byteSize))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(AppDateTimeFormatter.shared.string(from: entry.createdAt, role: .dateOnly))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Menu {
                Button(action: onQuickLook) {
                    Label(localized("recordings.action.quicklook"), systemImage: "eye")
                }
                Button(action: onExport) {
                    Label(localized("recordings.action.export"), systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label(localized("recordings.action.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(localized("recordings.action.more"))
        }
        .padding(.vertical, 4)
    }

    private var displayTitle: String {
        if let contactName, !contactName.isEmpty { return contactName }
        if let number = entry.number, !number.isEmpty { return number }
        return localized("recordings.row.unknown_number")
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(max(0, duration))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .file)
    }
}
