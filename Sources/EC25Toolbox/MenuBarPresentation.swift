import AppKit
import Combine
import SwiftUI
import UserNotifications

/// Owns the status item, pinnable popover, standalone native window, and app menus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let coordinator = ModemSessionCoordinator()
    private var store: ModemStore { coordinator.selectedStore }
    private let contactStore = ContactStore()
    private let presentation = WindowPresentationModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var appWindow: NSWindow?
    private lazy var callPanelController = CallNotificationPanelController(coordinator: coordinator)
    private var statusContextMenu: NSMenu?
    private var coordinatorObservation: AnyCancellable?
    private var settingsObservation: AnyCancellable?
    private var appearanceObservation: AnyCancellable?
    private var dateTimePreferencesObservation: AnyCancellable?
    private var dateTimeLanguageObservation: AnyCancellable?
    private var callNotificationDelegate: CallNotificationDelegate?
    private var terminationCleanupStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        configureCallNotifications()
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        applyAppAppearance(store.settings.effectiveAppearance)
        configurePopover()
        applyPopoverAppearance()
        presentation.onPopoverPinnedChange = { [weak self] pinned in
            self?.applyPopoverPinnedState(pinned)
        }
        presentation.onOpenStandaloneWindow = { [weak self] in
            self?.openStandaloneWindow()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverDidShow(_:)),
            name: NSPopover.didShowNotification,
            object: popover
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverDidClose(_:)),
            name: NSPopover.didCloseNotification,
            object: popover
        )
        coordinator.aggregateStateDidChange = { [weak self] in
            guard let self else { return }
            self.updateStatusItem()
            self.presentation.recomputeCallSurfaceVisible(
                hasIncomingCall: self.coordinator.hasIncomingCall
            )
            self.synchronizeCallPanel()
        }
        coordinatorObservation = coordinator.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateStatusItem()
                self.presentation.recomputeCallSurfaceVisible(
                    hasIncomingCall: self.coordinator.hasIncomingCall
                )
                self.synchronizeCallPanel()
            }
        }
        settingsObservation = coordinator.$sharedSettings
            .map(\.preferredLanguage)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.configureMainMenu()
                // `.id(preferredLanguage)` recreates the hosted SwiftUI
                // subtree so every native control re-renders localized
                // titles in one transaction.
                // The standalone window's native TabView labels and page
                // navigation titles re-render with the recreated SwiftUI
                // subtree on language change.
                self.updateStatusItem()
                // Category action titles are captured at registration;
                // re-register so notification buttons follow the new language.
                CallNotification.registerCategory()
            }
        appearanceObservation = coordinator.$sharedSettings
            .map(\.effectiveAppearance)
            .removeDuplicates()
            .sink { [weak self] appearance in
                applyAppAppearance(appearance)
                self?.applyPopoverAppearance()
            }
        // User-visible date-time rendering (R0) follows the same settings
        // pipeline; subscriptions deliver the current value immediately, so
        // the shared formatter is configured before any view renders.
        dateTimePreferencesObservation = coordinator.$sharedSettings
            .map(\.effectiveDateTimeDisplay)
            .removeDuplicates()
            .sink { AppDateTimeFormatter.shared.apply(preferences: $0) }
        dateTimeLanguageObservation = coordinator.$sharedSettings
            .map(\.preferredLanguage)
            .removeDuplicates()
            .sink { AppDateTimeFormatter.shared.apply(languageIdentifier: $0 ?? "") }
        updateStatusItem()
        // Request notification authorization before any call can ring; a
        // first-run prompt at launch replaces the old mid-ring request (R2).
        Task { @MainActor [weak self] in
            await self?.store.requestCallNotificationAuthorizationIfNeeded()
        }
        coordinator.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationCleanupStarted else { return .terminateNow }
        terminationCleanupStarted = true
        callPanelController.dismiss()
        Task { @MainActor [weak sender, weak self] in
            guard let self else {
                sender?.reply(toApplicationShouldTerminate: true)
                return
            }
            await coordinator.shutdownForApplicationTermination()
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === appWindow else { return }
        presentation.setStandaloneWindowVisible(false, hasIncomingCall: coordinator.hasIncomingCall)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === appWindow else { return }
        presentation.setStandaloneWindowVisible(true, hasIncomingCall: coordinator.hasIncomingCall)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === appWindow else { return }
        presentation.setStandaloneWindowVisible(
            appWindow?.isVisible == true && appWindow?.isMiniaturized == false,
            hasIncomingCall: coordinator.hasIncomingCall
        )
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === appWindow else { return }
        presentation.setStandaloneWindowVisible(false, hasIncomingCall: coordinator.hasIncomingCall)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === appWindow else { return }
        presentation.setStandaloneWindowVisible(true, hasIncomingCall: coordinator.hasIncomingCall)
    }

    @objc private func popoverDidShow(_ notification: Notification) {
        PresentationSignpost.popoverDidShow()
        presentation.setPopoverShown(true, hasIncomingCall: coordinator.hasIncomingCall)
    }

    @objc private func popoverDidClose(_ notification: Notification) {
        presentation.setPopoverShown(false, hasIncomingCall: coordinator.hasIncomingCall)
    }

    private func configureStatusItem() {
        // Let AppKit persist the position selected by Command-dragging the
        // menu-bar item. Without a stable autosave name, every fresh launch
        // places the item at the right edge and the anchored popover follows it.
        statusItem.autosaveName = "ing.fuyaoskyrocket.ec25toolbox.status-item"
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        // Fixed logical canvas (R17); `preparePopoverForPresentation` applies
        // the single pre-show screen clamp before every show.
        popover.contentSize = NSSize(
            width: PanelPresentationSpec.popoverWidth,
            height: PanelPresentationSpec.popoverHeight
        )
        popover.contentViewController = makeHostingController(surface: .popover)
        popover.contentViewController?.preferredContentSize = popover.contentSize
    }

    /// Match CodexBar's menu presentation: pin the exact effective appearance
    /// (including accessibility contrast attributes), rather than recreating
    /// it from a light/dark name and losing those system adjustments.
    private func applyPopoverAppearance() {
        let effectiveAppearance = NSApplication.shared.effectiveAppearance
        popover.appearance = effectiveAppearance
        popover.contentViewController?.view.appearance = effectiveAppearance
    }

    /// Reasserts the fixed popover canvas — `min(640×700, visibleFrame - 24)`
    /// per dimension — while the popover is still hidden, so `show` presents
    /// one stable frame (R17). This is the only sizing step on the open
    /// path; it stays free of AT, disk, Contacts, and NIC work.
    private func preparePopoverForPresentation() {
        let interval = PresentationSignpost.prepareBegin()
        presentation.beginPopoverPresentation()
        // A closed NSPopover reuses its AppKit window. SwiftUI safe-area and
        // scroll containers can retain the geometry of the tab that was last
        // visible even after frame/bounds are reset. Install a fresh hosting
        // tree for every presentation while preserving all durable selection
        // and modem state in the shared models.
        PopoverCanvasSync.install(
            makeHostingController(surface: .popover),
            size: PanelPresentationSpec.clampedSize(visibleFrame: anchorScreenVisibleFrame()),
            on: popover
        )
        applyPopoverAppearance()
        applyPopoverSize()
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        PresentationSignpost.prepareEnd(interval)
    }

    private func anchorScreenVisibleFrame() -> CGRect? {
        statusItem.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
    }

    /// Reasserts the fixed popover canvas with the pre-show screen clamp.
    private func applyPopoverSize() {
        applyPopoverSize(visibleFrame: anchorScreenVisibleFrame())
    }

    func applyPopoverSize(visibleFrame: CGRect?) {
        PopoverCanvasSync.apply(
            PanelPresentationSpec.clampedSize(visibleFrame: visibleFrame),
            to: popover
        )
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        // The popover's size is fixed (R17). A screen-parameter change may
        // only shrink a currently shown popover back into the new visible
        // frame, once and without animation; it never grows the frame.
        guard popover.isShown else { return }
        let visibleFrame = anchorScreenVisibleFrame()
        let clamped = PanelPresentationSpec.clampedSize(visibleFrame: visibleFrame)
        guard clamped.width < popover.contentSize.width
            || clamped.height < popover.contentSize.height else { return }
        let restoresAnimation = popover.animates
        popover.animates = false
        applyPopoverSize(visibleFrame: visibleFrame)
        popover.animates = restoresAnimation
    }

    func makeHostingController(surface: PresentationSurface) -> NSViewController {
        PresentationHostingFactory.makeController(
            surface: surface,
            coordinator: coordinator,
            contactStore: contactStore,
            presentation: presentation
        )
    }

    private func makeAppWindow() -> NSWindow {
        // Native system-settings chrome (full-size content + unified
        // titlebar) lives in WindowChromeConfigurator; the AppDelegate only
        // stays the window delegate (R15).
        let window = WindowChromeConfigurator.makeWindow(
            contentViewController: makeHostingController(surface: .standaloneWindow),
            anchorVisibleFrame: statusItem.button?.window?.screen?.visibleFrame
        )
        window.delegate = self
        return window
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        PresentationSignpost.statusItemClick()
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    @objc private func openFromMenu(_ sender: Any?) {
        // Let AppKit finish dismissing the status-item menu before presenting
        // another transient window from the same menu-bar anchor.
        DispatchQueue.main.async { [weak self] in
            self?.showPopover()
        }
    }

    @objc private func terminateApplication(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func selectPanelTab(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let tab = PanelTab(rawValue: rawValue) else { return }
        // Every main tab is always selectable (R10); capability and
        // connection limits are explained inside the target page.
        presentation.popoverSelectedTab = tab
    }

    @objc private func openSettingsAction(_ sender: Any?) {
        // ⌘, routes to the standalone window's Settings page: selecting the
        // tab first, then showing the window, lands on the single-page form
        // without a back stack (R19).
        presentation.windowSelectedTab = .settings
        openStandaloneWindow()
    }

    @objc private func answerCallAction(_ sender: Any?) {
        callActionStore.answer()
    }

    @objc private func declineCallAction(_ sender: Any?) {
        callActionStore.reject()
    }

    @objc private func hangUpCallAction(_ sender: Any?) {
        callActionStore.hangUp()
    }

    private var callActionStore: ModemStore {
        coordinator.focusedLiveSession?.store ?? store
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(answerCallAction(_:)), #selector(declineCallAction(_:)):
            return callActionStore.state.call.phase == .incoming
        case #selector(hangUpCallAction(_:)):
            switch callActionStore.state.call.phase {
            case .dialing, .alerting, .answering, .active, .held, .ending:
                return callActionStore.state.connected
            default:
                return false
            }
        default:
            break
        }
        guard menuItem.action == #selector(selectPanelTab(_:)),
              let rawValue = menuItem.representedObject as? String,
              let tab = PanelTab(rawValue: rawValue) else { return true }
        menuItem.state = presentation.popoverSelectedTab == tab ? .on : .off
        // Navigation entries stay enabled regardless of capability or
        // connection state (R10); pages explain their own unavailability.
        return true
    }

    /// Registers the incoming-call notification category and routes banner
    /// actions back into the store and the popover.
    private func configureCallNotifications() {
        CallNotification.registerCategory()
        let delegate = CallNotificationDelegate()
        // Banner suppression is decided per presentation, not per app
        // activation: only an actually visible call surface swallows the
        // banner (R2 visibility coordinator).
        delegate.isCallSurfaceVisible = { [weak self] deviceID in
            guard let self else { return false }
            // The floating call panel is itself the native operable
            // notification surface. Do not stack a second system banner over
            // it for the same focused module.
            if self.callPanelController.isPresenting(deviceID: deviceID) {
                return true
            }
            // The standalone sidebar lists every live module. The compact
            // popover can operate only its focused call, so another module's
            // simultaneous call must still receive a banner.
            if self.presentation.isStandaloneWindowVisible {
                return self.coordinator.liveSessions.contains { $0.id == deviceID }
            }
            if self.presentation.isPopoverVisible {
                return self.coordinator.focusedLiveSession?.id == deviceID
            }
            return false
        }
        // Recheck the phase at execution time so a stale banner action cannot
        // answer or reject a call that already rolled over.
        delegate.onAnswerDevice = { [weak self] deviceID in
            guard let self,
                  let target = self.coordinator.store(for: deviceID),
                  target.state.call.phase == .incoming else { return }
            target.answer()
        }
        delegate.onDeclineDevice = { [weak self] deviceID in
            guard let self, let target = self.coordinator.store(for: deviceID) else { return }
            switch target.state.call.phase {
            case .incoming:
                target.reject()
            case .answering:
                target.hangUp()
            default:
                break
            }
        }
        delegate.onOpenDevice = { [weak self] deviceID in
            guard let self else { return }
            self.coordinator.selectDevice(deviceID)
            if self.appWindow?.isVisible == true {
                self.presentation.windowSelectedTab = .phone
                self.appWindow?.makeKeyAndOrderFront(nil)
            } else {
                self.presentation.popoverSelectedTab = .phone
                self.showPopover()
            }
        }
        delegate.onOpenSMSDevice = { [weak self] deviceID in
            guard let self else { return }
            self.coordinator.selectDevice(deviceID)
            self.presentation.popoverSelectedTab = .sms
            self.showPopover()
        }
        UNUserNotificationCenter.current().delegate = delegate
        callNotificationDelegate = delegate
        coordinator.configurePresentationServices(
            smsContactNameResolver: { [weak contactStore] number in
                contactStore?.displayName(forNumber: number)
            },
            callContactNameResolver: { [weak contactStore] number in
                contactStore?.displayName(forNumber: number)
            },
            callContactSnapshotReload: { [weak contactStore] in
                await contactStore?.reload()
            },
            isSMSSurfaceVisible: { [weak self] deviceID in
                guard let self else { return false }
                return self.presentation.isSMSSurfaceVisible
                    && self.coordinator.selectedDeviceID == deviceID
            }
        )
    }

    private func showContextMenu() {
        // A translucent NSMenu samples whatever is behind it. Close the main
        // popover synchronously so its tab labels cannot bleed through the
        // menu material or compete for the same status-item anchor.
        if popover.isShown {
            let restoresAnimation = popover.animates
            popover.animates = false
            popover.close()
            popover.animates = restoresAnimation
        }

        let menu = NSMenu()
        menu.delegate = self
        let openItem = NSMenuItem(
            title: localized("action.open_window"),
            action: #selector(openFromMenu(_:)),
            keyEquivalent: ""
        )
        openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        openItem.image?.isTemplate = true
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: localized("action.quit"),
            action: #selector(terminateApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quitItem.image?.isTemplate = true
        quitItem.target = self
        menu.addItem(quitItem)

        // Assign the menu only for this right-click presentation. NSStatusItem
        // then owns native positioning, safe-area clamping, and menu chrome.
        statusContextMenu = menu
        statusItem.menu = menu
        DispatchQueue.main.async { [weak self, weak menu] in
            guard let self,
                  let menu,
                  self.statusContextMenu === menu,
                  let button = self.statusItem.button else { return }
            button.performClick(nil)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusContextMenu else { return }
        statusItem.menu = nil
        statusContextMenu = nil
    }

    private func applyPopoverPinnedState(_ pinned: Bool) {
        popover.behavior = pinned ? .applicationDefined : .transient
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // Apply the fixed size (with the one pre-show screen clamp) and lay
        // the content out while still hidden so `show` presents one stable
        // frame (R13). This path stays free of AT, disk, Contacts, and NIC
        // work — those run on the store's async pipelines, never on the
        // status-item click path.
        preparePopoverForPresentation()
        if appWindow?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func openStandaloneWindow() {
        popover.performClose(nil)
        if appWindow == nil {
            appWindow = makeAppWindow()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        appWindow?.makeKeyAndOrderFront(nil)
    }

    private func synchronizeCallPanel() {
        callPanelController.synchronize(
            on: appWindow?.screen ?? statusItem.button?.window?.screen ?? NSScreen.main
        )
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu(title: localized("app.name"))

        let appMenu = NSMenu(title: localized("app.name"))
        appMenu.addItem(menuItem("menu.about", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        // Standard ⌘, entry: opens the standalone window directly on the
        // Settings page; sidebar search and the native top category tabs share
        // the same category routes.
        let settingsItem = menuItem("menu.settings", action: #selector(openSettingsAction(_:)), key: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let servicesItem = menuItem("menu.services", action: nil)
        let servicesMenu = NSMenu(title: localized("menu.services"))
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("menu.hide", action: #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = menuItem("menu.hide_others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(menuItem("menu.show_all", action: #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        let quit = menuItem("action.quit", action: #selector(terminateApplication(_:)), key: "q")
        quit.target = self
        appMenu.addItem(quit)
        mainMenu.addItem(rootMenuItem(title: localized("app.name"), submenu: appMenu))

        let fileMenu = NSMenu(title: localized("menu.file"))
        fileMenu.addItem(menuItem("menu.close", action: #selector(NSWindow.performClose(_:)), key: "w"))
        mainMenu.addItem(rootMenuItem(title: localized("menu.file"), submenu: fileMenu))

        let editMenu = NSMenu(title: localized("menu.edit"))
        editMenu.addItem(menuItem("menu.undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(menuItem("menu.redo", action: Selector(("redo:")), key: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("menu.cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(menuItem("menu.copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(menuItem("menu.paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(menuItem("menu.select_all", action: #selector(NSText.selectAll(_:)), key: "a"))
        mainMenu.addItem(rootMenuItem(title: localized("menu.edit"), submenu: editMenu))

        let viewMenu = NSMenu(title: localized("menu.view"))
        for (index, tab) in PanelTab.allCases.enumerated() {
            let item = NSMenuItem(
                title: tab.title,
                action: #selector(selectPanelTab(_:)),
                keyEquivalent: String(index + 1)
            )
            item.target = self
            item.representedObject = tab.rawValue
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        let fullScreen = menuItem("menu.full_screen", action: #selector(NSWindow.toggleFullScreen(_:)), key: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)
        mainMenu.addItem(rootMenuItem(title: localized("menu.view"), submenu: viewMenu))

        let callMenu = NSMenu(title: localized("menu.call"))
        let answer = menuItem("menu.call.answer", action: #selector(answerCallAction(_:)), key: "a")
        answer.keyEquivalentModifierMask = [.command, .shift]
        answer.target = self
        callMenu.addItem(answer)
        let decline = menuItem("menu.call.decline", action: #selector(declineCallAction(_:)), key: "d")
        decline.keyEquivalentModifierMask = [.command, .shift]
        decline.target = self
        callMenu.addItem(decline)
        callMenu.addItem(.separator())
        let hangUp = menuItem("menu.call.hang_up", action: #selector(hangUpCallAction(_:)), key: "h")
        hangUp.keyEquivalentModifierMask = [.command, .shift]
        hangUp.target = self
        callMenu.addItem(hangUp)
        mainMenu.addItem(rootMenuItem(title: localized("menu.call"), submenu: callMenu))

        let windowMenu = NSMenu(title: localized("menu.window"))
        windowMenu.addItem(menuItem("menu.minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(menuItem("menu.zoom", action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(menuItem("menu.bring_all_to_front", action: #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = windowMenu
        mainMenu.addItem(rootMenuItem(title: localized("menu.window"), submenu: windowMenu))

        let helpMenu = NSMenu(title: localized("menu.help"))
        mainMenu.addItem(rootMenuItem(title: localized("menu.help"), submenu: helpMenu))
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = mainMenu
    }

    private func rootMenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func menuItem(_ titleKey: String, action: Selector?, key: String = "") -> NSMenuItem {
        NSMenuItem(title: localized(titleKey), action: action, keyEquivalent: key)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let statusStore = store.state.connected
            ? store
            : (coordinator.sessions.first(where: { $0.store.state.connected })?.store ?? store)
        let state = statusStore.state
        let image: NSImage?
        if state.connected {
            let level = Double(min(max(state.info.signal.bars, 0), 4)) / 4.0
            image = NSImage(
                systemSymbolName: "cellularbars",
                variableValue: level,
                accessibilityDescription: statusStore.menuBarAccessibilityLabel
            )
        } else {
            image = NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right.slash",
                accessibilityDescription: statusStore.menuBarAccessibilityLabel
            )
        }
        image?.isTemplate = true
        button.image = image
        var indicators: [MenuBarEventIndicator] = []
        if coordinator.aggregateUnreadCount > 0 {
            indicators.append(.unreadMessages(coordinator.aggregateUnreadCount))
        }
        if coordinator.aggregateMissedCallCount > 0 {
            indicators.append(.missedCalls(coordinator.aggregateMissedCallCount))
        }
        if coordinator.hasIncomingCall {
            indicators.append(.incomingCall)
        }
        button.attributedTitle = StatusItemPresentation.attributedTitle(for: indicators)
        button.imagePosition = indicators.isEmpty ? .imageOnly : .imageLeading
        var toolTip = statusStore.menuBarAccessibilityLabel
        if coordinator.connectedCount > 1 {
            toolTip += " · " + localizedFormat("menubar.connected_modules", coordinator.connectedCount)
        }
        if coordinator.aggregateUnreadCount > 0 {
            toolTip += " · " + localizedFormat("menubar.unread_sms", coordinator.aggregateUnreadCount)
        }
        let missed = coordinator.aggregateMissedCallCount
        if missed > 0 {
            toolTip += " · " + localizedFormat("menubar.missed_calls", missed)
        }
        if coordinator.hasIncomingCall {
            toolTip += " · " + localized("menubar.incoming_call")
        }
        if state.gnss.phase != .off {
            toolTip = localizedFormat(
                "gnss.menubar.tooltip",
                toolTip,
                localized(state.gnss.phase.localizationKey)
            )
        }
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
    }
}
