@testable import EC25Toolbox
import XCTest

final class RecoveryStateMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(after seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private var allTiers: Set<RecoveryTier> {
        Set(RecoveryTier.allCases)
    }

    /// What the driver passes while the AT transport is gone: higher tiers
    /// cannot run without a live AT session.
    private var usbOnly: Set<RecoveryTier> {
        [.usbReconnect]
    }

    // MARK: - Episode lifecycle

    func testIdleMachineAuthorizesNothing() {
        var machine = RecoveryStateMachine()
        XCTAssertFalse(machine.isActive)
        XCTAssertNil(machine.beginAttempt(now: t0, applicable: allTiers))
    }

    func testTransportLostStartsAtUSBReconnect() {
        var machine = RecoveryStateMachine()
        machine.reportSymptom(.transportLost, now: t0)
        let begin = machine.beginAttempt(now: t0, applicable: usbOnly)
        XCTAssertEqual(begin?.tier, .usbReconnect)
        XCTAssertFalse(begin?.restartedEpisode ?? true)
    }

    func testDataStalledSkipsUSBReconnect() {
        var machine = RecoveryStateMachine()
        machine.reportSymptom(.dataStalled, now: t0)
        XCTAssertEqual(machine.beginAttempt(now: t0, applicable: allTiers)?.tier, .dhcpRenew)
    }

    func testRepeatedSymptomReportsDoNotResetEpisode() {
        var machine = RecoveryStateMachine()
        machine.reportSymptom(.dataStalled, now: t0)
        _ = machine.beginAttempt(now: t0, applicable: allTiers)
        _ = machine.reportOutcome(.dhcpRenew, succeeded: false, now: date(after: 1), applicable: allTiers)
        XCTAssertEqual(machine.attempts(at: .dhcpRenew), 1)

        machine.reportSymptom(.dataStalled, now: date(after: 2))
        XCTAssertEqual(machine.attempts(at: .dhcpRenew), 1, "same-symptom report must not clear attempts")
    }

    func testSymptomSwitchResetsEpisode() {
        var machine = RecoveryStateMachine()
        machine.config.cooldowns[.dhcpRenew] = 1
        machine.reportSymptom(.transportLost, now: t0)
        _ = machine.beginAttempt(now: t0, applicable: usbOnly)
        _ = machine.reportOutcome(.usbReconnect, succeeded: false, now: t0, applicable: usbOnly)

        machine.reportSymptom(.dataStalled, now: date(after: 5))
        XCTAssertEqual(machine.attempts(at: .usbReconnect), 0)
        XCTAssertEqual(machine.beginAttempt(now: date(after: 5), applicable: allTiers)?.tier, .dhcpRenew)
    }

    func testSuccessEndsEpisode() {
        var machine = RecoveryStateMachine()
        machine.reportSymptom(.transportLost, now: t0)
        _ = machine.beginAttempt(now: t0, applicable: usbOnly)
        let report = machine.reportOutcome(.usbReconnect, succeeded: true, now: t0, applicable: usbOnly)
        XCTAssertTrue(report.recovered)
        XCTAssertFalse(machine.isActive)
        XCTAssertNil(machine.beginAttempt(now: date(after: 100), applicable: usbOnly))

        // A later symptom starts a fresh episode with zeroed attempts.
        machine.reportSymptom(.transportLost, now: date(after: 100))
        XCTAssertEqual(machine.attempts(at: .usbReconnect), 0)
    }

    func testHealthyResetsMachine() {
        var machine = RecoveryStateMachine()
        machine.reportSymptom(.dataStalled, now: t0)
        _ = machine.beginAttempt(now: t0, applicable: allTiers)
        machine.reportHealthy()
        XCTAssertFalse(machine.isActive)
        XCTAssertNil(machine.beginAttempt(now: t0, applicable: allTiers))
    }

    func testCancelResetsMachine() {
        var machine = RecoveryStateMachine()
        machine.reportSymptom(.transportLost, now: t0)
        machine.cancel()
        XCTAssertFalse(machine.isActive)
    }

    // MARK: - Cooldowns and escalation

    func testCooldownBlocksImmediateRetry() {
        var machine = RecoveryStateMachine()
        machine.config.cooldowns[.usbReconnect] = 30
        machine.reportSymptom(.transportLost, now: t0)
        XCTAssertEqual(machine.beginAttempt(now: t0, applicable: usbOnly)?.tier, .usbReconnect)
        XCTAssertNil(machine.beginAttempt(now: date(after: 10), applicable: usbOnly))
        XCTAssertEqual(machine.beginAttempt(now: date(after: 30), applicable: usbOnly)?.tier, .usbReconnect)
    }

    func testEscalationAfterTierAttemptsExhausted() {
        var machine = RecoveryStateMachine()
        machine.reportSymptom(.dataStalled, now: t0)
        // Advance far enough past every tier cooldown between attempts.
        var now = t0

        // dhcpRenew: default cap of 2 attempts.
        for _ in 0..<2 {
            XCTAssertEqual(machine.beginAttempt(now: now, applicable: allTiers)?.tier, .dhcpRenew)
            _ = machine.reportOutcome(.dhcpRenew, succeeded: false, now: now, applicable: allTiers)
            now = now.addingTimeInterval(120)
        }
        XCTAssertEqual(machine.beginAttempt(now: now, applicable: allTiers)?.tier, .networkReattach)
        _ = machine.reportOutcome(.networkReattach, succeeded: false, now: now, applicable: allTiers)
        now = now.addingTimeInterval(120)
        XCTAssertEqual(machine.beginAttempt(now: now, applicable: allTiers)?.tier, .networkReattach)
        _ = machine.reportOutcome(.networkReattach, succeeded: false, now: now, applicable: allTiers)
        // moduleReset carries a five-minute cooldown even right after the
        // gentler tiers failed.
        now = now.addingTimeInterval(310)
        XCTAssertEqual(machine.beginAttempt(now: now, applicable: allTiers)?.tier, .moduleReset)
    }

    func testInapplicableTiersAreSkippedNotBurned() {
        var machine = RecoveryStateMachine()
        machine.reportSymptom(.dataStalled, now: t0)
        // No configured module service: dhcpRenew not applicable, so the
        // ladder starts at networkReattach even though it is tier 2.
        let tiers: Set<RecoveryTier> = [.networkReattach, .moduleReset, .hardReset]
        XCTAssertEqual(machine.beginAttempt(now: t0, applicable: tiers)?.tier, .networkReattach)
    }

    func testNothingApplicableWaitsWithoutExhausting() {
        var machine = RecoveryStateMachine()
        machine.reportSymptom(.dataStalled, now: t0)
        XCTAssertNil(machine.beginAttempt(now: t0, applicable: []))
        // The empty applicability set must not start the exhaustion pause.
        let report = machine.reportOutcome(.dhcpRenew, succeeded: false, now: t0, applicable: [])
        XCTAssertFalse(report.exhausted)
        // Tiers appearing later are still authorized.
        XCTAssertEqual(machine.beginAttempt(now: t0, applicable: [.dhcpRenew])?.tier, .dhcpRenew)
    }

    // MARK: - Exhaustion pause and restart

    func testExhaustedEpisodePausesThenRestarts() {
        var machine = RecoveryStateMachine()
        machine.config.episodeRetryDelay = 300
        machine.reportSymptom(.transportLost, now: t0)
        // Burn all three usbReconnect attempts; the third failure (t0+60)
        // marks the episode exhausted.
        var sawExhausted = false
        for index in 0..<3 {
            let now = t0.addingTimeInterval(Double(index) * 30)
            XCTAssertEqual(machine.beginAttempt(now: now, applicable: usbOnly)?.tier, .usbReconnect)
            let report = machine.reportOutcome(.usbReconnect, succeeded: false, now: now, applicable: usbOnly)
            sawExhausted = sawExhausted || report.exhausted
        }
        XCTAssertTrue(sawExhausted, "final usbReconnect failure exhausts the usb-only ladder")

        XCTAssertNil(machine.beginAttempt(now: date(after: 359), applicable: usbOnly), "pause window")
        let restart = machine.beginAttempt(now: date(after: 360), applicable: usbOnly)
        XCTAssertEqual(restart?.tier, .usbReconnect)
        XCTAssertTrue(restart?.restartedEpisode ?? false)
        XCTAssertEqual(machine.attempts(at: .usbReconnect), 0)
    }

    func testBeginAttemptMarksExhaustionWhenLadderAlreadySpent() {
        var machine = RecoveryStateMachine()
        machine.config.episodeRetryDelay = 100
        machine.reportSymptom(.transportLost, now: t0)
        // Outcomes reported while nothing was applicable must not mark
        // exhaustion themselves.
        for _ in 0..<3 {
            _ = machine.beginAttempt(now: t0, applicable: usbOnly)
            _ = machine.reportOutcome(.usbReconnect, succeeded: false, now: t0, applicable: [])
        }
        XCTAssertNil(machine.beginAttempt(now: t0, applicable: usbOnly), "marks the pause now")
        XCTAssertNil(machine.beginAttempt(now: date(after: 99), applicable: usbOnly))
        XCTAssertEqual(machine.beginAttempt(now: date(after: 100), applicable: usbOnly)?.tier, .usbReconnect)
    }

    // MARK: - User priority

    func testUserActivityPacesAutomation() {
        var machine = RecoveryStateMachine()
        machine.reportSymptom(.transportLost, now: t0)
        XCTAssertEqual(machine.beginAttempt(now: t0, applicable: usbOnly)?.tier, .usbReconnect)

        machine.reportUserActivity(now: date(after: 5))
        XCTAssertNil(machine.beginAttempt(now: date(after: 6), applicable: usbOnly))
        XCTAssertEqual(machine.beginAttempt(now: date(after: 15), applicable: usbOnly)?.tier, .usbReconnect)
    }

    func testUserActivitySurvivesEpisodeReset() {
        var machine = RecoveryStateMachine()
        machine.reportSymptom(.transportLost, now: t0)
        machine.reportUserActivity(now: date(after: 5))
        machine.cancel()
        machine.reportSymptom(.transportLost, now: date(after: 6))
        XCTAssertNil(machine.beginAttempt(now: date(after: 6), applicable: usbOnly))
    }

    // MARK: - Hard reset limiting

    func testHardResetSingleAttemptPerEpisode() {
        var machine = RecoveryStateMachine()
        machine.config.cooldowns = [
            .dhcpRenew: 0, .networkReattach: 0, .moduleReset: 0, .hardReset: 0
        ]
        machine.reportSymptom(.dataStalled, now: t0)
        var spent: [RecoveryTier] = []
        for _ in 0..<10 {
            guard let begin = machine.beginAttempt(now: t0, applicable: allTiers) else { break }
            spent.append(begin.tier)
            _ = machine.reportOutcome(begin.tier, succeeded: false, now: t0, applicable: allTiers)
        }
        XCTAssertEqual(spent, [.dhcpRenew, .dhcpRenew, .networkReattach, .networkReattach, .moduleReset, .hardReset])
        // Cap is one hard reset per episode: nothing more is authorized.
        XCTAssertNil(machine.beginAttempt(now: t0, applicable: allTiers))
    }

    // MARK: - Config plumbing

    func testCustomCooldownAndAttemptsHonored() {
        var machine = RecoveryStateMachine()
        machine.config.cooldowns[.usbReconnect] = 5
        machine.config.maxAttempts[.usbReconnect] = 1
        machine.reportSymptom(.transportLost, now: t0)
        XCTAssertEqual(machine.beginAttempt(now: t0, applicable: usbOnly)?.tier, .usbReconnect)
        XCTAssertEqual(machine.attempts(at: .usbReconnect), 0, "attempt counted only at outcome")
        let report = machine.reportOutcome(.usbReconnect, succeeded: false, now: t0, applicable: usbOnly)
        XCTAssertEqual(report.attemptsAtTier, 1)
        XCTAssertNil(machine.beginAttempt(now: date(after: 10), applicable: usbOnly), "cap of 1 reached")
    }

    func testDefaultCooldownsMatchTierSpecs() {
        XCTAssertEqual(RecoveryTier.usbReconnect.defaultCooldown, 10)
        XCTAssertEqual(RecoveryTier.dhcpRenew.defaultCooldown, 45)
        XCTAssertEqual(RecoveryTier.networkReattach.defaultCooldown, 60)
        XCTAssertEqual(RecoveryTier.moduleReset.defaultCooldown, 300)
        XCTAssertEqual(RecoveryTier.hardReset.defaultCooldown, 600)
        XCTAssertEqual(RecoveryTier.hardReset.defaultMaxAttempts, 1)
        XCTAssertEqual(RecoveryTier.firstTier(for: .transportLost), .usbReconnect)
        XCTAssertEqual(RecoveryTier.firstTier(for: .dataStalled), .dhcpRenew)
    }
}
