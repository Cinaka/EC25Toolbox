import XCTest
@testable import EC25Toolbox

/// R12 caller-identity tests: epoch-bound identity model, the bounded
/// RING→CLIP merge window, CLCC number fallback, contact resolution, and
/// same-identifier in-place banner replacement.
final class IncomingCallIdentityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let window: TimeInterval = 0.4

    // MARK: - Coordinator: bare RING merge window

    func testBareRingHoldsBannerUntilDeadline() {
        var coordinator = IncomingCallIdentityCoordinator()
        let decision = coordinator.incomingBegan(epoch: 1, number: nil, at: t0, mergeWindow: window)
        XCTAssertEqual(decision, .holdBanner(until: t0.addingTimeInterval(window)))
        XCTAssertEqual(coordinator.identity?.status, .pending)
        XCTAssertFalse(coordinator.identity?.mergeWindowElapsed ?? true)
    }

    func testClipWithinMergeWindowPostsResolvedBanner() {
        // 50 ms and 300 ms both sit inside the 400 ms window: the banner
        // never shows "unknown" — it posts directly with the number.
        for delay in [TimeInterval(0.05), 0.3] {
            var coordinator = IncomingCallIdentityCoordinator()
            _ = coordinator.incomingBegan(epoch: 1, number: nil, at: t0, mergeWindow: window)
            let decision = coordinator.clipArrived(
                number: "+8613800138000",
                epoch: 1,
                at: t0.addingTimeInterval(delay)
            )
            XCTAssertEqual(decision, .postBanner)
            XCTAssertEqual(coordinator.identity?.status, .resolved)
            XCTAssertEqual(coordinator.identity?.source, .clip)
            // The expired hold is a no-op once the identity is resolved.
            XCTAssertEqual(
                coordinator.mergeWindowExpired(epoch: 1, at: t0.addingTimeInterval(window)),
                .none
            )
        }
    }

    func testClipAfterWindowExpiredReplacesUnknownBanner() {
        // 700 ms: the window already expired and posted the explicit unknown
        // banner; the late CLIP replaces that banner in place.
        var coordinator = IncomingCallIdentityCoordinator()
        _ = coordinator.incomingBegan(epoch: 1, number: nil, at: t0, mergeWindow: window)
        XCTAssertEqual(
            coordinator.mergeWindowExpired(epoch: 1, at: t0.addingTimeInterval(window)),
            .postBanner
        )
        let decision = coordinator.clipArrived(
            number: "+8613800138000",
            epoch: 1,
            at: t0.addingTimeInterval(0.7)
        )
        XCTAssertEqual(decision, .replaceBanner)
        XCTAssertEqual(coordinator.identity?.status, .resolved)
        XCTAssertEqual(coordinator.identity?.source, .clip)
    }

    func testMergeWindowExpiryMarksUnknownNotPending() {
        var coordinator = IncomingCallIdentityCoordinator()
        _ = coordinator.incomingBegan(epoch: 1, number: nil, at: t0, mergeWindow: window)
        XCTAssertEqual(
            coordinator.mergeWindowExpired(epoch: 1, at: t0.addingTimeInterval(window)),
            .postBanner
        )
        let display = CallerIdentityDerivator.display(
            identity: coordinator.identity,
            pendingText: "pending",
            unknownText: "unknown",
            withheldText: "withheld"
        )
        XCTAssertTrue(display.isUnknown)
        XCTAssertEqual(display.title, "unknown")
        // A repeated expiry must not double-post.
        XCTAssertEqual(
            coordinator.mergeWindowExpired(epoch: 1, at: t0.addingTimeInterval(window + 0.1)),
            .none
        )
    }

    // MARK: - Coordinator: ordering and fallback sources

    func testClipBeforeRingSeedsResolvedBanner() {
        // CLIP arriving before any RING seeds the epoch identity directly;
        // the following RING for the same epoch never re-posts.
        var coordinator = IncomingCallIdentityCoordinator()
        let decision = coordinator.clipArrived(number: "+8613800138000", epoch: 1, at: t0)
        XCTAssertEqual(decision, .postBanner)
        XCTAssertEqual(coordinator.identity?.status, .resolved)
        XCTAssertEqual(
            coordinator.incomingBegan(epoch: 1, number: "+8613800138000", at: t0, mergeWindow: window),
            .none
        )
    }

    func testCLCCFallbackReplacesUnknownBanner() {
        // Only a CLCC number ever arrived for the ringing call.
        var coordinator = IncomingCallIdentityCoordinator()
        _ = coordinator.incomingBegan(epoch: 1, number: nil, at: t0, mergeWindow: window)
        _ = coordinator.mergeWindowExpired(epoch: 1, at: t0.addingTimeInterval(window))
        let decision = coordinator.clccNumber(number: "+8613900139000", epoch: 1, at: t0.addingTimeInterval(0.9))
        XCTAssertEqual(decision, .replaceBanner)
        XCTAssertEqual(coordinator.identity?.source, .clcc)
    }

    func testCLCCNumberIgnoredWhenClipAlreadyResolved() {
        // CLIP keeps priority over a later CLCC number.
        var coordinator = IncomingCallIdentityCoordinator()
        _ = coordinator.clipArrived(number: "+8613800138000", epoch: 1, at: t0)
        let decision = coordinator.clccNumber(number: "+8613900139000", epoch: 1, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(decision, .none)
        XCTAssertEqual(coordinator.identity?.rawNumber, "+8613800138000")
        XCTAssertEqual(coordinator.identity?.source, .clip)
    }

    // MARK: - Coordinator: contacts and withheld

    func testContactHitReplacesBannerWithTitle() {
        var coordinator = IncomingCallIdentityCoordinator()
        _ = coordinator.clipArrived(number: "+8613800138000", epoch: 1, at: t0)
        let decision = coordinator.contactResolved(name: "Ada", epoch: 1, at: t0.addingTimeInterval(0.05))
        XCTAssertEqual(decision, .replaceBanner)
        let display = CallerIdentityDerivator.display(
            identity: coordinator.identity,
            pendingText: "pending",
            unknownText: "unknown",
            withheldText: "withheld"
        )
        XCTAssertEqual(display.title, "Ada")
        XCTAssertEqual(display.subtitle, "+8613800138000")
        XCTAssertEqual(display.timelineToken, "identity=contact")
        // Re-resolving to the same name must not churn the banner.
        XCTAssertEqual(
            coordinator.contactResolved(name: "Ada", epoch: 1, at: t0.addingTimeInterval(0.1)),
            .none
        )
    }

    func testContactMissKeepsNumberBanner() {
        var coordinator = IncomingCallIdentityCoordinator()
        _ = coordinator.clipArrived(number: "+8613800138000", epoch: 1, at: t0)
        XCTAssertEqual(coordinator.contactResolved(name: nil, epoch: 1, at: t0), .none)
        XCTAssertEqual(coordinator.contactResolved(name: "", epoch: 1, at: t0), .none)
        XCTAssertEqual(coordinator.identity?.displayName, nil)
    }

    func testWithheldClipPostsPrivateBanner() {
        var coordinator = IncomingCallIdentityCoordinator()
        _ = coordinator.incomingBegan(epoch: 1, number: nil, at: t0, mergeWindow: window)
        let decision = coordinator.clipArrived(number: nil, epoch: 1, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(decision, .postBanner)
        XCTAssertEqual(coordinator.identity?.status, .withheld)
        let display = CallerIdentityDerivator.display(
            identity: coordinator.identity,
            pendingText: "pending",
            unknownText: "unknown",
            withheldText: "withheld"
        )
        XCTAssertTrue(display.isWithheld)
        XCTAssertEqual(display.title, "withheld")
    }

    func testWithheldUpgradedByCLCCNumber() {
        var coordinator = IncomingCallIdentityCoordinator()
        _ = coordinator.incomingBegan(epoch: 1, number: nil, at: t0, mergeWindow: window)
        _ = coordinator.clipArrived(number: nil, epoch: 1, at: t0.addingTimeInterval(0.1))
        let decision = coordinator.clccNumber(number: "+8613800138000", epoch: 1, at: t0.addingTimeInterval(0.5))
        XCTAssertEqual(decision, .replaceBanner)
        XCTAssertEqual(coordinator.identity?.status, .resolved)
        XCTAssertEqual(coordinator.identity?.source, .clcc)
    }

    // MARK: - Coordinator: epochs

    func testStaleEpochClipDropped() {
        var coordinator = IncomingCallIdentityCoordinator()
        _ = coordinator.incomingBegan(epoch: 2, number: nil, at: t0, mergeWindow: window)
        XCTAssertEqual(coordinator.clipArrived(number: "+8613800138000", epoch: 1, at: t0), .none)
        XCTAssertEqual(coordinator.identity?.status, .pending)
        XCTAssertEqual(coordinator.identity?.epoch, 2)
        XCTAssertEqual(coordinator.contactResolved(name: "Ada", epoch: 1, at: t0), .none)
    }

    func testCallEndedClearsIdentityAndDropsLateResults() {
        var coordinator = IncomingCallIdentityCoordinator()
        _ = coordinator.clipArrived(number: "+8613800138000", epoch: 1, at: t0)
        coordinator.callEnded(epoch: 1)
        XCTAssertNil(coordinator.identity)
        XCTAssertEqual(coordinator.clipArrived(number: "+8613900139000", epoch: 1, at: t0), .none)
        // An older epoch may not clear a newer call's identity either.
        _ = coordinator.clipArrived(number: "+8613800138000", epoch: 3, at: t0)
        coordinator.callEnded(epoch: 2)
        XCTAssertEqual(coordinator.identity?.epoch, 3)
    }

    func testReentryAfterRetractionRepostsResolvedIdentity() {
        // A failed answer returns to `.incoming` for the same epoch: after the
        // banner retracted, the re-entry re-posts with the known identity.
        var coordinator = IncomingCallIdentityCoordinator()
        _ = coordinator.clipArrived(number: "+8613800138000", epoch: 1, at: t0)
        coordinator.bannerRetracted(epoch: 1)
        let decision = coordinator.incomingBegan(
            epoch: 1,
            number: "+8613800138000",
            at: t0.addingTimeInterval(1),
            mergeWindow: window
        )
        XCTAssertEqual(decision, .postBanner)
        // A still-pending identity re-arms the window instead of posting
        // "unknown" immediately.
        var pending = IncomingCallIdentityCoordinator()
        _ = pending.incomingBegan(epoch: 1, number: nil, at: t0, mergeWindow: window)
        pending.bannerRetracted(epoch: 1)
        let rearm = pending.incomingBegan(epoch: 1, number: nil, at: t0, mergeWindow: window)
        guard case .holdBanner = rearm else {
            XCTFail("expected re-armed hold, got \(rearm)")
            return
        }
    }

    // MARK: - Derivator

    func testDerivatorPriorityChain() {
        let pendingIdentity = IncomingCallerIdentity(epoch: 1)
        var display = CallerIdentityDerivator.display(
            identity: pendingIdentity,
            pendingText: "pending",
            unknownText: "unknown",
            withheldText: "withheld"
        )
        XCTAssertTrue(display.isPending)
        XCTAssertEqual(display.title, "pending")

        var resolved = IncomingCallerIdentity(epoch: 1)
        resolved.resolve(number: "+8613800138000", source: .clip, at: t0)
        display = CallerIdentityDerivator.display(
            identity: resolved,
            pendingText: "pending",
            unknownText: "unknown",
            withheldText: "withheld"
        )
        XCTAssertEqual(display.title, "+8613800138000")
        XCTAssertNil(display.subtitle)
        XCTAssertEqual(display.timelineToken, "identity=number")

        resolved.displayName = "Ada"
        display = CallerIdentityDerivator.display(
            identity: resolved,
            pendingText: "pending",
            unknownText: "unknown",
            withheldText: "withheld"
        )
        XCTAssertEqual(display.title, "Ada")
        XCTAssertEqual(display.subtitle, "+8613800138000")
    }

    func testDerivatorBareNumberConvenience() {
        XCTAssertEqual(
            CallerIdentityDerivator.display(number: "10086", contactName: "Service", unknownText: "unknown").title,
            "Service"
        )
        XCTAssertEqual(
            CallerIdentityDerivator.display(number: "10086", contactName: nil, unknownText: "unknown").title,
            "10086"
        )
        XCTAssertEqual(
            CallerIdentityDerivator.display(number: nil, contactName: nil, unknownText: "unknown").isUnknown,
            true
        )
    }

    func testIdentityNormalization() {
        XCTAssertEqual(IncomingCallerIdentity.normalized("+86 138-0013-8000"), "+8613800138000")
        XCTAssertEqual(IncomingCallerIdentity.normalized(" 10086 "), "10086")
    }

    func testInternationalDisplayAddsMainlandCountryCodeOnlyWhenSafe() {
        XCTAssertEqual(PhoneNumberDisplay.internationalized("13800138000"), "+8613800138000")
        XCTAssertEqual(PhoneNumberDisplay.internationalized("+1 415 555 0100"), "+14155550100")
        XCTAssertEqual(PhoneNumberDisplay.internationalized("008613800138000"), "+8613800138000")
        XCTAssertEqual(PhoneNumberDisplay.internationalized("10086"), "10086")
    }

    func testContactSubtitleUsesInternationalDisplayNumber() {
        let display = CallerIdentityDerivator.display(
            number: "13800138000",
            contactName: "Ada",
            unknownText: "unknown"
        )
        XCTAssertEqual(display.title, "Ada")
        XCTAssertEqual(display.subtitle, "+8613800138000")
    }
}

/// Store-level R12 integration: the merge window runs against the real feed
/// pipeline, the banner replaces in place with one identifier, and contact
/// resolution flows through the injected resolvers.
@MainActor
final class IncomingCallIdentityStoreTests: XCTestCase {
    private func makeStore() -> ModemStore {
        ModemStore(
            callLogStore: CallLogStore(applicationSupportDirectory: URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true
            ))
        )
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    override nonisolated func setUp() async throws {
        await MainActor.run {
            CallNotification.resetTestObservability()
        }
    }

    func testBareRingHoldsBannerUntilClipArrives() {
        let store = makeStore()
        store.feedMachine(.ring)
        XCTAssertEqual(store.state.call.phase, .incoming)
        XCTAssertEqual(store.state.callerIdentity?.status, .pending)
        XCTAssertNil(CallNotification.postedBannerEpoch)

        store.feedMachine(.clip(number: "+8613800138000"))
        XCTAssertEqual(CallNotification.postedBannerEpoch, 1)
        XCTAssertEqual(CallNotification.lastBannerBody, "+8613800138000")
        XCTAssertEqual(CallNotification.bannerReplaceCount, 0)
        XCTAssertEqual(store.state.callerIdentity?.status, .resolved)
    }

    func testMergeWindowExpiryPostsExplicitUnknownBanner() async {
        let store = makeStore()
        store.callerIdentityMergeWindow = 0.05
        store.feedMachine(.ring)
        await waitUntil { CallNotification.postedBannerEpoch == 1 }
        XCTAssertEqual(CallNotification.lastBannerBody, localized("phone.status.no_number"))
        XCTAssertEqual(store.state.callerIdentity?.mergeWindowElapsed, true)
    }

    func testLateClipReplacesUnknownBannerInPlace() async {
        let store = makeStore()
        store.callerIdentityMergeWindow = 0.05
        store.feedMachine(.ring)
        await waitUntil { CallNotification.postedBannerEpoch == 1 }
        XCTAssertEqual(CallNotification.lastBannerBody, localized("phone.status.no_number"))

        store.feedMachine(.clip(number: "+8613800138000"))
        XCTAssertEqual(CallNotification.postedBannerEpoch, 1)
        XCTAssertEqual(CallNotification.lastBannerBody, "+8613800138000")
        XCTAssertEqual(CallNotification.bannerReplaceCount, 1)
        // Exactly one banner post and one in-place replacement — never a
        // second banner identifier.
        XCTAssertTrue(store.state.callTimeline.contains(.notifyReplaced))
    }

    func testContactNameReplacesBannerContent() {
        let store = makeStore()
        store.callContactNameResolver = { number in
            number == "+8613800138000" ? "Ada" : nil
        }
        store.feedMachine(.ring)
        store.feedMachine(.clip(number: "+8613800138000"))
        XCTAssertEqual(CallNotification.lastBannerBody, "Ada")
        XCTAssertEqual(CallNotification.bannerReplaceCount, 1)
        XCTAssertEqual(store.state.callerIdentity?.displayName, "Ada")
    }

    func testContactMissKeepsNumberAndNeverShowsUnknown() {
        let store = makeStore()
        store.callContactNameResolver = { _ in nil }
        store.feedMachine(.ring)
        store.feedMachine(.clip(number: "+8613800138000"))
        XCTAssertEqual(CallNotification.lastBannerBody, "+8613800138000")
        XCTAssertEqual(store.state.callerIdentity?.displayName, nil)
    }

    func testCLCCNumberFallsBackForBareRing() async {
        let store = makeStore()
        store.callerIdentityMergeWindow = 0.05
        store.feedMachine(.ring)
        await waitUntil { CallNotification.postedBannerEpoch == 1 }

        store.feedMachine(.clcc([CLCCEntry(
            index: 1,
            direction: .incoming,
            status: .incoming,
            number: "+8613900139000"
        )]))
        XCTAssertEqual(CallNotification.lastBannerBody, "+8613900139000")
        XCTAssertEqual(CallNotification.bannerReplaceCount, 1)
        XCTAssertEqual(store.state.callerIdentity?.source, .clcc)
    }

    func testWithheldClipFeedsDistinctPrivateText() {
        let store = makeStore()
        store.feedMachine(.ring)
        store.feedMachine(.clip(number: nil))
        XCTAssertEqual(CallNotification.lastBannerBody, localized("call.identity.withheld"))
        XCTAssertEqual(store.state.callerIdentity?.status, .withheld)
    }

    func testConcludedCallDropsIdentityAndLateResults() {
        let store = makeStore()
        store.feedMachine(.ring)
        store.feedMachine(.clip(number: "+8613800138000"))
        store.feedMachine(.noCarrier)
        XCTAssertEqual(store.state.call.phase, .missed)
        XCTAssertNil(store.state.callerIdentity)
        XCTAssertNil(CallNotification.postedBannerEpoch)

        // A second call: the old epoch's late identity must not leak in.
        store.feedMachine(.ring)
        XCTAssertEqual(store.state.callerIdentity?.epoch, 2)
        XCTAssertEqual(store.state.callerIdentity?.status, .pending)
    }

    func testModemEventWithheldClipMapsToDistinctInput() {
        XCTAssertEqual(ModemEvent.fromURC("RING"), .incomingCall(number: nil))
        XCTAssertEqual(ModemEvent.fromURC("+CLIP: \"+8613800138000\",145"), .incomingCall(number: "+8613800138000"))
        XCTAssertEqual(ModemEvent.fromURC("+CLIP: \"\",129"), .clipWithoutNumber)
        XCTAssertEqual(ModemEvent.fromURC("+CLIP:"), .clipWithoutNumber)
    }
}
