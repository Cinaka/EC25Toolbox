import AppKit
import AVFAudio
import SwiftUI

private enum PhoneCategory: String, CaseIterable, Identifiable, SettingsCategoryItem {
    case dialer
    case history
    case contacts
    case sim
    case recordings

    var id: String { rawValue }
    var title: String { "phone.\(rawValue).title" }
    var description: String { "phone.\(rawValue).description" }

    var systemImage: String {
        switch self {
        case .dialer: "circle.grid.3x3"
        case .history: "clock"
        case .contacts: "person.2"
        case .sim: "simcard"
        case .recordings: "waveform"
        }
    }
}

/// Voice-call page for dialing and reviewing the local call event log.
struct PhoneView: View {
    @EnvironmentObject private var store: ModemStore
    @EnvironmentObject private var contactStore: ContactStore
    @EnvironmentObject private var presentation: WindowPresentationModel
    @Environment(\.prefersInlineSearch) private var prefersInlineSearch
    @State private var selectedCategory: PhoneCategory = .dialer
    @State private var number = ""
    @State private var historyQuery = ""

    private var filteredCallLog: [CallEvent] {
        let needle = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.state.callLog }
        return store.state.callLog.filter { event in
            event.title.localizedStandardContains(needle)
                || event.detail.localizedCaseInsensitiveContains(needle)
                || (contactStore.displayName(forNumber: event.detail) ?? "")
                    .localizedStandardContains(needle)
        }
    }

    private let keypad = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"]
    ]

    var body: some View {
        SettingsCategoryLayout(
            categories: PhoneCategory.allCases,
            owningTab: .phone,
            selection: $selectedCategory
        ) {
            SettingsCategoryHeader(
                title: selectedCategory.title,
                description: selectedCategory.description,
                systemImage: selectedCategory.systemImage
            ) {
                if selectedCategory == .sim {
                    Button {
                        store.probePhonebook()
                    } label: {
                        Label(localized("phonebook.probe.action"), systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(store.state.busy || !store.state.connected)
                    .help(localized("phonebook.probe.help"))
                }
            }
        } content: {
            categoryContent
        }
        .onAppear(perform: consumePendingDialNumber)
        .onChange(of: presentation.pendingDialNumber) { _, _ in
            consumePendingDialNumber()
        }
        .onChange(of: selectedCategory, initial: true) { _, category in
            if category == .history {
                store.acknowledgeMissedCalls()
            }
        }
        .onChange(of: store.state.callLog.count) { _, _ in
            if selectedCategory == .history {
                store.acknowledgeMissedCalls()
            }
        }
    }

    /// Adopts a number handed over from the contacts browser, switching to
    /// the dialer without auto-dialing.
    private func consumePendingDialNumber() {
        guard let pending = presentation.pendingDialNumber else { return }
        presentation.pendingDialNumber = nil
        number = pending
        selectedCategory = .dialer
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .dialer:
            dialer
        case .history:
            callHistory
        case .contacts:
            ContactsContent()
        case .sim:
            SIMPhonebookContent()
        case .recordings:
            CallRecordingsContent()
        }
    }

    private var dialer: some View {
        VStack(spacing: 16) {
            callStatusBar

            if store.state.call.phase == .active || store.state.call.phase == .held {
                CallAudioControls()
            }

            if let rings = store.state.autoAnswerRings, rings > 0 {
                AutoAnswerWarningCard(rings: rings)
            }

            if store.state.call.phase == .incoming, store.state.call.clccActiveAnomalies > 0 {
                Label(
                    localized("phone.call.anomaly_clcc_active"),
                    systemImage: "exclamationmark.bubble"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(localized("phone.call.anomaly_clcc_active.help"))
            }

            dialPad
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }

    /// Only the keypad needs the narrow phone-like measure. Status and audio
    /// surfaces stay full-width so their leading and trailing edges match the
    /// category introduction card and the other information cards below it.
    private var dialPad: some View {
        VStack(spacing: 16) {
            TextField(localized("phone.number.placeholder"), text: $number)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(height: 52)
                .textSelection(.enabled)
                .help(localized("phone.number.help"))
                .onSubmit { store.dial(number: number) }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(68), spacing: 20), count: 3), spacing: 14) {
                ForEach(keypad.flatMap { $0 }, id: \.self) { key in
                    keypadButton(for: key)
                }
            }
            .frame(maxWidth: .infinity)

            if store.state.call.phase == .active {
                Text(localized("phone.dtmf_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            actionRow
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var callStatusBar: some View {
        if store.state.call.phase == .active {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                callStatusRow(text: statusText(now: context.date))
            }
        } else {
            callStatusRow(text: statusText(now: Date()))
        }
    }

    private func callStatusRow(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusSystemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusActive ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(statusActive ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .help(text)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private var actionRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(68), spacing: 20), count: 3), spacing: 0) {
            switch store.state.call.phase {
            case .incoming:
                PhoneCircleButton(
                    systemImage: "phone.down.fill",
                    accessibilityLabel: "action.decline",
                    prominentColor: .red,
                    disabled: store.state.busy
                ) {
                    store.reject()
                }
                actionSpacer
                PhoneCircleButton(
                    systemImage: "phone.fill",
                    accessibilityLabel: "action.answer",
                    prominentColor: .green,
                    disabled: store.state.busy
                ) {
                    store.answer()
                }
                actionSpacer
            case .answering:
                PhoneCircleButton(
                    systemImage: "phone.down.fill",
                    accessibilityLabel: "action.hang_up",
                    prominentColor: .red,
                    disabled: store.state.busy || !store.state.connected
                ) {
                    store.hangUp()
                }
                actionSpacer
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 68, height: 68)
                    .help(localized("phone.status.answering"))
            case .dialing, .alerting:
                PhoneCircleButton(systemImage: "delete.left", accessibilityLabel: "action.delete", disabled: number.isEmpty) {
                    number = String(number.dropLast())
                }
                .buttonRepeatBehavior(.enabled)
                actionSpacer
                PhoneCircleButton(
                    systemImage: "phone.down.fill",
                    accessibilityLabel: "action.hang_up",
                    prominentColor: .red,
                    disabled: store.state.busy || !store.state.connected
                ) {
                    store.hangUp()
                }
            case .ending:
                PhoneCircleButton(systemImage: "delete.left", accessibilityLabel: "action.delete", disabled: number.isEmpty) {
                    number = String(number.dropLast())
                }
                .buttonRepeatBehavior(.enabled)
                actionSpacer
                PhoneCircleButton(
                    systemImage: "phone.down.fill",
                    accessibilityLabel: "action.hang_up",
                    prominentColor: .red,
                    disabled: true
                ) {}
            case .active, .held:
                PhoneCircleButton(systemImage: "delete.left", accessibilityLabel: "action.delete", disabled: number.isEmpty) {
                    number = String(number.dropLast())
                }
                .buttonRepeatBehavior(.enabled)
                actionSpacer
                PhoneCircleButton(
                    systemImage: "phone.down.fill",
                    accessibilityLabel: "action.hang_up",
                    prominentColor: .red,
                    disabled: store.state.busy || !store.state.connected
                ) {
                    store.hangUp()
                }
            default:
                PhoneCircleButton(systemImage: "delete.left", accessibilityLabel: "action.delete", disabled: number.isEmpty) {
                    number = String(number.dropLast())
                }
                .buttonRepeatBehavior(.enabled)

                PhoneCircleButton(systemImage: "phone.fill", accessibilityLabel: "action.call", prominent: true, disabled: store.state.busy || sanitizedDialNumber(number).isEmpty) {
                    store.dial(number: number)
                }

                actionSpacer
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var actionSpacer: some View {
        Color.clear.frame(width: 68, height: 68)
    }

    private func handleKeypadKey(_ key: String) {
        if store.state.call.phase == .active {
            store.sendDTMF(key)
        } else {
            number.append(key)
        }
    }

    private func keypadButton(for key: String) -> some View {
        DialKey(
            key: key,
            longPressAction: key == "0" ? { handleInternationalPrefix() } : nil,
            action: { handleKeypadKey(key) }
        )
    }

    /// Long-pressing zero follows the system dialer convention. If digits
    /// were entered first, move the international prefix to the front instead
    /// of producing an invalid embedded `+`.
    private func handleInternationalPrefix() {
        guard store.state.call.phase != .active else { return }
        number = DialPadInput.addingInternationalPrefix(to: number)
    }

    private var statusActive: Bool {
        switch store.state.call.phase {
        case .idle, .ended, .failed, .missed: false
        case .incoming, .answering, .dialing, .alerting, .active, .held, .ending: true
        }
    }

    private var statusSystemImage: String {
        switch store.state.call.phase {
        case .idle: "phone"
        case .incoming, .answering: "phone.arrow.down.right"
        case .dialing, .alerting: "phone.arrow.up.right"
        case .active: "phone.fill"
        case .held: "pause.circle"
        case .ending, .ended, .missed: "phone.down.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// Caller/peer display derived through the shared R12 identity
    /// derivator: the tracked incoming identity when it belongs to the
    /// current call, otherwise the same name → number → unknown chain from
    /// the contact snapshot.
    private var peerDisplayText: String {
        if let identity = store.state.callerIdentity,
           identity.epoch == store.state.call.epoch {
            return CallerIdentityDerivator.display(
                identity: identity,
                pendingText: localized("call.identity.resolving"),
                unknownText: localized("phone.status.no_number"),
                withheldText: localized("call.identity.withheld")
            ).title
        }
        let raw = store.state.call.number
        return CallerIdentityDerivator.display(
            number: raw,
            contactName: raw.flatMap { contactStore.displayName(forNumber: $0) },
            unknownText: localized("phone.status.no_number")
        ).title
    }

    private func statusText(now: Date) -> String {
        let number = peerDisplayText
        switch store.state.call.phase {
        case .idle:
            return localized("phone.active_call.none")
        case .incoming:
            return localizedFormat("phone.status.incoming", number)
        case .answering:
            return localized("phone.status.answering")
        case .dialing:
            return localizedFormat("phone.status.dialing", number)
        case .alerting:
            return localizedFormat("phone.status.alerting", number)
        case .active:
            guard let started = store.state.call.startedAt else {
                return localized("phone.status.active")
            }
            return localizedFormat("phone.status.active_duration", durationText(since: started, now: now))
        case .held:
            return localized("phone.status.held")
        case .ending:
            return localized("phone.status.ending")
        case .ended:
            return localized("phone.status.ended")
        case .failed:
            return localized("phone.status.failed")
        case .missed:
            return localized("phone.status.missed")
        }
    }

    private func durationText(since started: Date, now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(started))
        return String(format: "%02d:%02d", Int(interval) / 60, Int(interval) % 60)
    }

    @ViewBuilder
    private var callHistory: some View {
        if store.state.callLog.isEmpty {
            EmptyState(title: "phone.history.empty_title", subtitle: "phone.history.empty_description", systemImage: "phone")
                .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            VStack(spacing: 10) {
                if prefersInlineSearch {
                    CompactSearchField(text: $historyQuery, promptKey: "phone.history.search_placeholder")
                }

                if filteredCallLog.isEmpty {
                    SearchNoResultsState()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    MacSettingsContentCard {
                        VStack(spacing: 12) {
                            ForEach(filteredCallLog) { event in
                                CallEventRow(event: event, contact: contactStore.contact(forNumber: event.detail))
                            }
                        }
                    }
                }
            }
            .surfaceSearch(text: $historyQuery, promptKey: "phone.history.search_placeholder")
        }
    }
}

/// Single dial-pad key.
struct DialKey: View {
    var key: String
    var longPressAction: (() -> Void)? = nil
    var action: () -> Void
    @State private var consumedLongPress = false

    private var letters: String? {
        switch key {
        case "2": "ABC"
        case "3": "DEF"
        case "4": "GHI"
        case "5": "JKL"
        case "6": "MNO"
        case "7": "PQRS"
        case "8": "TUV"
        case "9": "WXYZ"
        case "0": "+"
        default: nil
        }
    }

    var body: some View {
        Button {
            if consumedLongPress {
                consumedLongPress = false
            } else {
                DialPadTonePlayer.shared.play(key)
                action()
            }
        } label: {
            VStack(spacing: -1) {
                Text(key)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                if let letters {
                    Text(letters)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(1.2)
                }
            }
                .frame(width: 68, height: 68)
                .contentShape(Circle())
        }
        .buttonStyle(PressableCallButtonStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    guard let longPressAction else { return }
                    consumedLongPress = true
                    DialPadTonePlayer.shared.play(key)
                    longPressAction()
                }
        )
        .background(.quaternary.opacity(0.34), in: Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .help(localizedFormat("phone.key_input", key))
    }
}

/// Standard dual-frequency mapping used by both the ordinary dial pad and
/// the in-call DTMF pad. Keeping the mapping pure makes the audible feedback
/// deterministic and independently testable from modem-side `AT+VTS`.
enum DTMFTone {
    struct Frequencies: Equatable {
        var low: Double
        var high: Double
    }

    static func frequencies(for key: String) -> Frequencies? {
        let rows: [Character: Double] = [
            "1": 697, "2": 697, "3": 697, "A": 697,
            "4": 770, "5": 770, "6": 770, "B": 770,
            "7": 852, "8": 852, "9": 852, "C": 852,
            "*": 941, "0": 941, "#": 941, "D": 941,
        ]
        let columns: [Character: Double] = [
            "1": 1_209, "4": 1_209, "7": 1_209, "*": 1_209,
            "2": 1_336, "5": 1_336, "8": 1_336, "0": 1_336,
            "3": 1_477, "6": 1_477, "9": 1_477, "#": 1_477,
            "A": 1_633, "B": 1_633, "C": 1_633, "D": 1_633,
        ]
        guard let character = key.uppercased().first,
              key.count == 1,
              let low = rows[character],
              let high = columns[character]
        else { return nil }
        return Frequencies(low: low, high: high)
    }
}

/// Short local DTMF feedback. In-call keys still send the authoritative tone
/// through `AT+VTS`; this player only provides immediate Mac-side feedback.
@MainActor
final class DialPadTonePlayer {
    static let shared = DialPadTonePlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate = 48_000.0
    private let duration = 0.12

    private init() {
        engine.attach(player)
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func play(_ key: String) {
        guard let frequencies = DTMFTone.frequencies(for: key),
              let buffer = makeBuffer(frequencies: frequencies)
        else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            player.play()
        } catch {
            // Key feedback must never block dialing or modem-side DTMF.
        }
    }

    private func makeBuffer(frequencies: DTMFTone.Frequencies) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
        let samples = buffer.floatChannelData?[0]
        else { return nil }

        let attackFrames = max(1, Int(sampleRate * 0.006))
        let releaseFrames = max(1, Int(sampleRate * 0.014))
        let count = Int(frameCount)
        for index in 0..<count {
            let time = Double(index) / sampleRate
            let attack = min(1, Double(index) / Double(attackFrames))
            let release = min(1, Double(count - index - 1) / Double(releaseFrames))
            let envelope = min(attack, release)
            let sample = sin(2 * .pi * frequencies.low * time)
                + sin(2 * .pi * frequencies.high * time)
            samples[index] = Float(sample * 0.11 * envelope)
        }
        buffer.frameLength = frameCount
        return buffer
    }
}

/// Pure dial-pad input rule shared by the UI and focused tests.
enum DialPadInput {
    static func addingInternationalPrefix(to value: String) -> String {
        guard !value.hasPrefix("+") else { return value }
        return "+" + value.replacingOccurrences(of: "+", with: "")
    }
}

/// Circular action button matching the dial-pad layout.
struct PhoneCircleButton: View {
    var systemImage: String
    var accessibilityLabel: String
    var prominent = false
    /// Custom fill for prominent actions (answer/hang-up semantics); implies
    /// the prominent white-glyph treatment.
    var prominentColor: Color?
    var disabled = false
    var action: () -> Void

    private var isProminent: Bool { prominent || prominentColor != nil }

    private var fill: Color {
        if let prominentColor { return prominentColor }
        return prominent ? Color.accentColor : Color.secondary.opacity(0.16)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .frame(width: 68, height: 68)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isProminent ? Color.white : Color.primary)
        .background(fill, in: Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
        .accessibilityLabel(localized(accessibilityLabel))
        .help(localized(accessibilityLabel))
    }
}

/// Row describing one optional phone call event. `contact` is resolved by the
/// caller so rows stay decoupled from the contacts store; a match renders the
/// system avatar, otherwise a plain call glyph stands in.
struct CallEventRow: View {
    @EnvironmentObject private var store: ModemStore
    var event: CallEvent
    var contact: ContactRecord?

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let contact {
                    ContactAvatar(contact: contact, size: 30)
                } else {
                    Image(systemName: "phone")
                        .foregroundStyle(Color.secondary)
                        .frame(width: 24, height: 24)
                }
                if event.failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .background(.background, in: Circle())
                }
            }
            .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(event.title))
                    .font(.subheadline.weight(.medium))
                Text(displayDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let moduleProvenance {
                    Label(moduleProvenance, systemImage: "cpu")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(AppDateTimeFormatter.shared.string(from: event.date, role: .compact))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)

                HStack(spacing: 8) {
                    Button {
                        guard let number = displayedNumber else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(number, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help(localized("phone.history.copy_number"))
                    .disabled(displayedNumber == nil)

                    Button {
                        store.dial(number: event.detail)
                    } label: {
                        Image(systemName: "phone.arrow.up.right")
                    }
                    .buttonStyle(.borderless)
                    .help(localized("phone.history.call_back"))
                    .disabled(store.state.busy || displayedNumber == nil)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var moduleProvenance: String? {
        if let name = event.moduleName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            if let serial = event.moduleSerialNumber, !serial.isEmpty, name != serial {
                return "\(name) · \(serial)"
            }
            return name
        }
        return event.moduleSerialNumber
    }

    /// Same R12 derivator chain as the banner and live-call surfaces:
    /// contact name, then the raw detail (usually the number), without
    /// round-tripping a phone number through the localization table.
    private var displayDetail: String {
        let number = displayedNumber ?? event.detail
        guard let name = contact?.displayName, !name.isEmpty else { return number }
        return "\(name) · \(number)"
    }

    private var displayedNumber: String? {
        PhoneNumberDisplay.internationalized(event.detail)
    }
}

/// R8: warns when the module itself answers calls (`ATS0` non-zero). The
/// modem then reports calls as active without any user answer, which the
/// incoming-call gate refuses; the fix is disabling auto-answer, and it is
/// only ever written after explicit confirmation.
private struct AutoAnswerWarningCard: View {
    @EnvironmentObject private var store: ModemStore
    let rings: Int
    @State private var confirmingDisable = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(localizedFormat("phone.autoanswer.warning", rings))
                    .font(.caption.weight(.medium))
                Text(localized("phone.autoanswer.help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(localized("phone.autoanswer.disable")) {
                confirmingDisable = true
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .confirmationDialog(
            localized("phone.autoanswer.confirm.title"),
            isPresented: $confirmingDisable,
            titleVisibility: .visible
        ) {
            Button(localized("phone.autoanswer.confirm.button"), role: .destructive) {
                store.disableAutoAnswer()
            }
            Button(localized("common.cancel"), role: .cancel) {}
        } message: {
            Text(localizedFormat("phone.autoanswer.confirm.message", rings))
        }
    }
}
