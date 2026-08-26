import Foundation

/// Owns the temporary module-side QDC507 voice runtime for one physical modem.
/// Driver installation is intentionally volatile: files live in `/tmp`, and
/// loaded modules remain until the modem reboots rather than being hot-unloaded.
actor QDC507VoiceRuntimeController {
    private static let remoteDirectory = "/tmp/ec25toolbox-call"
    private static let helper = remoteDirectory + "/mavo-pcm-bridge.armv7"
    private static let routePID = "/run/ec25toolbox-voice-route.pid"
    private static let routeLog = "/run/ec25toolbox-voice-route.log"
    private static let calibrationPID = "/run/ec25toolbox-alsaucm.pid"
    private static let calibrationLog = "/run/ec25toolbox-alsaucm.log"

    private let runtimeStore: ModuleVoiceRuntimeStore
    private var adb: NativeUSBADBClient?
    private var preparedDescriptorID: String?
    private var routeActive = false

    init(runtimeStore: ModuleVoiceRuntimeStore = .shared) {
        self.runtimeStore = runtimeStore
    }

    func isInstalled() async -> Bool {
        await runtimeStore.isInstalled()
    }

    func install(progress: ModuleVoiceRuntimeStore.Progress? = nil) async throws -> URL {
        try await runtimeStore.download(progress: progress)
    }

    func removeInstalledRuntime() async throws {
        guard !routeActive else {
            throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.remove_active"))
        }
        try await runtimeStore.removeInstalledRuntime()
    }

    func prepare(for descriptor: USBModemDescriptor) async throws {
        let directory = try await runtimeStore.installedDirectory()
        if preparedDescriptorID == descriptor.id, let adb {
            let ready = try adb.shell(Self.soundDeviceChecks, timeout: 8)
            if ready.status == 0 { return }
        }

        adb?.close()
        adb = nil
        preparedDescriptorID = nil
        routeActive = false

        let client: NativeUSBADBClient
        do {
            client = try NativeUSBADBClient.open(target: descriptor)
            try client.probeRoot()
        } catch let error as ModuleVoiceRuntimeError {
            throw error
        } catch {
            throw ModuleVoiceRuntimeError.adbUnavailable(error.localizedDescription)
        }

        let kernel = try checkedShell(client, "uname -r", timeout: 8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard kernel == ModuleVoiceRuntimeManifest.kernelRelease else {
            client.close()
            throw ModuleVoiceRuntimeError.unsupportedKernel(
                expected: ModuleVoiceRuntimeManifest.kernelRelease,
                actual: kernel.isEmpty ? localized("common.unknown") : kernel
            )
        }

        _ = try checkedShell(
            client,
            "mkdir -p '\(Self.remoteDirectory)' && chmod 700 '\(Self.remoteDirectory)'",
            timeout: 8
        )
        for artifact in ModuleVoiceRuntimeManifest.deployedArtifacts {
            let localURL = directory.appendingPathComponent(artifact.name)
            let data = try Data(contentsOf: localURL, options: [.mappedIfSafe])
            try ModuleVoiceRuntimeStore.verify(data: data, artifact: artifact)
            try client.push(
                data,
                to: Self.remoteDirectory + "/" + artifact.name,
                permissions: artifact.permissions,
                timeout: 35
            )
        }

        let devicesReady = try client.shell(Self.soundDeviceChecks, timeout: 8).status == 0
        if !devicesReady {
            let legacy = try client.shell("grep -q '^qdc507_afe ' /proc/modules", timeout: 8)
            if legacy.status == 0 {
                throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.legacy_driver"))
            }
            try loadModuleIfNeeded(
                client,
                file: "qdc507_aprv3.ko",
                moduleName: "qdc507_aprv3"
            )
            try loadModuleIfNeeded(
                client,
                file: "qdc507_voice.ko",
                moduleName: "qdc507_voice"
            )
        }

        let waitForDevices = "ready=0; n=0; while test \"$n\" -lt 100; do "
            + "if \(Self.soundDeviceChecks); then ready=1; break; fi; "
            + "sleep 0.2; n=$((n+1)); done; test \"$ready\" -eq 1"
        do {
            _ = try checkedShell(client, waitForDevices, timeout: 25)
        } catch {
            let diagnostics = try? client.shell("dmesg | tail -n 100", timeout: 8).output
            throw ModuleVoiceRuntimeError.commandFailed(
                diagnostics?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? localized("modulevoice.error.sound_devices")
            )
        }

        try ensureCalibration(client)
        _ = try checkedShell(
            client,
            "test -c /dev/ttyGS0 && test -p /run/voc_svr",
            timeout: 8
        )
        _ = try checkedShell(client, "'\(Self.helper)' --check", timeout: 15)

        adb = client
        preparedDescriptorID = descriptor.id
    }

    func startRoute(for descriptor: USBModemDescriptor) async throws {
        try await prepare(for: descriptor)
        guard let adb else {
            throw ModuleVoiceRuntimeError.adbUnavailable(localized("modulevoice.error.adb_not_open"))
        }
        if try routeIsReady(adb) {
            routeActive = true
            return
        }

        let launch = "rm -f '\(Self.routePID)' '\(Self.routeLog)'; "
            + "nohup '\(Self.helper)' --voice-route-session --verbose </dev/null "
            + ">>'\(Self.routeLog)' 2>&1 & pid=$!; "
            + "start=$(cut -d ' ' -f 22 \"/proc/$pid/stat\" 2>/dev/null); "
            + "case \"$pid:$start\" in :*|*:|*[!0-9:]*) false;; "
            + "*) printf '%s %s\\n' \"$pid\" \"$start\" > '\(Self.routePID)';; esac"
        _ = try? adb.shell(launch, timeout: 8)

        let deadline = Date().addingTimeInterval(30)
        while deadline.timeIntervalSinceNow > 0 {
            if try routeIsReady(adb) {
                routeActive = true
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        let log = try? adb.shell(
            "test ! -f '\(Self.routeLog)' || tail -n 160 '\(Self.routeLog)'",
            timeout: 8
        ).output
        try? stopRoute()
        throw ModuleVoiceRuntimeError.commandFailed(
            log?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? localized("modulevoice.error.route_not_running")
        )
    }

    func stopRoute() throws {
        guard let adb else {
            routeActive = false
            return
        }
        let ownership = Self.ownershipCheck(requireRunning: true)
        let stop = "if \(ownership); then "
            + "read pid expected < '\(Self.routePID)'; kill -TERM \"$pid\"; "
            + "n=0; while kill -0 \"$pid\" 2>/dev/null && test \"$n\" -lt 100; do "
            + "sleep 0.1; n=$((n+1)); done; ! kill -0 \"$pid\" 2>/dev/null; "
            + "else false; fi"
        _ = try checkedShell(adb, stop, timeout: 15)
        let stopped = try adb.shell(Self.ownershipCheck(requireRunning: false), timeout: 8)
        guard stopped.status == 0 else {
            throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.route_owner"))
        }
        _ = try checkedShell(
            adb,
            "test \"$(cat /sys/class/android_usb/f_audio/audio_enable 2>/dev/null)\" = 0",
            timeout: 8
        )
        _ = try? adb.shell("rm -f '\(Self.routePID)' '\(Self.routeLog)'", timeout: 8)
        routeActive = false
    }

    func resetAfterDisconnect() {
        adb?.close()
        adb = nil
        preparedDescriptorID = nil
        routeActive = false
    }

    private func loadModuleIfNeeded(
        _ client: NativeUSBADBClient,
        file: String,
        moduleName: String
    ) throws {
        let present = try client.shell("grep -q '^\(moduleName) ' /proc/modules", timeout: 8)
        if present.status == 0 { return }
        guard present.status == 1 else {
            throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.module_list"))
        }
        do {
            _ = try checkedShell(
                client,
                "insmod '\(Self.remoteDirectory)/\(file)'",
                timeout: 20
            )
        } catch {
            let diagnostics = try? client.shell("dmesg | tail -n 100", timeout: 8).output
            throw ModuleVoiceRuntimeError.commandFailed(
                diagnostics?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? error.localizedDescription
            )
        }
    }

    private func ensureCalibration(_ client: NativeUSBADBClient) throws {
        let command = "owned=0; "
            + "if test -s '\(Self.calibrationPID)'; then read pid expected < '\(Self.calibrationPID)' || true; "
            + "current=$(cut -d ' ' -f 22 \"/proc/$pid/stat\" 2>/dev/null); "
            + "argv0=$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p'); "
            + "test \"$current\" = \"$expected\" && test \"$argv0\" = /usr/bin/alsaucm_test && owned=1 || true; fi; "
            + "if test \"$owned\" -eq 0; then rm -f /run/alsaucm_test '\(Self.calibrationPID)' '\(Self.calibrationLog)'; "
            + "nohup /usr/bin/alsaucm_test </dev/null >>'\(Self.calibrationLog)' 2>&1 & pid=$!; "
            + "start=$(cut -d ' ' -f 22 \"/proc/$pid/stat\" 2>/dev/null); "
            + "printf '%s %s\\n' \"$pid\" \"$start\" > '\(Self.calibrationPID)'; "
            + "n=0; while test \"$n\" -lt 50 && test ! -p /run/alsaucm_test; do "
            + "kill -0 \"$pid\" 2>/dev/null || exit 72; sleep 0.1; n=$((n+1)); done; "
            + "test -p /run/alsaucm_test || exit 73; fi; "
            + "if ! grep -q 'ACDB -> Sent VocProc Cal!' '\(Self.calibrationLog)' 2>/dev/null; then "
            + "printf 'open snd_soc_msm_9x07_Tomtom_I2S\\n' > /run/alsaucm_test; "
            + "printf 'set _verb VoLTE\\n' > /run/alsaucm_test; "
            + "printf 'set _enadev Auxpcm Rx\\n' > /run/alsaucm_test; "
            + "printf 'set _enadev Auxpcm Tx\\n' > /run/alsaucm_test; "
            + "n=0; while test \"$n\" -lt 100; do "
            + "grep -q 'ACDB -> Sent VocProc Cal!' '\(Self.calibrationLog)' 2>/dev/null && break; "
            + "sleep 0.1; n=$((n+1)); done; fi; "
            + "grep -q 'ACDB -> Sent VocProc Cal!' '\(Self.calibrationLog)'"
        do {
            _ = try checkedShell(client, command, timeout: 25)
        } catch {
            let log = try? client.shell(
                "test ! -f '\(Self.calibrationLog)' || tail -n 100 '\(Self.calibrationLog)'",
                timeout: 8
            ).output
            throw ModuleVoiceRuntimeError.commandFailed(
                log?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? localized("modulevoice.error.calibration")
            )
        }
    }

    private func routeIsReady(_ client: NativeUSBADBClient) throws -> Bool {
        try client.shell(Self.routeReadyCheck, timeout: 8).status == 0
    }

    private static var soundDeviceChecks: String {
        "test -c /dev/snd/controlC0 && "
            + "test -c /dev/snd/pcmC0D4p && test -c /dev/snd/pcmC0D4c && "
            + "test -c /dev/snd/pcmC0D5p && test -c /dev/snd/pcmC0D6c && "
            + "grep -Fq 'mdm9607-tomtom-i2s-snd-card' /proc/asound/cards"
    }

    private static var routeReadyCheck: String {
        ownershipCheck(requireRunning: true)
            + " && grep -q 'VoLTE route session active on hw:0,4' '\(routeLog)'"
            + " && test \"$(cat /sys/class/android_usb/f_audio/audio_enable)\" = 1"
            + " && grep -q '^state: RUNNING' /proc/asound/card0/pcm4p/sub0/status"
            + " && grep -q '^state: RUNNING' /proc/asound/card0/pcm4c/sub0/status"
    }

    private static func ownershipCheck(requireRunning: Bool) -> String {
        let owned = "test -s '\(routePID)' && read pid expected < '\(routePID)' && "
            + "test \"$(cut -d ' ' -f 22 \"/proc/$pid/stat\" 2>/dev/null)\" = \"$expected\" && "
            + "test \"$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p')\" = '\(helper)' && "
            + "tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | grep -q '^--voice-route-session$'"
        return requireRunning ? owned : "! { \(owned); }"
    }

    @discardableResult
    private func checkedShell(
        _ client: NativeUSBADBClient,
        _ command: String,
        timeout: TimeInterval
    ) throws -> String {
        let result = try client.shell(command, timeout: timeout)
        guard result.status == 0 else {
            throw ModuleVoiceRuntimeError.commandFailed(
                result.output.nonEmpty
                    ?? localizedFormat("modulevoice.error.shell_exit", result.status)
            )
        }
        return result.output
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
