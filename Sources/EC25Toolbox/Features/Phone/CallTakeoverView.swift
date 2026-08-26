import SwiftUI

/// Which popover-root section owns the surface (R13). While a call is live
/// the takeover replaces everything — AppChrome, the tab picker, and normal
/// page content are not even laid out. Terminal phases give the surface back;
/// the user's tab selection never changed during the call, so the panel
/// reopens exactly where it was.
enum PopoverRootSection: Equatable {
    case takeover
    case tabs

    static func resolve(callPhase: CallPhase) -> PopoverRootSection {
        CallTakeoverView.isLiveCallPhase(callPhase) ? .takeover : .tabs
    }
}

/// Focused native call surface for every live call phase (R13). As the
/// popover root it is the only content on screen; the standalone window
/// hosts compact cards at the bottom of the primary sidebar.
/// Closing the popover neither rejects nor hangs up — reopening shows the
/// same call epoch for as long as it is live.
struct CallTakeoverView: View {
    enum Placement {
        /// Exclusive popover root (fixed 640×700 canvas, R17).
        case popoverRoot
        /// Compact operable card at the bottom of the standalone sidebar.
        case sidebarCard
        /// Non-activating floating panel shown for every live call.
        case notificationPanel
    }

    var placement: Placement = .popoverRoot

    @EnvironmentObject private var store: ModemStore

    /// The phases whose popover root is the takeover surface (R13).
    nonisolated static func isLiveCallPhase(_ phase: CallPhase) -> Bool {
        switch phase {
        case .incoming, .answering, .dialing, .alerting, .active, .held, .ending:
            return true
        case .idle, .ended, .failed, .missed:
            return false
        }
    }

    /// Non-ringing call phases use the always-visible right-hand keypad. The
    /// incoming and ending surfaces keep only their phase-specific actions.
    nonisolated static func usesPersistentKeypad(_ phase: CallPhase) -> Bool {
        switch phase {
        case .answering, .dialing, .alerting, .active, .held:
            return true
        case .incoming, .ending, .idle, .ended, .failed, .missed:
            return false
        }
    }

    var body: some View {
        switch placement {
        case .popoverRoot:
            fullSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .sidebarCard:
            sidebarCard
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .notificationPanel:
            notificationPanel
        }
    }

    // MARK: - Popover root

