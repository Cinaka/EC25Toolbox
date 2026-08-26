import Foundation
import AVFAudio
import AppKit
import CoreAudio

/// User preferences the service reads at every (re)build of the bridge.
struct CallAudioPreferences {
    var inputDeviceUID: String?
    var outputDeviceUID: String?
    /// Manual override for the module sound card; nil = auto-match.
    var moduleDeviceUID: String?
    var ringtoneFileName: String?
    /// Physical USB parent of the store's module. This prevents two identical
    /// EC25/DJI sound cards from being cross-wired when both are attached.
    var preferredModuleParent: USBAudioParentKey?
    /// Transient UAC forwarding readiness. The call command path sets this to
    /// true only after `AT+QPCMV=1,2` succeeds; nil/false must not build an
    /// all-zero bridge and present it as working.
    var moduleVoiceReady: Bool?

    init(
        inputDeviceUID: String? = nil,
        outputDeviceUID: String? = nil,
        moduleDeviceUID: String? = nil,
        ringtoneFileName: String? = nil,
        preferredModuleParent: USBAudioParentKey? = nil,
        moduleVoiceReady: Bool? = nil
    ) {
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self.moduleDeviceUID = moduleDeviceUID
        self.ringtoneFileName = ringtoneFileName
        self.preferredModuleParent = preferredModuleParent
        self.moduleVoiceReady = moduleVoiceReady
    }
}

/// Owns the duplex call-audio bridge, the call recorder, and the ringtone
/// player (R14). The service runs entirely outside the modem command
/// pipeline: audio must never queue behind AT operations and AT operations
/// must never wait on audio. All state flows out through `statusDidChange`
/// into `ModemState.callAudio`.
///
/// Bridges are single-use: every (re)build resolves topology, keeps every
/// endpoint on its native clock, and installs a fresh
/// `CoreAudioDuplexBridge`. Async rebuilds carry a build-generation epoch and
/// may only run while their epoch is still current. "Running" is derived
/// exclusively from the watchdog: every segment counter must keep advancing
/// between polls — a started IOProc proves nothing by itself.
@MainActor
final class CallAudioService {
    var recordingDidFinish: ((RecordingEntry?) -> Void)?
    var statusDidChange: ((CallAudioStatus) -> Void)?

    var preferences: () -> CallAudioPreferences = { CallAudioPreferences() }
    var ringtoneURLProvider: (() -> URL?)?
    /// Present only when this store controls a paired remote modem host.
    var remoteTransportProvider: () -> RemoteModemTransport? = { nil }

    private let catalog = AudioDeviceCatalog()
    private(set) var status = CallAudioStatus() {
        didSet {
            if status != oldValue {
                statusDidChange?(status)
            }
        }
    }

    private var bridge: CoreAudioDuplexBridge?
    private var remoteBridge: RemoteCallAudioBridge?
    /// Lazily created when the synthetic System Audio input is selected. It
    /// stays alive across link rebuilds so its aggregate-device notification
    /// cannot create a rebuild loop; shutdown destroys it.
    private var systemAudioCaptureDevice: SystemAudioCaptureDevice?
    private var desiredLinks = false
    private var rebuildTask: Task<Void, Never>?
    private var deviceRecoveryAttempts = 0
    private static let maximumDeviceRecoveryAttempts = 6
    /// Bumped on every build/stop; async rebuilds compare against the epoch
    /// they were planned for (R14 race guard).
    private var buildGeneration = 0
    /// 1 Hz segment-counter poll while the bridge is desired: "running" must
    /// reflect frames actually moving on every segment (R14).
    private var metricsPollTask: Task<Void, Never>?
    private var previousCounters: DuplexSegmentCounters?

    private var ringtonePlayer: AVAudioPlayer?
    private var ringtoneActive = false

