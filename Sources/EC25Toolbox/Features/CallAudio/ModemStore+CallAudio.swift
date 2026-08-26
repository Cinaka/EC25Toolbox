import Foundation

/// Call-audio user actions (P6). None of these touch the AT pipeline: link
/// control, device selection, ringtones, and recordings are local Mac-side
/// operations that must never serialize behind modem commands.
extension ModemStore {
    /// Re-reads the system audio inventory and re-resolves the module device.
    func refreshCallAudioDevices() {
        callAudioService.refreshDevices()
    }

    /// Mutes the uplink by transmitting silence (zeroed buffers), so the far
    /// end never sees an interrupted stream.
    func setCallAudioMuted(_ muted: Bool) {
        callAudioService.setMuted(muted)
    }

    /// Gates downlink playback; recording keeps capturing the remote party.
    func setCallAudioSpeakerEnabled(_ enabled: Bool) {
        callAudioService.setSpeakerEnabled(enabled)
    }

    func setCallAudioVolume(_ volume: Double) {
        callAudioService.setVolume(volume)
    }

    /// Mac-side microphone for the uplink; nil follows the system default.
    func selectCallAudioInputDevice(uid: String?) {
        updateSettings { $0.callAudioInputDeviceUID = uid?.isEmpty == true ? nil : uid }
        callAudioService.refreshDevices()
        callAudioService.rebuildLinksIfRunning()
    }

    /// Mac-side speakers for the downlink; nil follows the system default.
    func selectCallAudioOutputDevice(uid: String?) {
        updateSettings { $0.callAudioOutputDeviceUID = uid?.isEmpty == true ? nil : uid }
        callAudioService.refreshDevices()
        callAudioService.rebuildLinksIfRunning()
    }

    /// Overrides the module sound card pick; nil restores auto-matching.
    func selectCallAudioModuleDevice(uid: String?) {
        updateSettings { $0.callAudioModuleDeviceUID = uid?.isEmpty == true ? nil : uid }
        callAudioService.refreshDevices()
        callAudioService.rebuildLinksIfRunning()
    }

    /// Starts or stops recording the current call. Only permitted while a
    /// call is connected; both directions mix into one mono track.
    func toggleCallRecording() {
        if state.callAudio.isRecording {
            callAudioService.stopRecording()
            return
        }
        guard callMachine.phase == .active || callMachine.phase == .held else { return }
        let scope = currentSIMMessageScope()
        let directory = callRecordingStore.directory(for: scope)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log(localized("callaudio.error.record_failed"))
            return
        }
        let fileURL = directory.appendingPathComponent(
            callRecordingStore.nextFileName(scope: scope, createdAt: Date())
        )
        if callAudioService.startRecording(fileURL: fileURL) {
            log(localized("callaudio.log.recording_started"))
        } else {
            log(localized("callaudio.error.record_failed"))
        }
    }

    /// Arms recording for a newly active call when the persisted preference
    /// is enabled. The ordinary toggle owns file creation and duplicate
    /// protection, so manual and automatic recording share one pipeline.
    func startAutomaticCallRecordingIfNeeded() {
        guard settings.effectiveAutoRecordConnectedCalls,
              !state.callAudio.isRecording,
              callMachine.phase == .active else { return }
        toggleCallRecording()
    }

    /// Reloads the recording list for the current SIM identity scope.
    func reloadCallRecordings() {
        state.recordings = callRecordingStore.load(scope: currentSIMMessageScope())
    }

    /// Deletes one recording after UI-level confirmation.
    func deleteCallRecording(_ entry: RecordingEntry) {
        state.recordings = callRecordingStore.delete(entry, scope: currentSIMMessageScope())
        log(localized("recordings.log.deleted"))
    }

    /// File URL for playback, Quick Look, and export of one recording.
    func callRecordingURL(_ entry: RecordingEntry) -> URL? {
        let url = callRecordingStore.fileURL(for: entry, scope: currentSIMMessageScope())
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Copies a picked audio file into the ringtone library and selects it.
    func importRingtone(from url: URL) {
        do {
            let name = try ringtoneStore.importFile(at: url)
            updateSettings { $0.ringtoneFileName = name }
            log(localized("callaudio.ringtone.log.imported"))
        } catch {
            log(error.localizedDescription)
        }
    }

    /// nil disables the ringtone (incoming calls stay notification-only).
    func selectRingtone(_ fileName: String?) {
        updateSettings { $0.ringtoneFileName = fileName }
    }

    /// Deletes one stored ringtone, deselecting it if it was active.
    func deleteRingtone(_ fileName: String) {
        ringtoneStore.delete(fileName)
        if settings.ringtoneFileName == fileName {
            updateSettings { $0.ringtoneFileName = nil }
        }
        log(localized("callaudio.ringtone.log.deleted"))
    }
}