    private var fullSurface: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    header
                    phaseControls
                }
                .padding(.horizontal, 28)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(
                    maxWidth: .infinity,
                    minHeight: max(0, geometry.size.height - 2),
                    alignment: .top
                )
            }
            .scrollIndicators(.hidden)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(phaseStatusText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(callerDisplay.title)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.62)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .help(callerDisplay.title)

            if let subtitle = callerDisplay.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 500)
    }

    /// Identity for the tracked epoch, derived exactly like the notification
    /// banner, phone status text, and history rows (R12).
    private var callerDisplay: CallerIdentityDerivator.Display {
        let identity = store.state.callerIdentity
        let tracked = identity.flatMap {
            $0.epoch == store.state.call.epoch ? $0 : nil
        }
        if tracked != nil {
            return CallerIdentityDerivator.display(
                identity: tracked,
                pendingText: localized("call.identity.resolving"),
                unknownText: localized("phone.status.no_number"),
                withheldText: localized("call.identity.withheld")
            )
        }
        // Outgoing calls and pre-R12 identities have no tracked identity.
        return CallerIdentityDerivator.display(
            number: store.state.call.number,
            contactName: contactName,
            unknownText: localized("phone.status.no_number")
        )
    }

    private var contactName: String? {
        guard let number = store.state.call.number else { return nil }
        return store.callContactNameResolver?(number) ?? nil
    }

    private var phaseStatusText: String {
        switch store.state.call.phase {
        case .incoming: localized("call.surface.ringing")
        case .answering: localized("phone.status.answering")
        case .dialing: localized("call.surface.calling")
        case .alerting: localized("call.surface.alerting")
        case .active: localized("call.surface.connected")
        case .held: localized("call.surface.held")
        case .ending: localized("call.surface.ending")
        case .idle, .ended, .failed, .missed: ""
        }
    }

    // MARK: - Phase controls

    @ViewBuilder
    private var phaseControls: some View {
        switch store.state.call.phase {
        case .incoming:
            incomingControls
        case .answering:
            horizontalCallLayout {
                connectingControlColumn
            }
        case .dialing, .alerting:
            horizontalCallLayout {
                outgoingControlColumn
            }
        case .active, .held:
            horizontalCallLayout {
                activeControlColumn
            }
        case .ending:
            endingControls
        case .idle, .ended, .failed, .missed:
            EmptyView()
        }
    }

    /// iPhone-style incoming pair: large decline and answer buttons with
    /// labels underneath.
    private var incomingControls: some View {
        HStack(spacing: 56) {
            TakeoverActionButton(
                systemImage: "phone.down.fill",
                labelKey: "action.decline",
                tint: .red
            ) {
                store.reject()
            }
            TakeoverActionButton(
                systemImage: "phone.fill",
                labelKey: "action.answer",
                tint: .green
            ) {
                store.answer()
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, minHeight: 390, alignment: .center)
    }

    private var connectingControlColumn: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(localized("phone.status.answering"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            TakeoverActionButton(
                systemImage: "phone.down.fill",
                labelKey: "action.hang_up",
                tint: .red
            ) {
                store.hangUp()
            }
        }
    }

    private var outgoingControlColumn: some View {
        VStack(spacing: 16) {
            callControlGrid(recordingEnabled: false)
            TakeoverActionButton(
                systemImage: "phone.down.fill",
                labelKey: "action.hang_up",
                tint: .red
            ) {
                store.hangUp()
            }
        }
    }

    private var activeControlColumn: some View {
        VStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(durationText(now: context.date))
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }

            callControlGrid(recordingEnabled: store.state.call.phase == .active)

            audioHealthRow

            TakeoverActionButton(
                systemImage: "phone.down.fill",
                labelKey: "action.hang_up",
                tint: .red
            ) {
                store.hangUp()
            }
        }
    }

    private func horizontalCallLayout<Controls: View>(
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(alignment: .top, spacing: 20) {
            controls()
                .frame(width: 232, alignment: .top)

            Divider()
                .padding(.vertical, 6)

            keypadGrid
                .frame(width: 220, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func callControlGrid(recordingEnabled: Bool) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(104), spacing: 10), count: 2),
            spacing: 12
        ) {
            TakeoverToggleButton(
                isOn: store.state.callAudio.muted,
                onImage: "mic.slash.fill",
                offImage: "mic.fill",
                onLabelKey: "callaudio.mute.on",
                offLabelKey: "callaudio.mute.off",
                tint: .orange
            ) {
                store.setCallAudioMuted(!store.state.callAudio.muted)
            }
            TakeoverToggleButton(
                isOn: store.state.callAudio.speakerEnabled,
                onImage: "speaker.wave.3.fill",
                offImage: "speaker.wave.1.fill",
                onLabelKey: "callaudio.speaker.on",
                offLabelKey: "callaudio.speaker.off",
                tint: .accentColor
            ) {
                store.setCallAudioSpeakerEnabled(!store.state.callAudio.speakerEnabled)
            }
            CallAudioDeviceMenu(kind: .input, presentation: .takeover)
            CallAudioDeviceMenu(kind: .output, presentation: .takeover)
            TakeoverToggleButton(
                isOn: store.state.callAudio.isRecording,
                onImage: "stop.circle.fill",
                offImage: "record.circle",
                onLabelKey: "callaudio.record.stop",
                offLabelKey: "callaudio.record.start",
                tint: .red,
                disabled: !recordingEnabled
            ) {
                store.toggleCallRecording()
            }
        }
    }

    private var endingControls: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(localized("phone.status.ending"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    /// Per-direction frame-flow indicators: "running" means frames keep
    /// moving on that segment, not that an engine merely started (R3/R14).
    private var audioHealthRow: some View {
        let audio = store.state.callAudio
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                AudioHealthChip(
                    labelKey: "call.takeover.audio.uplink",
                    streaming: audio.uplinkStreaming
                )
                AudioHealthChip(
                    labelKey: "call.takeover.audio.downlink",
                    streaming: audio.downlinkStreaming
                )
            }
            if audio.isRecording {
                Label(localized("callaudio.record.active"), systemImage: "record.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
            }
        }
    }

    private var keypadGrid: some View {
        VStack(spacing: 8) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(62), spacing: 18), count: 3),
                spacing: 12
            ) {
                ForEach(
                    ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"],
                    id: \.self
                ) { key in
                    DialKey(key: key) {
                        store.sendDTMF(key)
                    }
                }
            }
            Text(localized("phone.dtmf_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        let number = callerDisplay.title
        switch store.state.call.phase {
        case .dialing: return localizedFormat("phone.status.dialing", number)
        case .alerting: return localizedFormat("phone.status.alerting", number)
        default: return phaseStatusText
        }
    }

    private func durationText(now: Date) -> String {
        guard let started = store.state.call.startedAt else {
            return localized("phone.status.active")
        }
        let interval = max(0, now.timeIntervalSince(started))
        return String(format: "%02d:%02d", Int(interval) / 60, Int(interval) % 60)
    }

    // MARK: - Standalone sidebar card

    /// Compact operable card for the standalone window. The identity stays in
    /// the upper part and every action is grouped below it, so a long caller
    /// name can never stretch across or cover the detail column.
    private var sidebarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: phaseSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
                    .symbolEffect(
                        .pulse, options: .repeating,
                        isActive: store.state.call.phase == .incoming
                            || store.state.call.phase == .dialing
                            || store.state.call.phase == .alerting
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.moduleDisplayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(callerDisplay.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(overlayStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            Divider().opacity(0.45)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if store.state.call.phase == .active || store.state.call.phase == .held {
                    OverlayCallButton(
                        systemImage: store.state.callAudio.muted
                            ? "mic.slash.fill" : "mic.fill",
                        accessibilityLabel: store.state.callAudio.muted
                            ? "callaudio.mute.off" : "callaudio.mute.on",
                        tint: store.state.callAudio.muted ? .orange : .gray
                    ) {
                        store.setCallAudioMuted(!store.state.callAudio.muted)
                    }
                    OverlayCallButton(
                        systemImage: store.state.callAudio.speakerEnabled
                            ? "speaker.wave.2.fill" : "speaker.wave.1.fill",
                        accessibilityLabel: store.state.callAudio.speakerEnabled
                            ? "callaudio.speaker.off" : "callaudio.speaker.on",
                        tint: .secondary
                    ) {
                        store.setCallAudioSpeakerEnabled(!store.state.callAudio.speakerEnabled)
                    }
                    CallAudioDeviceMenu(kind: .input, presentation: .sidebar)
                    CallAudioDeviceMenu(kind: .output, presentation: .sidebar)
                }

                if store.state.call.phase == .answering || store.state.call.phase == .ending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                } else if store.state.call.phase == .incoming {
                    OverlayCallButton(
                        systemImage: "phone.fill",
                        accessibilityLabel: "action.answer",
                        tint: .green
                    ) {
                        store.answer()
                    }
                }

                OverlayCallButton(
                    systemImage: "phone.down.fill",
                    accessibilityLabel: store.state.call.phase == .incoming
                        ? "action.decline" : "action.hang_up",
                    tint: .red
                ) {
                    if store.state.call.phase == .incoming {
                        store.reject()
                    } else {
                        store.hangUp()
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(11)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 13))
    }

    private var phaseSymbol: String {
        switch store.state.call.phase {
        case .incoming: "phone.arrow.down.right"
        case .answering: "phone.badge.plus"
        case .dialing, .alerting: "phone.arrow.up.right"
        case .active: "phone.fill"
        case .held: "phone.badge.clock"
        case .ending: "phone.down"
        case .idle, .ended, .failed, .missed: "phone"
        }
    }

    private var overlayStatusText: String {
        switch store.state.call.phase {
        case .active:
            guard store.state.call.startedAt != nil else {
                return localized("phone.status.active")
            }
            return localizedFormat(
                "phone.status.active_duration",
                durationText(now: Date())
            )
        default:
            return statusText.isEmpty ? phaseStatusText : statusText
        }
    }

    // MARK: - Floating notification panel

    private var notificationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: phaseSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .symbolEffect(
                        .pulse,
                        options: .repeating,
                        isActive: store.state.call.phase == .incoming
                            || store.state.call.phase == .dialing
                            || store.state.call.phase == .alerting
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(callerDisplay.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(store.moduleDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if store.state.call.phase == .active || store.state.call.phase == .held {
                    let streaming = store.state.callAudio.uplinkStreaming
                        || store.state.callAudio.downlinkStreaming
                    Image(systemName: "waveform")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(streaming ? Color.green : Color.secondary)
                        .help(localized(streaming
                            ? "call.takeover.audio.streaming"
                            : "call.takeover.audio.stalled"))
                }

                if store.state.call.phase == .active {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationText(now: context.date))
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                } else {
                    Text(overlayStatusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }

            Divider().opacity(0.45)

            HStack(spacing: 8) {
                notificationPanelActions
                Spacer(minLength: 6)
                if store.state.call.phase != .ending {
                    NotificationCallButton(
                        systemImage: "phone.down.fill",
                        accessibilityLabel: store.state.call.phase == .incoming
                            ? "action.decline" : "action.hang_up",
                        prominentTint: .red
                    ) {
                        if store.state.call.phase == .incoming {
                            store.reject()
                        } else {
                            store.hangUp()
                        }
                    }
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(8)
    }

    @ViewBuilder
    private var notificationPanelActions: some View {
        switch store.state.call.phase {
        case .incoming:
            NotificationCallButton(
                systemImage: "phone.fill",
                accessibilityLabel: "action.answer",
                prominentTint: .green
            ) {
                store.answer()
            }
        case .answering, .ending:
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
        case .dialing, .alerting:
            CallAudioDeviceMenu(kind: .input, presentation: .notification)
            CallAudioDeviceMenu(kind: .output, presentation: .notification)
        case .active, .held:
            NotificationCallButton(
                systemImage: store.state.callAudio.muted ? "mic.slash.fill" : "mic.fill",
                accessibilityLabel: store.state.callAudio.muted
                    ? "callaudio.mute.off" : "callaudio.mute.on",
                foreground: store.state.callAudio.muted ? .orange : .primary
            ) {
                store.setCallAudioMuted(!store.state.callAudio.muted)
            }
            NotificationCallButton(
                systemImage: store.state.callAudio.speakerEnabled
                    ? "speaker.wave.2.fill" : "speaker.wave.1.fill",
                accessibilityLabel: store.state.callAudio.speakerEnabled
                    ? "callaudio.speaker.off" : "callaudio.speaker.on",
                foreground: store.state.callAudio.speakerEnabled ? .primary : .secondary
            ) {
                store.setCallAudioSpeakerEnabled(!store.state.callAudio.speakerEnabled)
            }
            CallAudioDeviceMenu(kind: .input, presentation: .notification)
            CallAudioDeviceMenu(kind: .output, presentation: .notification)
            NotificationCallButton(
                systemImage: store.state.callAudio.isRecording
                    ? "stop.circle.fill" : "record.circle",
                accessibilityLabel: store.state.callAudio.isRecording
                    ? "callaudio.record.stop" : "callaudio.record.start",
                foreground: store.state.callAudio.isRecording ? .red : .secondary
            ) {
                store.toggleCallRecording()
            }
        case .idle, .ended, .failed, .missed:
            EmptyView()
        }
    }
}
