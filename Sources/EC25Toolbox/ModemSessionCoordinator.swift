import Combine
import Foundation

/// One independently running physical-module session.
struct ModemDeviceSession: Identifiable {
    var descriptor: USBModemDescriptor
    var store: ModemStore

    /// IMEI-derived once available; provisional USB identity before the first
    /// successful `AT+CGSN` read.
    var id: String { descriptor.moduleID }
}

/// A physical or remote session whose call currently needs an operable UI.
/// The descriptor-less fallback keeps remote mode compatible with the same
/// presentation routing used by locally attached modules.
struct ModemLiveSession: Identifiable {
    var id: String
    var store: ModemStore
}

/// App-wide owner of all direct-module sessions.
///
/// AT/event/polling state stays inside one `ModemStore` per physical module.
/// This coordinator only owns discovery, selected-device presentation,
/// shared preference propagation, module notes, and notification routing.
@MainActor
final class ModemSessionCoordinator: ObservableObject {
    static let fallbackDeviceID = "default"

    @Published private(set) var sessions: [ModemDeviceSession] = []
    @Published private(set) var knownDevices: [USBModemDescriptor] = []
    @Published private(set) var unboundDevices: [USBModemDescriptor] = []
    @Published private(set) var availableDeviceIDs: Set<String> = []
    @Published private(set) var sharedSettings: ModemSettings
    @Published var selectedDeviceID: String {
        didSet {
            guard selectedDeviceID != oldValue else { return }
            defaults.set(selectedDeviceID, forKey: Self.selectedDeviceDefaultsKey)
            objectWillChange.send()
            aggregateStateDidChange?()
        }
    }

    var aggregateStateDidChange: (() -> Void)?

    private let defaults: UserDefaults
    private let fallbackStore: ModemStore
    private let sharedSMSArchive: SMSArchiveStore
    private let sharedCallLogStore: CallLogStore
    private var moduleNotes: [String: String]
    private var sessionObservations: [String: AnyCancellable] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var lastDiscoveredDevices: [USBModemDescriptor] = []
    /// Session-only suppression after a retained unbound record is deleted.
    /// It prevents a still-attached module from jumping straight back into
    /// the UI, but clears once that physical identity disappears.
    private var forgottenUntilDetachIDs: Set<String> = []
    private let startsDeviceSessions: Bool
    private var started = false

    private var smsContactNameResolver: ((String) -> String?)?
    private var callContactNameResolver: ((String) -> String?)?
    private var callContactSnapshotReload: (@MainActor () async -> Void)?
    private var smsSurfaceVisibility: ((String) -> Bool)?

    private static let notesDefaultsKey = "module-notes-v1"
    private static let knownDevicesDefaultsKey = "known-modules-v1"
    private static let unboundDevicesDefaultsKey = "unbound-modules-v1"
    private static let selectedDeviceDefaultsKey = "selected-module-v1"

    init(
        defaults: UserDefaults = .standard,
        smsArchive: SMSArchiveStore? = nil,
        callLogStore: CallLogStore? = nil,
        initialSettings: ModemSettings? = nil,
        startsDeviceSessions: Bool = true
    ) {
        self.defaults = defaults
        self.startsDeviceSessions = startsDeviceSessions
        sharedSMSArchive = smsArchive ?? SMSArchiveStore()
        sharedCallLogStore = callLogStore ?? CallLogStore()
        fallbackStore = ModemStore(
            callLogStore: sharedCallLogStore,
            smsArchive: sharedSMSArchive,
            ownsGlobalServices: true
        )
        if let initialSettings {
            fallbackStore.settings = initialSettings
        }
        sharedSettings = fallbackStore.settings
        moduleNotes = Self.decode([String: String].self, from: defaults, key: Self.notesDefaultsKey) ?? [:]
        knownDevices = Self.decode(
            [USBModemDescriptor].self,
            from: defaults,
            key: Self.knownDevicesDefaultsKey
        ) ?? []
        unboundDevices = Self.decode(
            [USBModemDescriptor].self,
            from: defaults,
            key: Self.unboundDevicesDefaultsKey
        ) ?? []
        selectedDeviceID = defaults.string(forKey: Self.selectedDeviceDefaultsKey)
            ?? Self.fallbackDeviceID
        let unboundModuleIDs = Set(unboundDevices.map(\.moduleID))
        let unboundTransportIDs = Set(unboundDevices.map(\.id))
        knownDevices.removeAll {
            unboundModuleIDs.contains($0.moduleID) || unboundTransportIDs.contains($0.id)
        }
        wireStore(fallbackStore)
    }

