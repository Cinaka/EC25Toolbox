import AppKit
import XCTest
@testable import EC25Toolbox

/// Window-shell rules: sidebar search coverage, entry identity, and the
/// device summary card's offline persistence.
@MainActor
final class WindowNavigationTests: XCTestCase {
    func testSidebarUsesAcceptedFixedColumnWidth() {
        XCTAssertEqual(AppSidebar.fixedColumnWidth, 216)
    }

    // MARK: - Search index structure

    func testSearchIndexCoversEveryMainTab() {
        for tab in PanelTab.allCases {
            XCTAssertTrue(
                SidebarSearchIndex.entries.contains { $0.tab == tab && $0.categoryRawValue == nil },
                "missing main-tab entry for \(tab)"
            )
        }
    }

    func testSearchEntryIDsAreUniqueAcrossPages() {
        let ids = SidebarSearchIndex.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testSubPageRoutesResolve() {
        let datetime = SidebarSearchIndex.entries.first { $0.id == "settings/datetime" }
        XCTAssertEqual(datetime?.route, SidebarCategoryRoute(tab: .settings, category: "datetime"))

        // Main tabs carry no category route.
        let sms = SidebarSearchIndex.entries.first { $0.id == "sms" }
        XCTAssertNil(sms?.route)
    }

    // MARK: - Search filtering (spec §3.1 minimum coverage)

    /// Resolver that stands in for `localized(_:)` so filtering stays
    /// deterministic regardless of bundle loading in xctest.
    private var resolver: (String) -> String {
        let table = [
            "nav.sms": "短信",
            "nav.gnss": "定位",
            "settings.category.datetime": "日期与时间",
            "settings.category.general": "通用",
            "settings.category.calls": "电话与音频",
            "settings.category.messages": "短信与通知",
            "settings.category.module": "模块配置",
            "settings.search.keyword.notifications": "通知 通知设置",
            "settings.search.keyword.audio": "音频 通话音频",
        ]
        return { table[$0] ?? $0 }
    }

    func testSearchLocatesSpecRequiredPages() {
        // 短信 → main SMS tab.
        XCTAssertEqual(SidebarSearchIndex.filter(query: "短信", resolver: resolver).first?.tab, .sms)
        // 日期与时间 → Settings sub-page.
        XCTAssertTrue(SidebarSearchIndex.filter(query: "日期", resolver: resolver).contains {
            $0.route == SidebarCategoryRoute(tab: .settings, category: "datetime")
        })
        // 通知 → lives inside the reorganized Messages settings (keyword).
        XCTAssertTrue(SidebarSearchIndex.filter(query: "通知", resolver: resolver).contains {
            $0.route == SidebarCategoryRoute(tab: .settings, category: "messages")
        })
        // 音频 → call-audio settings inside the reorganized Calls page.
        XCTAssertTrue(SidebarSearchIndex.filter(query: "音频", resolver: resolver).contains {
            $0.route == SidebarCategoryRoute(tab: .settings, category: "calls")
        })
        // 模块配置 → its own Settings category, separate from SIM security.
        XCTAssertTrue(SidebarSearchIndex.filter(query: "模块", resolver: resolver).contains {
            $0.route == SidebarCategoryRoute(tab: .settings, category: "module")
        })
        // GNSS/定位 → main GNSS tab.
        XCTAssertEqual(SidebarSearchIndex.filter(query: "定位", resolver: resolver).first?.tab, .gnss)
    }

    func testSearchIsCaseAndSpacingInsensitive() {
        XCTAssertEqual(SidebarSearchIndex.filter(query: "  sms ", resolver: { $0 }).first?.tab, .sms)
        XCTAssertTrue(SidebarSearchIndex.filter(query: "SMS", resolver: { $0 }).contains { $0.tab == .sms && $0.categoryRawValue == nil })
    }

    func testEmptyQueryMatchesEverythingUnknownQueryMatchesNothing() {
        XCTAssertEqual(SidebarSearchIndex.filter(query: "", resolver: resolver).count, SidebarSearchIndex.entries.count)
        XCTAssertEqual(SidebarSearchIndex.filter(query: "zzz-no-match", resolver: resolver).count, 0)
    }

    // MARK: - Device summary card

    func testDeviceSummaryKeepsRememberedIdentityWhileOffline() {
        var state = ModemState()
        state.connected = true
        state.usbDescription = "USB 2c7c:0125 if2 out=0x03 in=0x84"

        let connected = DeviceSummaryDisplay.make(
            state: state,
            statusTextKey: "status.online",
            rememberedDetail: nil
        )
        XCTAssertEqual(connected.usbIdentity, "USB 2c7c:0125 · if2")
        XCTAssertEqual(connected.endpoints, "out=0x03 · in=0x84")
        XCTAssertEqual(connected.statusKey, "status.online")
        XCTAssertTrue(connected.isOnline)
        XCTAssertEqual(connected.modeKey, "remote.mode.direct")

        // The store resets usbDescription on disconnect; the card keeps the
        // remembered identity instead of collapsing to a placeholder.
        state.connected = false
        state.usbDescription = "USB 2c7c:0125"
        let offline = DeviceSummaryDisplay.make(
            state: state,
            statusTextKey: "status.offline",
            rememberedDetail: "USB 2c7c:0125 if2 out=0x03 in=0x84"
        )
        XCTAssertEqual(offline.usbIdentity, "USB 2c7c:0125 · if2")
        XCTAssertEqual(offline.endpoints, "out=0x03 · in=0x84")
        XCTAssertFalse(offline.isOnline)

        // Without a remembered session, the default identity still renders —
        // the row is never removed from the sidebar.
        let cold = DeviceSummaryDisplay.make(
            state: state,
            statusTextKey: "status.offline",
            rememberedDetail: nil
        )
        XCTAssertEqual(cold.usbIdentity, "USB 2c7c:0125")
        XCTAssertNil(cold.endpoints)
    }

    func testDeviceSummaryReflectsRemoteMode() {
        var state = ModemState()
        state.remoteManagement.mode = .remote
        state.connected = true
        state.usbDescription = "Remote 192.168.1.5:48525 · USB 2c7c:0125 if2 out=0x03 in=0x84"
        let display = DeviceSummaryDisplay.make(
            state: state,
            statusTextKey: "status.offline",
            rememberedDetail: nil
        )
        XCTAssertEqual(display.modeKey, "remote.mode.remote")
        XCTAssertEqual(display.usbIdentity, "Remote 192.168.1.5:48525 · USB 2c7c:0125 · if2")
        XCTAssertEqual(display.endpoints, "out=0x03 · in=0x84")
    }
}

/// Cross-surface navigation state and shared presentation geometry.
@MainActor
final class PresentationStateTests: XCTestCase {
    func testAllMainTabsAlwaysOffered() {
        XCTAssertEqual(PanelTab.allCases, [
            .overview, .phone, .sms, .gnss, .network, .estk, .vowifi, .terminal, .settings,
        ])
    }