    private var recorder: CallRecorder?
    private var recordingURL: URL?
    private var recordingNumber: String?
    /// Recording armed but waiting for `bothDirectionsStreaming` — audio of a
    /// one-legged call is not a conversation (R14 gate).
    private var recordingPending = false
    private var recordingDrainTask: Task<Void, Never>?
    private var uplinkDrainFormat: AVAudioFormat?
    private var downlinkDrainFormat: AVAudioFormat?
    private var uplinkDrainConverter: AVAudioConverter?
    private var downlinkDrainConverter: AVAudioConverter?
    /// Frames drained per tap read; sized so a 250 ms drain pass stays light.
    private static let drainChunkFrames = 2_048

    /// Only mutated on the main actor; read once in deinit to unregister.
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        catalog.onDevicesChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleDevicesChanged()
            }
        }
        catalog.startWatching()

        // CoreAudio devices re-enumerate across sleep; drop the bridge before
        // sleeping and rebuild from fresh object IDs on wake (R14).
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleSystemSleep() }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleSystemWake() }
            }
        ]

        refreshDevices()
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Device inventory

    /// Re-reads the system audio inventory and re-resolves the module
    /// endpoints by USB parent identity (falling back to name scoring).
    func refreshDevices() {
        let snapshot = catalog.snapshot()
        let prefs = preferences()

        status.outputDevices = snapshot.all.filter(\.hasOutput)
        status.moduleCandidates = snapshot.all.filter { ModuleAudioMatcher.score($0) != nil }
        if let resolution = ModuleAudioTopology.resolve(
            devices: snapshot.all,
            overrideUID: prefs.moduleDeviceUID,
            preferredParent: prefs.preferredModuleParent
        ) {
            status.moduleDevice = resolution.group.captureDevice ?? resolution.group.playbackDevice
            // Direction comes solely from stream scopes, never from USB
            // interface numbers (R14).
            status.moduleInputDevice = resolution.group.captureDevice
            status.moduleOutputDevice = resolution.group.playbackDevice
            status.topologyEvidenceKey = resolution.evidence.localizationKey
        } else {
            status.moduleDevice = nil
            status.moduleInputDevice = nil
            status.moduleOutputDevice = nil
            status.topologyEvidenceKey = nil
        }
        let moduleUIDs = Set([
            status.moduleInputDevice?.uid,
            status.moduleOutputDevice?.uid,
        ].compactMap { $0 })
        status.inputDevices = CallAudioInputSource.eligiblePhysicalInputs(
            from: snapshot.all,
            moduleUIDs: moduleUIDs
        )
        status.selectedInputUID = prefs.inputDeviceUID
        status.selectedOutputUID = prefs.outputDeviceUID
        status.selectedModuleUID = prefs.moduleDeviceUID
    }

    private func handleDevicesChanged() {
        refreshDevices()
        guard desiredLinks else { return }
        // A module re-enumeration replaces its AudioObjectID; rebuild the
        // whole bridge so it addresses the fresh devices.
        scheduleRebuild()
    }

    private func scheduleRebuild(after delay: Duration = .milliseconds(600)) {
        buildGeneration += 1
        let plannedGeneration = buildGeneration
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard self.desiredLinks,
                  BridgeEpochGuard.shouldInstall(
                      rebuildEpoch: plannedGeneration,
                      currentEpoch: self.buildGeneration
                  )
            else { return }
            self.rebuildBridge()
        }
    }

    private func handleSystemSleep() {
        guard desiredLinks else { return }
        stopBridge()
    }

    private func handleSystemWake() {
        guard desiredLinks else { return }
        scheduleRebuild()
    }

    // MARK: - Call lifecycle

    /// Aligns the bridge and ringtone with the current call phase.
    func syncWithCall(phase: CallPhase, remoteNumber: String?) {
        let needed = CallAudioController.linksNeeded(for: phase)
        desiredLinks = needed.uplink || needed.downlink
        recordingNumber = remoteNumber

        switch phase {
        case .incoming:
            startRingtone()
        default:
            stopRingtone()
        }

        if desiredLinks {
            if bridge == nil, remoteBridge == nil {
                startBridge()
            }
        } else {
            deviceRecoveryAttempts = 0
            stopBridge()
            stopRecordingIfRunning()
        }
    }

    /// Stops everything (disconnect, quit).
    func shutdown() {
        desiredLinks = false
        stopBridge()
        systemAudioCaptureDevice?.invalidate()
        systemAudioCaptureDevice = nil
        stopRingtone()
        stopRecordingIfRunning()
    }

    // MARK: - Bridge management

    private func startBridge() {
        buildGeneration += 1
        stopBridge()
        previousCounters = nil
        let prefs = preferences()

        if let remoteTransport = remoteTransportProvider() {
            if CallAudioInputSource.isSystemAudio(prefs.inputDeviceUID) {
                status.micPermissionRaw = CallAudioMicPermission.notRequired.rawValue
                status.lastError = localized("callaudio.error.system_audio_remote_unsupported")
                return
            }
            startRemoteBridge(transport: remoteTransport)
            return
        }

        guard let moduleCapture = status.moduleInputDevice,
              let modulePlayback = status.moduleOutputDevice else {
            recoverFromTransientDeviceLoss(finalErrorKey: "callaudio.error.no_module_device")
            return
        }

        let resolvedInputUID = CallAudioInputSource.resolveLocalSourceUID(
            selectedUID: prefs.inputDeviceUID,
            defaultUID: AudioDeviceCatalog.defaultDeviceUID(
                selector: kAudioHardwarePropertyDefaultInputDevice
            ),
            candidates: status.inputDevices
        )
        let usesSystemAudio = CallAudioInputSource.isSystemAudio(resolvedInputUID)
        let macInputUID: String?
        let micPermission: CallAudioMicPermission
        if usesSystemAudio {
            micPermission = .notRequired
            do {
                if systemAudioCaptureDevice == nil {
                    systemAudioCaptureDevice = try SystemAudioCaptureDevice()
                }
                macInputUID = systemAudioCaptureDevice?.deviceUID
            } catch {
                status.micPermissionRaw = micPermission.rawValue
                status.lastError = Self.describe(error)
                return
            }
        } else {
            micPermission = Self.currentMicPermission()
            macInputUID = resolvedInputUID
        }
        status.micPermissionRaw = micPermission.rawValue
        let preflight = CallAudioPreflight.decide(
            micPermission: micPermission,
            hasUplinkSource: macInputUID != nil,
            moduleInput: status.moduleInputDevice,
            moduleOutput: status.moduleOutputDevice,
            moduleVoiceReady: prefs.moduleVoiceReady
        )
        // The current bridge is duplex by construction, so do not start a
        // partial graph that later fails format resolution or looks healthy
        // while one required leg is absent.
        guard preflight.uplink.allowed, preflight.downlink.allowed else {
            let errorKey = preflight.uplink.errorKey
                ?? preflight.downlink.errorKey
                ?? "callaudio.error.no_module_device"
            if errorKey == "callaudio.error.no_module_device" {
                recoverFromTransientDeviceLoss(finalErrorKey: errorKey)
            } else {
                status.lastError = localized(errorKey)
            }
            return
        }
        status.lastError = nil

        // Resolve the Mac endpoints the same way the bridge will, so the
        // format plan covers exactly the devices that will run.
        let macOutputUID = prefs.outputDeviceUID
            ?? AudioDeviceCatalog.defaultDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice)

        guard let endpointFormats = resolveEndpointFormats(
            macInputUID: macInputUID,
            macOutputUID: macOutputUID,
            moduleCaptureUID: moduleCapture.uid,
            modulePlaybackUID: modulePlayback.uid
        ) else {
            recoverFromTransientDeviceLoss(finalErrorKey: "callaudio.error.device_missing")
            return
        }
        let uplinkSourceRate = endpointFormats.macInputFacts.nominalRate
        let uplinkTargetRate = endpointFormats.modulePlaybackFacts.nominalRate
        let downlinkSourceRate = endpointFormats.moduleCaptureFacts.nominalRate
        let downlinkTargetRate = endpointFormats.macOutputFacts.nominalRate
        uplinkDrainFormat = AVAudioFormat(
            standardFormatWithSampleRate: uplinkTargetRate,
            channels: 1
        )
        downlinkDrainFormat = AVAudioFormat(
            standardFormatWithSampleRate: downlinkTargetRate,
            channels: 1
        )
        uplinkDrainConverter = nil
        downlinkDrainConverter = nil

        status.uplinkRoute = AudioRoutePlan(
            sourceRate: uplinkSourceRate,
            sourceChannels: max(1, endpointFormats.macInputFacts.inputChannels),
            targetRate: uplinkTargetRate,
            targetChannels: max(1, endpointFormats.modulePlaybackFacts.outputChannels)
        )
        status.downlinkRoute = AudioRoutePlan(
            sourceRate: downlinkSourceRate,
            sourceChannels: max(1, endpointFormats.moduleCaptureFacts.inputChannels),
            targetRate: downlinkTargetRate,
            targetChannels: max(1, endpointFormats.macOutputFacts.outputChannels)
        )

        let configuration = CoreAudioDuplexBridge.Configuration(
            macInputUID: macInputUID,
            macOutputUID: macOutputUID,
            moduleCaptureUID: moduleCapture.uid,
            modulePlaybackUID: modulePlayback.uid,
            uplinkSourceRate: uplinkSourceRate,
            uplinkTargetRate: uplinkTargetRate,
            downlinkSourceRate: downlinkSourceRate,
            downlinkTargetRate: downlinkTargetRate,
            volume: status.volume,
            muted: status.muted,
            speakerEnabled: status.speakerEnabled
        )
        let newBridge = CoreAudioDuplexBridge(configuration: configuration)
        do {
            try newBridge.start()
        } catch {
            if error as? CallAudioError == .deviceMissing {
                recoverFromTransientDeviceLoss(finalErrorKey: "callaudio.error.device_missing")
            } else {
                status.lastError = Self.describe(error)
            }
            return
        }
        bridge = newBridge
        deviceRecoveryAttempts = 0
        status.lastError = nil
        if recorder != nil {
            recordingPending = true
        }
        startMetricsPoll()
    }

    /// CoreAudio publishes removal and addition notifications separately
    /// while a USB sound card re-enumerates. Treat the gap as transient,
    /// re-resolve stable UIDs from a fresh inventory, and only surface the
    /// permanent error after a bounded retry window.
    private func recoverFromTransientDeviceLoss(finalErrorKey: String) {
        guard desiredLinks else { return }
        if deviceRecoveryAttempts < Self.maximumDeviceRecoveryAttempts {
            deviceRecoveryAttempts += 1
            status.lastError = localized("callaudio.status.reconnecting_devices")
            refreshDevices()
            scheduleRebuild(after: .milliseconds(800))
        } else {
            status.lastError = localized(finalErrorKey)
        }
    }

    private func startRemoteBridge(transport: RemoteModemTransport) {
        let micPermission = Self.currentMicPermission()
        status.micPermissionRaw = micPermission.rawValue
        guard micPermission != .denied else {
            status.lastError = localized("callaudio.error.mic_denied")
            return
        }
        let newBridge = RemoteCallAudioBridge(transport: transport)
        newBridge.setMuted(status.muted)
        newBridge.setSpeakerEnabled(status.speakerEnabled)
        newBridge.setVolume(status.volume)
        do {
            try newBridge.start()
        } catch {
            status.lastError = Self.describe(error)
            return
        }
        remoteBridge = newBridge
        deviceRecoveryAttempts = 0
        status.lastError = nil
        uplinkDrainFormat = AVAudioFormat(
            standardFormatWithSampleRate: 8_000,
            channels: 1
        )
        downlinkDrainFormat = AVAudioFormat(
            standardFormatWithSampleRate: 8_000,
            channels: 1
        )
        uplinkDrainConverter = nil
        downlinkDrainConverter = nil
        status.uplinkRoute = AudioRoutePlan(
            sourceRate: 48_000,
            sourceChannels: 1,
            targetRate: 8_000,
            targetChannels: 1
        )
        status.downlinkRoute = AudioRoutePlan(
            sourceRate: 8_000,
            sourceChannels: 1,
            targetRate: 48_000,
            targetChannels: 2
        )
        startMetricsPoll()
    }

    private struct EndpointFormats {
        var macInputFacts: DeviceStreamFacts
        var moduleCaptureFacts: DeviceStreamFacts
        var modulePlaybackFacts: DeviceStreamFacts
        var macOutputFacts: DeviceStreamFacts
    }

    /// Resolves the four native device clocks. Conversion happens explicitly
    /// in the bounded bridge rings, so fixed endpoints at different rates are
    /// valid and no device nominal-rate mutation is attempted.
    private func resolveEndpointFormats(
        macInputUID: String?,
        macOutputUID: String?,
        moduleCaptureUID: String,
        modulePlaybackUID: String
    ) -> EndpointFormats? {
        guard let macInputUID,
              let macOutputUID,
              let macInput = AudioDeviceCatalog.streamFacts(uid: macInputUID),
              let moduleCapture = AudioDeviceCatalog.streamFacts(uid: moduleCaptureUID),
              let modulePlayback = AudioDeviceCatalog.streamFacts(uid: modulePlaybackUID),
              let macOutput = AudioDeviceCatalog.streamFacts(uid: macOutputUID),
              macInput.nominalRate > 0,
              moduleCapture.nominalRate > 0,
              modulePlayback.nominalRate > 0,
              macOutput.nominalRate > 0
        else { return nil }
        return EndpointFormats(
            macInputFacts: macInput,
            moduleCaptureFacts: moduleCapture,
            modulePlaybackFacts: modulePlayback,
            macOutputFacts: macOutput
        )
    }

    /// Reads the Mac microphone permission synchronously; the async request
    /// path belongs to preflight UI, not to bridge building.
    private static func currentMicPermission() -> CallAudioMicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    /// Segment-counter watchdog poll: running/streaming flags come only from
    /// counters advancing between polls, per direction and per segment (R14).
    private func startMetricsPoll() {
        guard metricsPollTask == nil else { return }
        metricsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.desiredLinks else { break }
                self.evaluateFrameFlow()
            }
        }
    }

    private func evaluateFrameFlow() {
        if let remoteBridge, remoteBridge.running {
            let snapshot = remoteBridge.snapshot()
            applyFrameFlow(
                counters: snapshot.counters,
                unsupportedFormatEvents: 0
            )
            if let error = snapshot.lastError {
                status.lastError = error
            }
            return
        }
        guard let bridge, bridge.running else {
            status.uplinkRunning = false
            status.downlinkRunning = false
            status.uplinkStreaming = false
            status.downlinkStreaming = false
            return
        }
        let snapshot = bridge.snapshot()
        applyFrameFlow(
            counters: snapshot.counters,
            unsupportedFormatEvents: snapshot.unsupportedFormatEvents,
            uplinkPeak: snapshot.uplinkPeak,
            downlinkPeak: snapshot.downlinkPeak
        )
    }

    private func applyFrameFlow(
        counters: DuplexSegmentCounters,
        unsupportedFormatEvents: UInt64,
        uplinkPeak: Float? = nil,
        downlinkPeak: Float? = nil
    ) {
        let verdict = DuplexWatchdog.evaluate(
            current: counters,
            previous: previousCounters
        )
        previousCounters = counters

        status.uplinkRunning = verdict.uplinkRunning
        status.uplinkStreaming = verdict.uplinkStreaming
        status.downlinkRunning = verdict.downlinkRunning
        status.downlinkStreaming = verdict.downlinkStreaming
        status.uplinkMetrics = CallAudioLinkMetrics(
            inputFrames: counters.macMicCaptureFrames,
            scheduledFrames: counters.modulePlaybackFrames,
            droppedFrames: counters.droppedFrames,
            underruns: counters.starvedFrames,
            conversionErrors: unsupportedFormatEvents,
            peakLevel: uplinkPeak
        )
        status.downlinkMetrics = CallAudioLinkMetrics(
            inputFrames: counters.moduleCaptureFrames,
            scheduledFrames: counters.macSpeakerFrames,
            droppedFrames: counters.droppedFrames,
            underruns: counters.starvedFrames,
            conversionErrors: unsupportedFormatEvents,
            peakLevel: downlinkPeak
        )

        // R14 recording gate: the recorder stays pending until both
        // directions demonstrably stream.
        if recordingPending, verdict.bothDirectionsStreaming, recorder != nil {
            recordingPending = false
        }
    }

    private func stopBridge() {
        buildGeneration += 1
        metricsPollTask?.cancel()
        metricsPollTask = nil
        bridge?.stop()
        bridge = nil
        remoteBridge?.stop()
        remoteBridge = nil
        previousCounters = nil
        status.uplinkRunning = false
        status.downlinkRunning = false
        status.uplinkStreaming = false
        status.downlinkStreaming = false
    }

    private func rebuildBridge() {
        guard desiredLinks else { return }
        stopBridge()
        startBridge()
    }

    /// Rebuilds the bridge when a call is connected — used after device or
    /// preference changes so the new selection takes effect immediately.
    func rebuildLinksIfRunning() {
        guard desiredLinks else { return }
        rebuildBridge()
    }

    /// Mirrors the serialized AT preparation result into the audio surface.
    /// A successful retry clears only the preparation error; link/runtime
    /// errors remain owned by the bridge.
    func noteModuleVoicePreparation(succeeded: Bool) {
        if succeeded {
            if status.lastError == localized("callaudio.error.voice_prepare_failed")
                || status.lastError == localized("callaudio.error.voice_unverified")
                || status.lastError == localized("callaudio.error.voice_disabled") {
                status.lastError = nil
            }
        } else {
            status.lastError = localized("callaudio.error.voice_prepare_failed")
        }
    }

    private static func describe(_ error: Error) -> String {
        if let callAudioError = error as? CallAudioError {
            return localized(callAudioError.localizedKey)
        }
        return error.localizedDescription
    }

    // MARK: - Live controls

    func setMuted(_ muted: Bool) {
        status.muted = muted
        bridge?.setMuted(muted)
        remoteBridge?.setMuted(muted)
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        status.speakerEnabled = enabled
        bridge?.setSpeakerEnabled(enabled)
        remoteBridge?.setSpeakerEnabled(enabled)
    }

    func setVolume(_ volume: Double) {
        status.volume = min(1, max(0, volume))
        bridge?.setVolume(status.volume)
        remoteBridge?.setVolume(status.volume)
    }

    /// Encrypted remote-management audio exchange. The host bridge keeps its
    /// local mic/speaker path while mixing the paired client's uplink and
    /// returning an independent downlink copy at the requested network rate.
    func exchangeRemoteAudio(
        uplink: [Float],
        sampleRate: Double,
        requestedDownlinkFrames: Int
    ) -> [Float] {
        guard let bridge, bridge.running else {
            return [Float](repeating: 0, count: min(max(0, requestedDownlinkFrames), 8_000))
        }
        bridge.enqueueRemoteUplink(uplink, sampleRate: sampleRate)
        return bridge.pullRemoteDownlink(
            frameCount: requestedDownlinkFrames,
            sampleRate: sampleRate
        )
    }

    // MARK: - Recording

    /// Starts recording the current call into the given directory. Both
    /// directions mix into one mono 8 kHz CAF track, but only once both
    /// directions actually stream (R14).
    func startRecording(fileURL: URL) -> Bool {
        guard recorder == nil else { return true }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let newRecorder = CallRecorder(format: format)
        do {
            try newRecorder.start(fileURL: fileURL)
        } catch {
            return false
        }
        recorder = newRecorder
        recordingURL = fileURL
        recordingPending = true
        status.isRecording = true
        status.recordingStartedAt = Date()
        startRecordingDrainLoop()
        return true
    }

    /// Stops recording and files the result through `recordingDidFinish`.
    func stopRecording() {
        guard let finishedRecorder = recorder else { return }
        stopRecordingDrainLoop()
        let finished = finishedRecorder.stop()
        recorder = nil
        recordingPending = false
        status.isRecording = false
        status.recordingStartedAt = nil

        let entry = Self.makeEntry(
            from: finished,
            fileURL: recordingURL,
            number: recordingNumber
        )
        recordingURL = nil
        recordingDidFinish?(entry)
    }

    private func stopRecordingIfRunning() {
        if recorder != nil {
            stopRecording()
        }
    }

    private static func makeEntry(
        from recording: CallRecorder.FinishedRecording?,
        fileURL: URL?,
        number: String?
    ) -> RecordingEntry? {
        guard let recording, let fileURL else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return RecordingEntry(
            fileName: fileURL.lastPathComponent,
            createdAt: Date(),
            duration: recording.duration,
            byteSize: byteSize,
            number: number
        )
    }

    /// Drains the bridge's recorder taps into the `CallRecorder` every
    /// 250 ms. Runs on the service (never in an IOProc); the taps are
    /// bounded rings, so a slow drain drops samples instead of growing.
    private func startRecordingDrainLoop() {
        guard recordingDrainTask == nil else { return }
        recordingDrainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.recorder != nil else { break }
                self.drainRecordingTaps()
            }
        }
    }

    private func stopRecordingDrainLoop() {
        recordingDrainTask?.cancel()
        recordingDrainTask = nil
    }

    private func drainRecordingTaps() {
        guard recorder != nil, !recordingPending else { return }
        if let bridge {
            drainTap(bridge.uplinkTapRing, direction: .uplink)
            drainTap(bridge.downlinkTapRing, direction: .downlink)
        } else if let remoteBridge {
            drainTap(remoteBridge.uplinkTapRing, direction: .uplink)
            drainTap(remoteBridge.downlinkTapRing, direction: .downlink)
        }
    }

    private func drainTap(_ tap: AudioSPSCRing, direction: CallRecorder.Direction) {
        let drainFormat = direction == .uplink ? uplinkDrainFormat : downlinkDrainFormat
        guard let drainFormat, let targetFormat = recorder?.format else { return }
        if direction == .uplink, uplinkDrainConverter == nil {
            uplinkDrainConverter = AVAudioConverter(from: drainFormat, to: targetFormat)
        }
        if direction == .downlink, downlinkDrainConverter == nil {
            downlinkDrainConverter = AVAudioConverter(from: drainFormat, to: targetFormat)
        }
        guard let converter = direction == .uplink ? uplinkDrainConverter : downlinkDrainConverter
        else { return }

        var chunk = [Float](repeating: 0, count: Self.drainChunkFrames)
        while tap.availableFrames > 0 {
            let count = min(Self.drainChunkFrames, tap.availableFrames)
            chunk.withUnsafeMutableBufferPointer { pointer in
                tap.read(into: pointer.baseAddress!, count: count)
            }
            guard let input = AVAudioPCMBuffer(
                pcmFormat: drainFormat,
                frameCapacity: AVAudioFrameCount(count)
            ) else { return }
            input.frameLength = AVAudioFrameCount(count)
            chunk.withUnsafeMutableBufferPointer { pointer in
                input.floatChannelData![0].update(from: pointer.baseAddress!, count: count)
            }

            let ratio = targetFormat.sampleRate / max(1, drainFormat.sampleRate)
            let outCapacity = AVAudioFrameCount(Double(count) * ratio) + 32
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outCapacity
            ) else { return }
            var consumed = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return input
            }
            if status != .error, output.frameLength > 0 {
                recorder?.append(direction, buffer: output)
            }
            if count < Self.drainChunkFrames { break }
        }
    }

    // MARK: - Ringtone

    private func startRingtone() {
        guard !ringtoneActive else { return }
        guard let url = ringtoneURLProvider?() else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.9
            player.prepareToPlay()
            player.play()
            ringtonePlayer = player
            ringtoneActive = true
        } catch {
            // A broken ringtone file must never disturb call handling.
            ringtonePlayer = nil
            ringtoneActive = false
        }
    }

    private func stopRingtone() {
        ringtonePlayer?.stop()
        ringtonePlayer = nil
        ringtoneActive = false
    }
}