    /// Test/preview adapter that preserves the existing single-store hosting
    /// API without starting hardware discovery.
    init(singleStore: ModemStore) {
        defaults = UserDefaults.standard
        fallbackStore = singleStore
        sharedSMSArchive = singleStore.smsArchive
        sharedCallLogStore = singleStore.callLogStore
        sharedSettings = singleStore.settings
        moduleNotes = [:]
        startsDeviceSessions = false
        selectedDeviceID = Self.fallbackDeviceID
        wireStore(singleStore)
    }

    deinit {
        discoveryTask?.cancel()
    }

    var selectedStore: ModemStore {
        store(for: selectedDeviceID) ?? sessions.first?.store ?? fallbackStore
    }

    /// Orderly app-termination boundary: stop owned module voice helpers before
    /// USB sessions disappear, then tear down every store. This is awaited by
    /// AppDelegate through AppKit's terminate-later reply.
    func shutdownForApplicationTermination() async {
        var stores = sessions.map(\.store)
        if !stores.contains(where: { $0 === fallbackStore }) {
            stores.append(fallbackStore)
        }
        for store in stores {
            store.callAudioService.shutdown()
            await store.shutdownQDC507VoiceRuntime()
        }
        for store in stores {
            store.stopSession()
        }
    }

    var selectedDescriptor: USBModemDescriptor? {
        sessions.first(where: { $0.id == selectedDeviceID })?.descriptor
            ?? knownDevices.first(where: { $0.moduleID == selectedDeviceID })
    }

    var liveSessions: [ModemLiveSession] {
        var live = sharedSettings.effectiveManagementMode == .direct
            ? sessions.compactMap { session -> ModemLiveSession? in
            guard CallTakeoverView.isLiveCallPhase(session.store.state.call.phase) else { return nil }
            return ModemLiveSession(id: session.id, store: session.store)
        } : []
        if (sharedSettings.effectiveManagementMode == .remote || sessions.isEmpty),
           CallTakeoverView.isLiveCallPhase(fallbackStore.state.call.phase) {
            live.append(ModemLiveSession(id: Self.fallbackDeviceID, store: fallbackStore))
        }
        return live.sorted {
            if $0.id == selectedDeviceID { return true }
            if $1.id == selectedDeviceID { return false }
            return $0.store.moduleDisplayName.localizedStandardCompare(
                $1.store.moduleDisplayName
            ) == .orderedAscending
        }
    }

    var focusedLiveSession: ModemLiveSession? {
        liveSessions.first
    }

    var hasIncomingCall: Bool {
        activeStores.contains {
            $0.state.call.phase == .incoming || $0.state.call.phase == .answering
        }
    }

    var connectedCount: Int {
        activeStores.count(where: { $0.state.connected })
    }

    var aggregateUnreadCount: Int {
        activeStores.reduce(0) { $0 + $1.state.unreadCount }
    }