    func testSMSSurfaceVisibilityDerivation() {
        let model = WindowPresentationModel()
        XCTAssertFalse(model.isSMSSurfaceVisible)

        model.setPopoverShown(true, callPhase: .idle)
        model.popoverSelectedTab = .sms
        XCTAssertTrue(model.isSMSSurfaceVisible)

        model.popoverSelectedTab = .overview
        XCTAssertFalse(model.isSMSSurfaceVisible)

        model.setPopoverShown(false, callPhase: .idle)
        model.setStandaloneWindowVisible(true, callPhase: .idle)
        model.windowSelectedTab = .sms
        XCTAssertTrue(model.isSMSSurfaceVisible)

        model.setStandaloneWindowVisible(false, callPhase: .idle)
        XCTAssertFalse(model.isSMSSurfaceVisible)
    }

    func testPopoverAndWindowTabSelectionsAreIndependent() {
        let model = WindowPresentationModel()

        model.popoverSelectedTab = .phone
        XCTAssertEqual(model.windowSelectedTab, .overview)

        model.windowSelectedTab = .settings
        XCTAssertEqual(model.popoverSelectedTab, .phone)
    }

    func testSMSColumnsShareOneFixedPrimaryHeaderHeight() {
        XCTAssertEqual(SMSLayoutMetrics.primaryHeaderHeight, 54)
        XCTAssertEqual(SMSLayoutMetrics.recipientRowHeight, 36)
        XCTAssertGreaterThan(
            SMSLayoutMetrics.primaryHeaderHeight,
            SMSLayoutMetrics.recipientRowHeight
        )
    }
}

/// Native symbol, device-summary edge case, and Settings routing consistency.
@MainActor
final class WindowConsistencyTests: XCTestCase {
    func testEveryPanelTabIconResolvesInTheCurrentSDK() {
        XCTAssertEqual(PanelTab.allCases.count, 9)
        for tab in PanelTab.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil),
                "\(tab.rawValue) icon \(tab.systemImage) does not resolve"
            )
        }
    }

    func testSymbolResolverFallsBackForUnknownName() {
        XCTAssertEqual(
            SFSymbolAvailability.resolvedName(
                preferred: "definitely-not-a-real-symbol-xyz",
                fallback: "wifi"
            ),
            "wifi"
        )
    }

    func testSummaryLinesHandlePartialAndUnrelatedDescriptions() {
        let bare = DeviceSummaryDisplay.summaryLines(from: "USB 2c7c:0125")
        XCTAssertEqual(bare.identity, "USB 2c7c:0125")
        XCTAssertNil(bare.endpoints)

        let noUSB = DeviceSummaryDisplay.summaryLines(from: "waiting for device")
        XCTAssertEqual(noUSB.identity, "waiting for device")
        XCTAssertNil(noUSB.endpoints)
    }

    func testSettingsSearchRoutesResolveToWindowSectionAnchors() {
        let routes = SidebarSearchIndex.entries
            .filter { $0.tab == .settings }
            .compactMap(\.route)
        XCTAssertEqual(routes.count, SettingsCategory.allCases.count)
        for route in routes {
            XCTAssertNotNil(
                SettingsCategory(rawValue: route.category),
                "settings route \(route.category) has no window section anchor"
            )
        }
        XCTAssertEqual(
            Set(SettingsCategory.allCases.map(\.rawValue)).count,
            SettingsCategory.allCases.count
        )
    }
}
