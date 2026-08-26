import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

private enum ESTKDownloadMode: String, CaseIterable, Identifiable {
    case activationCode
    case manual

    var id: String { rawValue }
}

private enum ESTKCategory: String, CaseIterable, Identifiable, SettingsCategoryItem {
    case profiles
    case download
    case euicc
    case notifications
    case tools

    var id: String { rawValue }
    var title: String { "estk.category.\(rawValue)" }
    var description: String { "estk.category.\(rawValue).description" }

    var systemImage: String {
        switch self {
        case .profiles: "rectangle.stack"
        case .download: "square.and.arrow.down"
        case .euicc: "simcard"
        case .notifications: "bell.badge"
        case .tools: "wrench.and.screwdriver"
        }
    }
}

/// Native eSTK/eUICC profile manager backed by lpac over the modem's APDU channel.
struct ESTKView: View {
    @EnvironmentObject private var store: ModemStore

    @State private var selectedCategory: ESTKCategory = .profiles
    @State private var activationCode = ""
    @State private var downloadMode = ESTKDownloadMode.activationCode
    @State private var smdpAddress = ""
    @State private var matchingID = ""
    @State private var confirmationCode = ""
    @State private var importingActivationCode = false
    @State private var activationImportError: String?
    @State private var smdsAddress = "lpa.ds.gsma.com"
    @State private var defaultSMDPAddress = ""
    @State private var renamingProfile: ESTKProfile?
    @State private var nickname = ""
    @State private var pendingProfileDeletion: ESTKProfile?
    @State private var pendingNotificationDeletion: ESTKNotification?
    @State private var pendingDeleteAllNotifications = false
    @State private var pendingMemoryReset = false
    @State private var memoryResetConfirmation = ""
    @State private var isdRAID = ESTKDefaults.isdRAID
    @State private var es10xMSS = ESTKDefaults.es10xMSS
    @State private var notifyDownloads = true
    @State private var notifyDeletions = true
    @State private var notifySwitches = false
    @State private var httpProxy = ""
    @State private var ignoreTLSCertificate = false
    @State private var loadedSettings = false

    private var hasEUICC: Bool { store.state.estk.chipInfo != nil }