    var aggregateMissedCallCount: Int {
        activeStores.reduce(0) {
            $0 + $1.state.callLog.count(where: \.isUnacknowledgedMissedCall)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        if sharedSettings.effectiveManagementMode == .remote {
            fallbackStore.start()
        }
        refreshDiscoveredDevices()
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.refreshDiscoveredDevices()
            }
        }
    }

    func store(for deviceID: String) -> ModemStore? {
        if deviceID == Self.fallbackDeviceID { return fallbackStore }
        return sessions.first(where: { $0.id == deviceID })?.store
    }

    func selectDevice(_ deviceID: String) {
        guard deviceID == Self.fallbackDeviceID
            || sessions.contains(where: { $0.id == deviceID }) else { return }
        selectedDeviceID = deviceID
    }

    func displayName(for descriptor: USBModemDescriptor) -> String {
        let note = moduleNotes[descriptor.moduleID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !note.isEmpty { return note }
        return descriptor.imei ?? descriptor.productName ?? descriptor.displaySerial
    }

    func notificationName(for deviceID: String) -> String {
        guard let descriptor = sessions.first(where: { $0.id == deviceID })?.descriptor
            ?? knownDevices.first(where: { $0.moduleID == deviceID }) else {
            return localized("app.name")
        }
        let name = displayName(for: descriptor)
        let identity = descriptor.imei ?? descriptor.displaySerial
        return name == identity ? name : "\(name) · \(identity)"
    }

    func note(for deviceID: String) -> String {
        moduleNotes[deviceID] ?? ""
    }

    func setNote(_ note: String, for deviceID: String) {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            moduleNotes.removeValue(forKey: deviceID)
        } else {
            // Preserve the edit buffer exactly while it contains meaningful
            // text; displayName performs its own trimming.
            moduleNotes[deviceID] = note
        }
        Self.encode(moduleNotes, into: defaults, key: Self.notesDefaultsKey)
        objectWillChange.send()
        aggregateStateDidChange?()
    }

    /// Removes a module from the bound registry and ends its background
    /// session. The descriptor is retained in the unbound registry so USB
    /// discovery cannot immediately add it again. SIM-scoped content is not
    /// touched by this hardware-management action.
    func unbindDevice(_ deviceID: String) {
        guard deviceID != Self.fallbackDeviceID,
              let descriptor = sessions.first(where: { $0.id == deviceID })?.descriptor
                ?? knownDevices.first(where: { $0.moduleID == deviceID })
        else { return }

        if let index = sessions.firstIndex(where: { $0.id == deviceID }) {
            let removed = sessions.remove(at: index)
            sessionObservations.removeValue(forKey: removed.descriptor.id)
            let transferredGlobalOwnership = removed.store.ownsGlobalServices
            removed.store.stopSession()
            if transferredGlobalOwnership {
                sessions.first?.store.setGlobalServicesOwnership(true)
            }
        }

        knownDevices.removeAll {
            $0.moduleID == descriptor.moduleID || $0.id == descriptor.id
        }
        Self.upsert(descriptor, into: &unboundDevices)
        moduleNotes.removeValue(forKey: descriptor.moduleID)
        if descriptor.moduleID != descriptor.id {
            moduleNotes.removeValue(forKey: descriptor.id)
        }
        persistDeviceRegistry()

        if selectedDeviceID == deviceID || store(for: selectedDeviceID) == nil {
            selectedDeviceID = sessions.first?.id ?? Self.fallbackDeviceID
        }
        objectWillChange.send()
        aggregateStateDidChange?()
    }

    /// Explicitly allows a previously unbound module to participate again.
    /// If it is still attached, reconciliation immediately starts a fresh
    /// hardware session; otherwise it remains known until the next attach.
    func bindDevice(_ deviceID: String) {
        guard let descriptor = unboundDevices.first(where: { $0.moduleID == deviceID }) else { return }
        unboundDevices.removeAll { $0.moduleID == deviceID }
        Self.upsert(descriptor, into: &knownDevices)
        persistDeviceRegistry()
        reconcile(discovered: lastDiscoveredDevices)
    }

    /// Removes the retained unbound-device tombstone and every remaining
    /// hardware-local association. Because the identity is no longer kept in
    /// the suppression registry, an attached module can be discovered again
    /// as a new device. SIM-scoped messages, calls, and recordings are never
    /// touched by this hardware-registry action.
    func forgetUnboundDevice(_ deviceID: String) {
        guard deviceID != Self.fallbackDeviceID,
              let descriptor = unboundDevices.first(where: { $0.moduleID == deviceID })
        else { return }

        forgottenUntilDetachIDs.insert(descriptor.id)
        forgottenUntilDetachIDs.insert(descriptor.moduleID)
        unboundDevices.removeAll {
            $0.moduleID == descriptor.moduleID || $0.id == descriptor.id
        }
        knownDevices.removeAll {
            $0.moduleID == descriptor.moduleID || $0.id == descriptor.id
        }
        moduleNotes.removeValue(forKey: descriptor.moduleID)
        if descriptor.moduleID != descriptor.id {
            moduleNotes.removeValue(forKey: descriptor.id)
        }
        persistDeviceRegistry()
        objectWillChange.send()
        aggregateStateDidChange?()
    }

    func configurePresentationServices(
        smsContactNameResolver: @escaping (String) -> String?,
        callContactNameResolver: @escaping (String) -> String?,
        callContactSnapshotReload: @escaping @MainActor () async -> Void,
        isSMSSurfaceVisible: @escaping (String) -> Bool
    ) {
        self.smsContactNameResolver = smsContactNameResolver
        self.callContactNameResolver = callContactNameResolver
        self.callContactSnapshotReload = callContactSnapshotReload
        smsSurfaceVisibility = isSMSSurfaceVisible
        for store in allStores {
            applyPresentationServices(to: store)
        }
    }

    /// Internal deterministic reconciliation seam used by tests and the USB
    /// discovery loop. Existing sessions survive temporary disappearance so
    /// reconnect, history, and selected-device state remain stable.
    func reconcile(discovered descriptors: [USBModemDescriptor]) {
        lastDiscoveredDevices = descriptors
        availableDeviceIDs = Set(descriptors.map(\.id))
        clearForgottenDevicesThatDetached(from: descriptors)
        refreshUnboundDescriptors(from: descriptors)

        let boundDescriptors = descriptors
            .filter { !isUnbound($0) && !isForgottenUntilDetach($0) }
            .map(enrichWithKnownIdentity)
        mergeKnownDevices(boundDescriptors)

        // Remote mode is represented by the descriptor-less fallback store;
        // local hardware remains known for notes but must not spawn duplicate
        // sessions that all connect to the same remote endpoint.
        guard sharedSettings.effectiveManagementMode == .direct else {
            if selectedDeviceID != Self.fallbackDeviceID {
                selectedDeviceID = Self.fallbackDeviceID
            }
            aggregateStateDidChange?()
            return
        }

        // USB topology can change while the IMEI-derived module identity
        // remains stable. Refresh that locator in place so audio/NMEA keep
        // following the same hardware after a port move.
        for descriptor in boundDescriptors {
            guard let index = sessions.firstIndex(where: { $0.descriptor.id == descriptor.id }) else { continue }
            sessions[index].descriptor = descriptor
            sessions[index].store.updateModuleDescriptor(descriptor)
        }

        for descriptor in boundDescriptors where !sessions.contains(where: { $0.descriptor.id == descriptor.id }) {
            let store = ModemStore(
                callLogStore: sharedCallLogStore,
                smsArchive: sharedSMSArchive,
                moduleDescriptor: descriptor,
                ownsGlobalServices: sessions.isEmpty
                    && sharedSettings.effectiveManagementMode == .direct
            )
            store.applySharedSettings(sharedSettings)
            wireStore(store)
            sessions.append(ModemDeviceSession(descriptor: descriptor, store: store))
            sessions.sort {
                displayName(for: $0.descriptor).localizedStandardCompare(
                    displayName(for: $1.descriptor)
                ) == .orderedAscending
            }
            if startsDeviceSessions { store.start() }
        }

        if selectedDeviceID == Self.fallbackDeviceID,
           sharedSettings.effectiveManagementMode == .direct,
           let first = sessions.first {
            selectedDeviceID = first.id
        } else if store(for: selectedDeviceID) == nil, let first = sessions.first {
            selectedDeviceID = first.id
        }
        objectWillChange.send()
        aggregateStateDidChange?()
    }

    private var activeStores: [ModemStore] {
        if sharedSettings.effectiveManagementMode == .remote { return [fallbackStore] }
        return sessions.isEmpty ? [fallbackStore] : sessions.map(\.store)
    }

    private var allStores: [ModemStore] {
        [fallbackStore] + sessions.map(\.store)
    }

    private func refreshDiscoveredDevices() {
        Task { [weak self] in
            let descriptors = await Task.detached(priority: .utility) {
                EC25Transport.discoverDevices()
            }.value
            guard let self else { return }
            self.reconcile(discovered: descriptors)
        }
    }

    private func wireStore(_ store: ModemStore) {
        store.moduleDisplayNameProvider = { [weak self, weak store] in
            guard let store else { return localized("app.name") }
            return self?.notificationName(for: store.moduleIdentifier)
                ?? store.moduleDescriptor?.displaySerial
                ?? localized("app.name")
        }
        store.moduleIMEIDidResolve = { [weak self, weak store] imei in
            guard let self, let store else { return }
            self.resolveIMEI(imei, for: store)
        }
        store.settingsDidChange = { [weak self, weak store] settings in
            guard let self else { return }
            let previousMode = self.sharedSettings.effectiveManagementMode
            self.sharedSettings = settings
            for other in self.allStores where other !== store {
                other.applySharedSettings(settings)
            }
            if previousMode != settings.effectiveManagementMode {
                if settings.effectiveManagementMode == .remote {
                    self.fallbackStore.start()
                    self.selectedDeviceID = Self.fallbackDeviceID
                } else {
                    if let first = self.sessions.first {
                        self.selectedDeviceID = first.id
                    }
                    self.refreshDiscoveredDevices()
                }
            }
            self.aggregateStateDidChange?()
        }
        applyPresentationServices(to: store)
        let observationKey = store.moduleDescriptor?.id ?? Self.fallbackDeviceID
        sessionObservations[observationKey] = store.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            DispatchQueue.main.async { [weak self] in
                self?.aggregateStateDidChange?()
            }
        }
    }

    private func applyPresentationServices(to store: ModemStore) {
        store.smsContactNameResolver = smsContactNameResolver
        store.callContactNameResolver = callContactNameResolver
        store.callContactSnapshotReload = callContactSnapshotReload
        store.isSMSSurfaceVisible = { [weak self, weak store] in
            guard let store else { return false }
            return self?.smsSurfaceVisibility?(store.moduleIdentifier) ?? false
        }
    }

    private func mergeKnownDevices(_ descriptors: [USBModemDescriptor]) {
        var byID: [String: USBModemDescriptor] = [:]
        for descriptor in knownDevices { byID[descriptor.moduleID] = descriptor }
        for descriptor in descriptors {
            // A descriptor may have been persisted first with its provisional
            // USB key and later resolved to IMEI. Remove that provisional row
            // before inserting the stable identity.
            if descriptor.moduleID != descriptor.id {
                byID.removeValue(forKey: descriptor.id)
            }
            byID[descriptor.moduleID] = descriptor
        }
        let merged = byID.values.sorted { $0.displaySerial < $1.displaySerial }
        guard merged != knownDevices else { return }
        knownDevices = merged
        Self.encode(merged, into: defaults, key: Self.knownDevicesDefaultsKey)
    }

    private func enrichWithKnownIdentity(_ descriptor: USBModemDescriptor) -> USBModemDescriptor {
        guard descriptor.imei == nil,
              let remembered = knownDevices.first(where: { $0.id == descriptor.id }),
              let imei = remembered.imei
        else { return descriptor }
        var enriched = descriptor
        enriched.imei = imei
        return enriched
    }

    private func isUnbound(_ descriptor: USBModemDescriptor) -> Bool {
        unboundDevices.contains {
            $0.id == descriptor.id || $0.moduleID == descriptor.moduleID
        }
    }

    private func isForgottenUntilDetach(_ descriptor: USBModemDescriptor) -> Bool {
        forgottenUntilDetachIDs.contains(descriptor.id)
            || forgottenUntilDetachIDs.contains(descriptor.moduleID)
    }

    private func clearForgottenDevicesThatDetached(from descriptors: [USBModemDescriptor]) {
        guard !forgottenUntilDetachIDs.isEmpty else { return }
        let presentIDs = Set(descriptors.flatMap { [$0.id, $0.moduleID] })
        forgottenUntilDetachIDs.formIntersection(presentIDs)
    }

    private func refreshUnboundDescriptors(from descriptors: [USBModemDescriptor]) {
        var refreshed = unboundDevices
        for descriptor in descriptors {
            guard let index = refreshed.firstIndex(where: { $0.id == descriptor.id }) else { continue }
            var current = descriptor
            current.imei = refreshed[index].imei
            refreshed[index] = current
        }
        guard refreshed != unboundDevices else { return }
        unboundDevices = refreshed
        Self.encode(refreshed, into: defaults, key: Self.unboundDevicesDefaultsKey)
    }

    private func resolveIMEI(_ value: String, for store: ModemStore) {
        guard let imei = USBModemDescriptor.normalizedIMEI(value),
              let index = sessions.firstIndex(where: { $0.store === store })
        else { return }

        let oldDescriptor = sessions[index].descriptor
        guard oldDescriptor.imei != imei else { return }
        let oldID = oldDescriptor.moduleID
        var resolved = oldDescriptor
        resolved.imei = imei
        let newID = resolved.moduleID

        sessions[index].descriptor = resolved
        store.updateModuleDescriptor(resolved)

        if moduleNotes[newID] == nil, let oldNote = moduleNotes.removeValue(forKey: oldID) {
            moduleNotes[newID] = oldNote
        } else {
            moduleNotes.removeValue(forKey: oldID)
        }

        knownDevices.removeAll {
            $0.id == oldDescriptor.id || $0.moduleID == newID
        }
        knownDevices.append(resolved)
        knownDevices.sort { displayName(for: $0) < displayName(for: $1) }
        if selectedDeviceID == oldID { selectedDeviceID = newID }
        persistDeviceRegistry()

        // A port-only provisional identity can reconnect from another USB
        // location. Once its IMEI proves that it is an explicitly unbound
        // module, immediately end the probe session and keep it unbound.
        if unboundDevices.contains(where: { $0.moduleID == newID }) {
            unbindDevice(newID)
            return
        }
        objectWillChange.send()
        aggregateStateDidChange?()
    }

    private static func upsert(_ descriptor: USBModemDescriptor, into devices: inout [USBModemDescriptor]) {
        devices.removeAll {
            $0.moduleID == descriptor.moduleID || $0.id == descriptor.id
        }
        devices.append(descriptor)
        devices.sort { ($0.imei ?? $0.displaySerial) < ($1.imei ?? $1.displaySerial) }
    }

    private func persistDeviceRegistry() {
        Self.encode(knownDevices, into: defaults, key: Self.knownDevicesDefaultsKey)
        Self.encode(unboundDevices, into: defaults, key: Self.unboundDevicesDefaultsKey)
        Self.encode(moduleNotes, into: defaults, key: Self.notesDefaultsKey)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from defaults: UserDefaults,
        key: String
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<Value: Encodable>(
        _ value: Value,
        into defaults: UserDefaults,
        key: String
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
