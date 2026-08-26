import Foundation

/// Network service actions isolated from the AT command flows. Discovery and
/// status reads run directly (no privileges needed); creating or changing the
/// dedicated modem service is routed through the privileged system helper.
extension ModemStore {
    /// Re-reads the module NIC and its bound service. Pure read: safe on every
    /// plug/unplug, wake, or re-enumeration, and never duplicates anything.
    func refreshNetworkStatus() {
        runRefresh {
            self.refreshNetworkStatusImpl()
        }
    }

    /// Snapshot helper shared by the user action and the general refresh flow.
    func refreshNetworkStatusImpl() {
        var status = ModemNICDiscovery.currentStatus()
        status.defaultPath = state.network.defaultPath
        status.traffic = state.network.traffic
        status.lastSession = state.network.lastSession
        state.network = status
        syncTrafficSampling(bsdName: status.nic?.bsdName)
        refreshExitFacts()
    }

    /// Samples link facts and proxy settings for the current snapshots. Split
    /// from the NIC discovery so default-path updates can refresh them too.
    func refreshExitFacts() {
        if let bsdName = state.network.nic?.bsdName {
            state.network.moduleLink = InterfaceFacts.linkSnapshot(bsdName: bsdName)
        } else {
            state.network.moduleLink = InterfaceLinkSnapshot()
        }
        let exitBSD = state.network.defaultPath.interfaceBSD ?? ""
        state.network.exitLink = exitBSD.isEmpty
            ? nil
            : InterfaceFacts.linkSnapshot(bsdName: exitBSD)
        state.network.proxy = InterfaceFacts.systemProxy()
        applyExitPolicyAutomation()
    }

    /// Applies the exit policy to the app-managed module service. Only the
    /// dedicated module service is ever toggled; manual mode never acts.
    func applyExitPolicyAutomation() {
        guard let service = state.network.service else { return }
        let decision = ExitPolicyDecision.moduleServiceShouldBeEnabled(
            policy: settings.effectiveExitPolicy,
            moduleBSD: state.network.nic?.bsdName,
            defaultPath: state.network.defaultPath
        )
        guard let decision, decision != service.enabled else { return }
        setModuleNetworkServiceEnabled(decision)
    }

    // MARK: - Traffic sampling

    /// Keeps the sampling loop aligned with the currently discovered NIC:
    /// starts it when a module interface exists, persists and stops it when
    /// the interface disappears or re-enumerates under a different BSD name.
    func syncTrafficSampling(bsdName: String?) {
        if let bsdName {
            if trafficSampledBSDName != bsdName {
                stopTrafficSampling(persist: true)
            }
            trafficSampledBSDName = bsdName
            startTrafficSampling(bsdName: bsdName)
        } else {
            trafficSampledBSDName = nil
            stopTrafficSampling(persist: true)
        }
    }

    /// Samples interface counters every two seconds while the module NIC is
    /// the one being watched.
    private func startTrafficSampling(bsdName: String) {
        guard trafficPollTask == nil else { return }
        state.network.lastSession = trafficArchive.lastSession()
        trafficPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.trafficSampledBSDName == bsdName else { break }
                self.collectTrafficSample(bsdName: bsdName)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Cancels the loop and, when requested, archives the finished session.
    func stopTrafficSampling(persist: Bool) {
        trafficPollTask?.cancel()
        trafficPollTask = nil
        trafficLastSample = nil
        guard persist, let session = state.network.traffic.session, session.hasTraffic else { return }
        trafficArchive.record(TrafficSessionRecord(
            id: UUID(),
            startedAt: session.startedAt,
            endedAt: Date(),
            bytesIn: session.bytesIn,
            bytesOut: session.bytesOut,
            peakBytesInPerSecond: session.peakBytesInPerSecond,
            peakBytesOutPerSecond: session.peakBytesOutPerSecond
        ))
        state.network.lastSession = trafficArchive.lastSession()
        state.network.traffic = TrafficStatus()
    }

    private func collectTrafficSample(bsdName: String) {
        guard let counters = TrafficCounterReader.counters(bsdName: bsdName) else { return }
        let sample = TrafficSample(
            date: Date(),
            bytesIn: counters.bytesIn,
            bytesOut: counters.bytesOut
        )
        guard let previous = trafficLastSample else {
            trafficLastSample = sample
            return
        }
        trafficLastSample = sample
        guard let step = TrafficMath.step(
            session: state.network.traffic.session,
            previous: previous,
            current: sample
        ) else { return }
        state.network.traffic.append(step.point)
        state.network.traffic.session = step.session
    }

    /// Gives the module NIC a dedicated, DHCP-based network service. Idempotent:
    /// an existing service bound to the NIC is reused (re-enabled if disabled)
    /// instead of creating a duplicate; the user's other services are never
    /// touched.
    func configureModuleNetworkService() {
        run {
            let nic = ModemNICDiscovery.discoverModuleNICs().first
            let plan = ModemNetworkPlan.servicePlan(
                nic: nic,
                services: ModemNICDiscovery.currentServices(),
                preferredName: localized("network.service.default_name")
            )
            switch plan {
            case .noInterface:
                throw ModemNetworkError.noInterface
            case let .useExisting(existing):
                if !existing.enabled {
                    try await self.systemHelper.networkSetServiceEnabled(
                        serviceID: existing.serviceID,
                        enabled: true
                    )
                }
            case let .create(bsdName, serviceName):
                try await self.systemHelper.networkCreateService(
                    bsdName: bsdName,
                    serviceName: serviceName
                )
            }
            self.refreshNetworkStatusImpl()
        }
    }

    /// Enables or disables the dedicated modem service through the helper.
    /// Toggling other services is intentionally not offered.
    func setModuleNetworkServiceEnabled(_ enabled: Bool) {
        run {
            guard let service = self.state.network.service else {
                throw ModemNetworkError.noService
            }
            try await self.systemHelper.networkSetServiceEnabled(
                serviceID: service.serviceID,
                enabled: enabled
            )
            self.refreshNetworkStatusImpl()
        }
    }
}