    var body: some View {
        SettingsCategoryLayout(
            categories: ESTKCategory.allCases,
            owningTab: .estk,
            selection: $selectedCategory
        ) {
            SettingsCategoryHeader(
                title: selectedCategory.title,
                description: selectedCategory.description,
                systemImage: selectedCategory.systemImage
            ) {
                Button {
                    selectedCategory = .download
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(localized("estk.download.open"))
                .disabled(store.state.busy || !store.state.connected || !hasEUICC)

                Button {
                    store.refreshESTK()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(localized("estk.refresh"))
                .disabled(store.state.busy || !store.state.connected)
            }
        } content: {
            categoryContent
        }
        .task {
            loadSettingsIfNeeded()
            if store.state.connected,
               store.state.estk.chipInfo == nil,
               store.state.estk.lastError == nil,
               !store.state.busy {
                store.refreshESTK()
            }
        }
        .onChange(of: store.state.estk.chipInfo) {
            loadChipDefaults()
        }
        .modifier(ESTKProfileDeleteAlert(profile: $pendingProfileDeletion))
        .modifier(ESTKNotificationDeleteAlert(notification: $pendingNotificationDeletion))
        .modifier(ESTKRemoveAllNotificationsAlert(isPresented: $pendingDeleteAllNotifications))
        .modifier(ESTKMemoryResetAlert(
            isPresented: $pendingMemoryReset,
            confirmation: $memoryResetConfirmation,
            expectedText: memoryResetExpectedText
        ))
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .profiles:
            VStack(spacing: 18) {
                statusMessage
                if store.state.estk.chipInfo != nil {
                    if let renamingProfile {
                        renameCard(profile: renamingProfile)
                    }
                    profilesCard
                } else {
                    chipUnavailableState
                }
            }
        case .download:
            VStack(spacing: 18) {
                statusMessage
                if !hasEUICC { chipUnavailableState }
                downloadCard
                    .disabled(!hasEUICC)
                    .opacity(hasEUICC ? 1 : 0.52)
                if hasEUICC {
                    discoveryCard
                }
            }
        case .euicc:
            VStack(spacing: 18) {
                statusMessage
                if let chipInfo = store.state.estk.chipInfo {
                    chipCard(chipInfo)
                    advancedInfoCard(chipInfo)
                } else {
                    chipUnavailableState
                }
            }
        case .notifications:
            VStack(spacing: 18) {
                statusMessage
                if store.state.estk.chipInfo != nil {
                    notificationsCard
                } else {
                    chipUnavailableState
                }
            }
        case .tools:
            VStack(spacing: 18) {
                statusMessage
                if !hasEUICC { chipUnavailableState }
                settingsCard
                    .disabled(!hasEUICC)
                    .opacity(hasEUICC ? 1 : 0.52)
                if store.state.estk.apduBackend != nil || !store.state.estk.operationLog.isEmpty {
                    diagnosticsCard(store.state.estk.apduBackend)
                }
                if let chipInfo = store.state.estk.chipInfo {
                    destructiveActionsCard(chipInfo)
                }
            }
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let error = store.state.estk.lastError {
            messageCard(error, systemImage: "exclamationmark.triangle", color: .red)
        } else if let warning = store.state.estk.warning {
            messageCard(warning, systemImage: "exclamationmark.circle", color: .orange)
        }
    }

    private var chipUnavailableState: some View {
        EmptyState(
            title: store.state.connected ? "estk.empty.title" : "estk.disconnected.title",
            subtitle: store.state.connected ? "estk.empty.description" : "estk.disconnected.description",
            systemImage: store.state.connected ? "simcard.2" : "simcard",
            actionTitleKey: store.state.connected ? "estk.refresh" : nil,
            action: store.state.connected ? { store.refreshESTK() } : nil
        )
        .frame(height: 220)
    }

    private var downloadCard: some View {
        MacSettingsContentCard {
            SettingsPickerRow(title: "estk.download.mode") {
                RightAlignedMenuPicker(
                    selection: $downloadMode,
                    options: [
                        .init(
                            title: localized("estk.download.mode.activation"),
                            value: ESTKDownloadMode.activationCode
                        ),
                        .init(
                            title: localized("estk.download.mode.manual"),
                            value: ESTKDownloadMode.manual
                        )
                    ]
                )
                .frame(width: 160)
            }

            if downloadMode == .activationCode {
                HStack(spacing: 8) {
                    SecureField(localized("estk.download.activation_code"), text: $activationCode)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .privacySensitive()
                        .help(localized("estk.download.activation_code.help"))
                    Button(localized("estk.download.paste")) {
                        pasteActivationCode()
                    }
                    .buttonStyle(.bordered)
                    Button {
                        importingActivationCode = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .help(localized("estk.download.qr_image"))
                }
                if let activationImportError {
                    Text(activationImportError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            } else {
                TextField(localized("estk.download.smdp"), text: $smdpAddress)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                SecureField(localized("estk.download.matching_id"), text: $matchingID)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
            }

            SecureField(localized("estk.download.confirmation_code"), text: $confirmationCode)
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .privacySensitive()
                .help(localized("estk.download.confirmation_code.help"))

            HStack {
                Text(localized("estk.download.privacy"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(localized("estk.download.action")) {
                    store.downloadESTKProfile(ESTKDownloadRequest(
                        activationCode: activationCode,
                        smdpAddress: smdpAddress,
                        matchingID: matchingID,
                        confirmationCode: confirmationCode
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.state.busy || !downloadReady)
            }
        }
        .fileImporter(isPresented: $importingActivationCode, allowedContentTypes: [.image]) { result in
            do {
                activationCode = try activationCodeFromImage(at: result.get())
                activationImportError = nil
            } catch {
                activationImportError = error.localizedDescription
            }
        }
    }

    private func renameCard(profile: ESTKProfile) -> some View {
        MacSettingsContentGroup("estk.profile.rename.title") {
            Text(localizedFormat("estk.profile.rename.target", profile.displayName))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(localized("estk.profile.rename.placeholder"), text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                Button(localized("estk.profile.rename.action")) {
                    store.renameESTKProfile(profile, nickname: nickname)
                    renamingProfile = nil
                    nickname = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.state.busy || trimmed(nickname).isEmpty)
                Button(localized("estk.action.cancel")) {
                    renamingProfile = nil
                    nickname = ""
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func chipCard(_ chipInfo: ESTKChipInfo) -> some View {
        MacSettingsContentGroup("estk.chip.title") {
            HStack(spacing: 8) {
                KeyValueRow(label: "estk.chip.eid", value: chipInfo.eidValue, labelWidth: 76)
                    .privacySensitive()
                Button {
                    copyToPasteboard(chipInfo.eidValue)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(localized("estk.chip.copy_eid"))
            }

            if let manufacturer = ESTKRegistry.manufacturer(forEID: chipInfo.eidValue) {
                KeyValueRow(
                    label: "estk.chip.manufacturer",
                    value: [manufacturer.manufacturer, manufacturer.country].filter { !$0.isEmpty }.joined(separator: " · "),
                    labelWidth: 76
                )
            }

            ParameterGrid(values: [
                ParameterValue(label: "estk.chip.firmware", value: chipInfo.extendedInfo?.euiccFirmwareVer ?? "-"),
                ParameterValue(label: "estk.chip.sgp_version", value: chipInfo.extendedInfo?.svn ?? "-"),
                ParameterValue(label: "estk.chip.profile_version", value: chipInfo.extendedInfo?.profileVersion ?? "-"),
                ParameterValue(label: "estk.chip.free_memory", value: formattedMemory(chipInfo.extendedInfo?.extCardResource?.freeNonVolatileMemory))
            ], showsCellBackground: false)

            if let defaultDP = firstPresent(chipInfo.configuredAddresses?.defaultDPAddress ?? "") {
                KeyValueRow(label: "estk.chip.default_smdp", value: defaultDP, labelWidth: 76)
            }
            if let rootDS = firstPresent(chipInfo.configuredAddresses?.rootDSAddress ?? "") {
                KeyValueRow(label: "estk.chip.root_smds", value: rootDS, labelWidth: 76)
            }

            HStack(spacing: 8) {
                TextField(localized("estk.chip.default_smdp.placeholder"), text: $defaultSMDPAddress)
                    .textFieldStyle(.roundedBorder)
                Button(localized("estk.chip.default_smdp.set")) {
                    store.setESTKDefaultSMDP(address: defaultSMDPAddress)
                }
                .buttonStyle(.bordered)
                .disabled(store.state.busy || trimmed(defaultSMDPAddress).isEmpty)
            }
        }
    }

    private var discoveryCard: some View {
        MacSettingsContentGroup("estk.discovery.title") {
            Text(localized("estk.discovery.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(localized("estk.discovery.smds"), text: $smdsAddress)
                    .textFieldStyle(.roundedBorder)
                Button(localized("estk.discovery.action")) {
                    store.discoverESTKProfiles(smdsAddress: smdsAddress)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.state.busy)
            }

            if store.state.estk.discoveryResults.isEmpty {
                Text(localized("estk.discovery.empty"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.state.estk.discoveryResults) { result in
                    HStack {
                        Text(result.address)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button(localized("estk.discovery.use")) {
                            smdpAddress = result.address
                            downloadMode = .manual
                            selectedCategory = .download
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var profilesCard: some View {
        MacSettingsContentCard {
            if store.state.estk.profiles.isEmpty {
                EmptyState(title: "estk.profiles.empty.title", subtitle: "estk.profiles.empty.description", systemImage: "simcard")
                    .frame(height: 110)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.state.estk.profiles.enumerated()), id: \.element.id) { index, profile in
                        ESTKProfileRow(profile: profile) {
                            store.setESTKProfileEnabled(profile, enabled: !profile.isEnabled)
                        } onRename: {
                            nickname = profile.profileNickname ?? profile.profileName
                            renamingProfile = profile
                        } onDelete: {
                            pendingProfileDeletion = profile
                        }
                        if index < store.state.estk.profiles.count - 1 {
                            Divider().opacity(0.45)
                        }
                    }
                }
            }
        }
    }

    private var notificationsCard: some View {
        MacSettingsContentGroup(
            localizedFormat("estk.notifications.title", store.state.estk.notifications.count)
        ) {
            if store.state.estk.notifications.isEmpty {
                Text(localized("estk.notifications.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Button(localized("estk.notifications.process_all")) {
                            store.processAllESTKNotifications()
                        }
                        .buttonStyle(.borderedProminent)
                        Button(localized("estk.notifications.remove_all"), role: .destructive) {
                            pendingDeleteAllNotifications = true
                        }
                        .buttonStyle(.bordered)
                        Menu(localized("estk.notifications.remove_by_type")) {
                            Button(localized("estk.notification.operation.install")) {
                                store.deleteESTKNotifications(operation: "install")
                            }
                            Button(localized("estk.notification.operation.enable")) {
                                store.deleteESTKNotifications(operation: "enable")
                            }
                            Button(localized("estk.notification.operation.disable")) {
                                store.deleteESTKNotifications(operation: "disable")
                            }
                            Button(localized("estk.notification.operation.delete")) {
                                store.deleteESTKNotifications(operation: "delete")
                            }
                        }
                        .menuStyle(.borderlessButton)
                        Spacer()
                    }
                    ForEach(store.state.estk.notifications) { notification in
                        ESTKNotificationRow(notification: notification) {
                            store.processESTKNotification(notification)
                        } onProcessOnly: {
                            store.processESTKNotification(notification, removeAfter: false)
                        } onDelete: {
                            pendingNotificationDeletion = notification
                        }
                    }
                }
            }
        }
    }

    private func advancedInfoCard(_ chipInfo: ESTKChipInfo) -> some View {
        MacSettingsContentGroup("estk.advanced_info.title") {
            let info = chipInfo.extendedInfo
            ParameterGrid(values: [
                ParameterValue(label: "estk.advanced_info.globalplatform", value: info?.globalplatformVersion ?? "-"),
                ParameterValue(label: "estk.advanced_info.ts102241", value: info?.ts102241Version ?? "-"),
                ParameterValue(label: "estk.advanced_info.pp", value: info?.ppVersion ?? "-"),
                ParameterValue(label: "estk.advanced_info.category", value: info?.euiccCategory ?? "-"),
                ParameterValue(label: "estk.advanced_info.sas", value: info?.sasAcreditationNumber ?? "-"),
                ParameterValue(label: "estk.advanced_info.platform", value: info?.certificationDataObject?.platformLabel ?? "-")
            ], showsCellBackground: false)

            detailedList(label: "estk.advanced_info.uicc_capabilities", values: info?.uiccCapability ?? [])
            detailedList(label: "estk.advanced_info.rsp_capabilities", values: info?.rspCapability ?? [])
            detailedList(label: "estk.advanced_info.policy_rules", values: info?.forbiddenProfilePolicyRules ?? [])

            if let discoveryURL = firstPresent(info?.certificationDataObject?.discoveryBaseURL ?? "") {
                KeyValueRow(label: "estk.advanced_info.discovery_url", value: discoveryURL, labelWidth: 112)
            }

            let keyIDs = Array(Set((info?.euiccCiPKIdListForSigning ?? []) + (info?.euiccCiPKIdListForVerification ?? []))).sorted()
            if !keyIDs.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(localized("estk.advanced_info.certificates"))
                        .font(.caption.weight(.semibold))
                    ForEach(keyIDs, id: \.self) { keyID in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ESTKRegistry.certificateIssuer(forKeyID: keyID)?.name ?? localized("estk.advanced_info.certificate_unknown"))
                                    .font(.caption)
                                Text(keyID)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            if let url = URL(string: "https://euicc-manual.osmocom.org/docs/pki/ci/files/\(String(keyID.prefix(6))).txt") {
                                Link(destination: url) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                }
                                .help(localized("estk.advanced_info.certificate_open"))
                            }
                        }
                    }
                }
            }

            HStack {
                Button(localized("estk.advanced_info.copy_json")) {
                    copyToPasteboard(store.state.estk.rawChipInfo)
                }
                .buttonStyle(.bordered)
                .disabled(store.state.estk.rawChipInfo.isEmpty)
                Text(localizedFormat("estk.advanced_info.rules_count", chipInfo.rulesAuthorisationTable?.count ?? 0))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var settingsCard: some View {
        VStack(spacing: 14) {
            MacSettingsGroup("estk.settings.group.transport") {
                MacSettingsRow(
                    title: "estk.settings.aid",
                    help: "estk.settings.aid.help"
                ) {
                    HStack(spacing: 8) {
                        TextField(localized("estk.settings.aid"), text: $isdRAID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minWidth: 120, idealWidth: 180, maxWidth: 220)
                        Menu {
                            Button(localized("estk.settings.aid.default")) { isdRAID = ESTKDefaults.isdRAID }
                            Button("5ber") { isdRAID = ESTKDefaults.fiveBerISDRAID }
                            Button("eSIM.me") { isdRAID = ESTKDefaults.esimMeISDRAID }
                            Button("Xesim") { isdRAID = ESTKDefaults.xesimISDRAID }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .help(localized("estk.settings.aid.presets"))
                    }
                }

                MacSettingsDivider()

                MacSettingsRow(
                    title: "estk.settings.segment_size",
                    help: "estk.settings.mss.help"
                ) {
                    CompactNumericStepper(value: $es10xMSS, range: 6...255)
                }

                MacSettingsDivider()

                MacSettingsRow(
                    title: "estk.settings.http_proxy",
                    help: "estk.settings.http_proxy.help"
                ) {
                    TextField(localized("estk.settings.http_proxy.placeholder"), text: $httpProxy)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 120, idealWidth: 180, maxWidth: 220)
                }

                MacSettingsDivider()

                MacSettingsToggleRow(
                    title: "estk.settings.ignore_tls",
                    help: "estk.settings.ignore_tls.help",
                    isOn: $ignoreTLSCertificate
                )
            }

            MacSettingsGroup("estk.settings.notifications.title") {
                MacSettingsToggleRow(
                    title: "estk.settings.notifications.download",
                    isOn: $notifyDownloads
                )
                MacSettingsDivider()
                MacSettingsToggleRow(
                    title: "estk.settings.notifications.delete",
                    isOn: $notifyDeletions
                )
                MacSettingsDivider()
                MacSettingsToggleRow(
                    title: "estk.settings.notifications.switch",
                    isOn: $notifySwitches
                )
            }

            MacSettingsGroup("estk.settings.group.actions") {
                MacSettingsRow(title: "estk.settings.version") {
                    Text(
                        store.state.estk.lpacVersion != "-"
                            ? localizedFormat("estk.settings.bundled_version", store.state.estk.lpacVersion)
                            : localized("estk.settings.install_hint")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                }

                MacSettingsDivider()

                MacSettingsRow(title: "estk.settings.save") {
                    HStack(spacing: 8) {
                        Button(localized("estk.settings.reset")) {
                            isdRAID = ESTKDefaults.isdRAID
                            es10xMSS = ESTKDefaults.es10xMSS
                            notifyDownloads = true
                            notifyDeletions = true
                            notifySwitches = false
                            httpProxy = ""
                            ignoreTLSCertificate = false
                        }
                        .buttonStyle(.bordered)

                        Button(localized("estk.settings.save")) {
                            store.saveESTKSettings(
                                isdRAID: isdRAID,
                                es10xMSS: es10xMSS,
                                notifyDownloads: notifyDownloads,
                                notifyDeletions: notifyDeletions,
                                notifySwitches: notifySwitches,
                                httpProxy: httpProxy,
                                ignoreTLSCertificate: ignoreTLSCertificate
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.state.busy)
                    }
                }
            }
        }
    }

    private func diagnosticsCard(_ backend: ESTKAPDUBackend?) -> some View {
        MacSettingsContentGroup("estk.diagnostics.title") {
            if let backend {
                ParameterGrid(
                    values: [
                        ParameterValue(label: "estk.diagnostics.backend", value: backend.rawValue),
                        ParameterValue(label: "estk.diagnostics.operation", value: store.state.estk.lastAPDUOperation),
                        ParameterValue(label: "estk.diagnostics.status_word", value: store.state.estk.lastAPDUStatusWord),
                        ParameterValue(label: "estk.diagnostics.response_bytes", value: String(store.state.estk.lastAPDUResponseBytes))
                    ],
                    columnCount: 2,
                    showsCellBackground: false
                )
            }

            if !store.state.estk.operationLog.isEmpty {
                if backend != nil {
                    Divider().opacity(0.45)
                }

                HStack {
                    Text(localized("estk.log.title"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("estk.log.copy")) {
                        let text = store.state.estk.operationLog.map {
                            "[\(AppDateTimeFormatter.shared.string(from: $0.date, role: .timeOnly))] \($0.message)"
                        }.joined(separator: "\n")
                        copyToPasteboard(text)
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.state.estk.operationLog.suffix(50)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: logIcon(entry.kind))
                                .foregroundStyle(logColor(entry.kind))
                            Text(AppDateTimeFormatter.shared.string(from: entry.date, role: .timeOnly))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .textSelection(.enabled)
                        }
                        .font(.caption2.monospaced())
                    }
                }
            }
        }
    }

    private func destructiveActionsCard(_ chipInfo: ESTKChipInfo) -> some View {
        MacSettingsContentGroup("estk.reset.section") {
            Text(localized("estk.reset.description"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(localized("estk.reset.open"), role: .destructive) {
                memoryResetConfirmation = ""
                pendingMemoryReset = true
            }
            .buttonStyle(.bordered)
            .disabled(store.state.busy || chipInfo.eidValue.count < 8)
        }
    }

    @ViewBuilder
    private func detailedList(label: String, values: [String]) -> some View {
        if !values.isEmpty {
            KeyValueRow(label: label, value: values.joined(separator: ", "), labelWidth: 112)
        }
    }

    private func messageCard(_ text: String, systemImage: String, color: Color) -> some View {
        MacSettingsContentGroup("estk.group.status") {
            Label(text, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

    private func loadSettingsIfNeeded() {
        guard !loadedSettings else { return }
        loadedSettings = true
        isdRAID = store.settings.estkISDRAID ?? ESTKDefaults.isdRAID
        es10xMSS = store.settings.estkES10xMSS ?? ESTKDefaults.es10xMSS
        notifyDownloads = store.settings.effectiveESTKNotifyDownloads
        notifyDeletions = store.settings.effectiveESTKNotifyDeletions
        notifySwitches = store.settings.effectiveESTKNotifySwitches
        httpProxy = store.settings.estkHTTPProxy ?? ""
        ignoreTLSCertificate = store.settings.estkIgnoreTLSCertificate ?? false
        loadChipDefaults()
    }

    private func loadChipDefaults() {
        guard let chipInfo = store.state.estk.chipInfo else { return }
        defaultSMDPAddress = chipInfo.configuredAddresses?.defaultDPAddress ?? ""
        if let rootDS = firstPresent(chipInfo.configuredAddresses?.rootDSAddress ?? "") {
            smdsAddress = rootDS
        }
    }

    private var downloadReady: Bool {
        switch downloadMode {
        case .activationCode:
            !trimmed(activationCode).isEmpty
        case .manual:
            !trimmed(smdpAddress).isEmpty && !trimmed(matchingID).isEmpty
        }
    }

    private var memoryResetExpectedText: String {
        String((store.state.estk.chipInfo?.eidValue ?? "").suffix(8))
    }

    private func pasteActivationCode() {
        if let value = NSPasteboard.general.string(forType: .string) {
            activationCode = trimmed(value)
            activationImportError = nil
        }
    }

    private func activationCodeFromImage(at url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ESTKError.qrCodeNotFound
        }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        guard let payload = request.results?.compactMap(\.payloadStringValue).first,
              !trimmed(payload).isEmpty else {
            throw ESTKError.qrCodeNotFound
        }
        return trimmed(payload)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func logIcon(_ kind: ESTKLogEntry.Kind) -> String {
        switch kind {
        case .progress: "arrow.right.circle"
        case .success: "checkmark.circle"
        case .failure: "xmark.circle"
        }
    }

    private func logColor(_ kind: ESTKLogEntry.Kind) -> Color {
        switch kind {
        case .progress: .secondary
        case .success: .green
        case .failure: .red
        }
    }

    private func formattedMemory(_ bytes: Int?) -> String {
        guard let bytes, bytes >= 0 else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

}

private struct ESTKProfileDeleteAlert: ViewModifier {
    @EnvironmentObject private var store: ModemStore
    @Binding var profile: ESTKProfile?

    func body(content: Content) -> some View {
        content.alert(
            localized("estk.profile.delete.title"),
            isPresented: Binding(
                get: { profile != nil },
                set: { if !$0 { profile = nil } }
            ),
            presenting: profile
        ) { value in
            Button(localized("action.delete"), role: .destructive) {
                store.deleteESTKProfile(value)
                profile = nil
            }
            Button(localized("estk.action.cancel"), role: .cancel) { profile = nil }
        } message: { value in
            Text(localizedFormat("estk.profile.delete.message", value.displayName))
        }
    }
}

private struct ESTKNotificationDeleteAlert: ViewModifier {
    @EnvironmentObject private var store: ModemStore
    @Binding var notification: ESTKNotification?

    func body(content: Content) -> some View {
        content.alert(
            localized("estk.notification.delete.title"),
            isPresented: Binding(
                get: { notification != nil },
                set: { if !$0 { notification = nil } }
            ),
            presenting: notification
        ) { value in
            Button(localized("action.delete"), role: .destructive) {
                store.deleteESTKNotification(value)
                notification = nil
            }
            Button(localized("estk.action.cancel"), role: .cancel) { notification = nil }
        } message: { value in
            Text(localizedFormat("estk.notification.delete.message", value.seqNumber))
        }
    }
}

private struct ESTKRemoveAllNotificationsAlert: ViewModifier {
    @EnvironmentObject private var store: ModemStore
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert(localized("estk.notifications.remove_all.title"), isPresented: $isPresented) {
            Button(localized("action.delete"), role: .destructive) {
                store.deleteAllESTKNotifications()
            }
            Button(localized("estk.action.cancel"), role: .cancel) {}
        } message: {
            Text(localizedFormat("estk.notifications.remove_all.message", store.state.estk.notifications.count))
        }
    }
}

private struct ESTKMemoryResetAlert: ViewModifier {
    @EnvironmentObject private var store: ModemStore
    @Binding var isPresented: Bool
    @Binding var confirmation: String
    var expectedText: String

    func body(content: Content) -> some View {
        content.alert(localized("estk.reset.title"), isPresented: $isPresented) {
            TextField(expectedText, text: $confirmation)
            Button(localized("estk.reset.action"), role: .destructive) {
                store.purgeESTKMemory()
                confirmation = ""
            }
            .disabled(confirmation != expectedText)
            Button(localized("estk.action.cancel"), role: .cancel) { confirmation = "" }
        } message: {
            Text(localizedFormat("estk.reset.message", expectedText))
        }
    }
}

private struct ESTKProfileRow: View {
    @EnvironmentObject private var store: ModemStore
    var profile: ESTKProfile
    var onToggle: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void
    @State private var editingMetadata = false

    private var metadata: ProfileMetadata? {
        store.state.estk.profileMetadata[profile.iccid]
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let image = profileIcon {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "simcard")
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                Image(systemName: profile.isEnabled ? "checkmark.circle.fill" : "circle.fill")
                    .foregroundStyle(profile.isEnabled ? Color.accentColor : Color.secondary)
                    .background(.background, in: Circle())
                    .font(.caption2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .help(localizedFormat("common.full_value_help", profile.displayName))
                HStack(spacing: 6) {
                    Text(localized(profile.stateLocalizationKey))
                        .foregroundStyle(profile.isEnabled ? Color.accentColor : Color.secondary)
                    if let provider = firstPresent(profile.serviceProviderName) {
                        Text(provider)
                            .help(localizedFormat("common.full_value_help", provider))
                    }
                    if let profileClass = firstPresent(profile.profileClass) {
                        Text(localizedFormat("estk.profile.class", profileClass))
                    }
                }
                .font(.caption2)
                .lineLimit(1)
                HStack(spacing: 6) {
                    Text(profile.iccid)
                        .font(.caption2.monospaced())
                        .privacySensitive()
                        .textSelection(.enabled)
                        .help(localizedFormat("common.full_value_help", profile.iccid))
                    if let metadata, !metadata.isEmpty {
                        Text(metadataSummary(metadata))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(localizedFormat("common.full_value_help", metadataSummary(metadata)))
                    }
                }
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 6)

            Menu {
                Button(localized(profile.isEnabled ? "estk.profile.disable" : "estk.profile.enable"), action: onToggle)
                    .disabled(crossClassSwitchBlocked)
                Button(localized("estk.profile.rename"), action: onRename)
                Button(localized("estk.profile.metadata"), action: { editingMetadata = true })
                Divider()
                Button(localized("action.delete"), role: .destructive, action: onDelete)
                    .disabled(profile.isEnabled)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .disabled(store.state.busy)
            .help(localized("estk.profile.actions"))
        }
        .padding(.vertical, 7)
        .sheet(isPresented: $editingMetadata) {
            ESTKProfileMetadataSheet(
                profile: profile,
                eid: trimmed(store.state.estk.chipInfo?.eidValue),
                existing: metadata
            ) { record in
                store.saveProfileMetadata(record)
            } onDelete: { eid, iccid in
                store.removeProfileMetadata(eid: eid, iccid: iccid)
            }
        }
    }

    private func metadataSummary(_ metadata: ProfileMetadata) -> String {
        var parts: [String] = []
        if !trimmed(metadata.label).isEmpty { parts.append(trimmed(metadata.label)) }
        if !trimmed(metadata.phone).isEmpty { parts.append(trimmed(metadata.phone)) }
        parts.append(contentsOf: metadata.normalizedTags)
        return parts.joined(separator: " · ")
    }

    private var profileIcon: NSImage? {
        guard let encoded = profile.icon,
              let data = Data(base64Encoded: encoded) else { return nil }
        return NSImage(data: data)
    }

    private var crossClassSwitchBlocked: Bool {
        guard !profile.isEnabled,
              let targetClass = firstPresent(profile.profileClass),
              let enabledClass = store.state.estk.profiles.first(where: \.isEnabled).flatMap({ firstPresent($0.profileClass) }) else {
            return false
        }
        return targetClass.caseInsensitiveCompare(enabledClass) != .orderedSame
    }
}

/// Mac-local profile details editor (P7-A): label, phone, and tags kept
/// beside the eSTK list — never written to the card.
private struct ESTKProfileMetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    var profile: ESTKProfile
    var eid: String
    var existing: ProfileMetadata?
    var onSave: (ProfileMetadata) -> Void
    var onDelete: (_ eid: String, _ iccid: String) -> Void

    @State private var label = ""
    @State private var phone = ""
    @State private var tags = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField(localized("estk.metadata.label_field"), text: $label)
                TextField(localized("estk.metadata.phone_field"), text: $phone)
                TextField(localized("estk.metadata.tags_field"), text: $tags)
                Text(localized("estk.metadata.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            HStack {
                if existing != nil {
                    Button(localized("estk.metadata.delete"), role: .destructive) {
                        onDelete(eid, profile.iccid)
                        dismiss()
                    }
                }
                Spacer()
                Button(localized("common.cancel")) { dismiss() }
                Button(localized("estk.metadata.save")) {
                    onSave(ProfileMetadata(
                        eid: eid,
                        iccid: profile.iccid,
                        label: label,
                        phone: phone,
                        tags: tags.split(separator: ",").map(String.init),
                        updatedAt: Date()
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 320, minHeight: 220)
        .onAppear {
            label = existing?.label ?? ""
            phone = existing?.phone ?? ""
            tags = existing?.tags.joined(separator: ", ") ?? ""
        }
    }
}

private struct ESTKNotificationRow: View {
    @EnvironmentObject private var store: ModemStore
    var notification: ESTKNotification
    var onProcess: () -> Void
    var onProcessOnly: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "bell")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(notification.operationLocalizationKey))
                    .font(.caption.weight(.semibold))
                Text(localizedFormat("estk.notification.sequence", notification.seqNumber, notification.notificationAddress))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(localizedFormat(
                        "common.full_value_help",
                        localizedFormat("estk.notification.sequence", notification.seqNumber, notification.notificationAddress)
                    ))
            }
            Spacer(minLength: 6)
            Menu {
                Button(localized("estk.notification.process_only"), action: onProcessOnly)
                Button(localized("estk.notification.process"), action: onProcess)
            } label: {
                Image(systemName: "paperplane")
            }
            .menuStyle(.borderlessButton)
            .help(localized("estk.notification.process"))
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(localized("estk.notification.remove"))
        }
        .disabled(store.state.busy)
    }
}
