import XCTest
@testable import EC25Toolbox

final class CallStateMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func clcc(
        _ index: Int,
        _ dir: CLCCEntry.Direction,
        _ stat: CLCCEntry.Status,
        number: String? = nil
    ) -> CLCCEntry {
        CLCCEntry(index: index, direction: dir, status: stat, number: number)
    }

    // MARK: - CLCC parsing

    func testCLCCParsesFullEntry() {
        let entries = CLCCEntry.parse([
            "+CLCC: 1,0,3,0,0,\"+8613800138000\",129,\"Name\"",
            "OK"
        ])
        XCTAssertEqual(entries, [
            CLCCEntry(index: 1, direction: .outgoing, status: .alerting, number: "+8613800138000")
        ])
    }

    func testCLCCParsesEntryWithoutNumber() {
        let entry = CLCCEntry.parseLine("+CLCC: 2,1,4,0,0")
        XCTAssertEqual(entry, CLCCEntry(index: 2, direction: .incoming, status: .incoming, number: nil))
    }

    func testCLCCParsesEmptyNumberAsNil() {
        let entry = CLCCEntry.parseLine("+CLCC: 3,1,4,0,0,\"\",129")
        XCTAssertEqual(entry?.number, nil)
    }

    func testCLCCIgnoresNonCallLines() {
        XCTAssertTrue(CLCCEntry.parse(["OK", "+CREG: 0,5", ""]).isEmpty)
    }

    func testCLCCRejectsUnknownFields() {
        XCTAssertNil(CLCCEntry.parseLine("+CLCC: 1,0,9,0,0"))
        XCTAssertNil(CLCCEntry.parseLine("+CLCC: 1,7,0,0,0"))
        XCTAssertNil(CLCCEntry.parseLine("+CLCC: x,0,0,0,0"))
    }

    func testURCLineMapping() {
        XCTAssertEqual(CallInput.forURCLine("NO CARRIER"), .noCarrier)
        XCTAssertEqual(CallInput.forURCLine("BUSY"), .busy)
        XCTAssertEqual(CallInput.forURCLine("NO ANSWER"), .noAnswer)
        XCTAssertEqual(
            CallInput.forURCLine("+CLCC: 1,1,4,0,0,\"10086\",129"),
            .clcc([CLCCEntry(index: 1, direction: .incoming, status: .incoming, number: "10086")])
        )
        XCTAssertNil(CallInput.forURCLine("+CCWA: \"+8613\",129,1"))
    }

    // MARK: - Incoming calls

    func testRingStartsIncomingAndClipFillsNumber() {
        var machine = CallStateMachine()
        let begin = machine.handle(.ring, now: t0)
        XCTAssertEqual(begin?.from, .idle)
        XCTAssertEqual(begin?.to, .incoming)
        XCTAssertEqual(machine.phase, .incoming)
        XCTAssertEqual(machine.direction, .incoming)
        XCTAssertNil(machine.handle(.clip(number: "+8613800138000"), now: t0.addingTimeInterval(1)))
        XCTAssertEqual(machine.number, "+8613800138000")
        XCTAssertEqual(machine.status.phase, .incoming)
        XCTAssertEqual(machine.status.number, "+8613800138000")
    }

    func testIncomingRingSilenceTimeoutIsMissed() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.clip(number: "+8613800138000"), now: t0.addingTimeInterval(1))
        XCTAssertNil(machine.handle(.tick, now: t0.addingTimeInterval(29)))
        let missed = machine.handle(.tick, now: t0.addingTimeInterval(31))
        XCTAssertEqual(missed?.to, .missed)
        XCTAssertEqual(missed?.outcome?.reason, .missed)
        XCTAssertEqual(missed?.outcome?.number, "+8613800138000")
        XCTAssertEqual(missed?.outcome?.direction, .incoming)
        XCTAssertFalse(missed?.adviseHangUp ?? true)
        XCTAssertEqual(machine.phase, .missed)
        XCTAssertEqual(machine.lastOutcome?.reason, .missed)
    }

    func testIncomingCLCCRefreshesRingWatchdog() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        XCTAssertNil(machine.handle(.tick, now: t0.addingTimeInterval(29)))
        XCTAssertNil(machine.handle(.clcc([clcc(1, .incoming, .incoming, number: "+8613")]), now: t0.addingTimeInterval(30)))
        XCTAssertNil(machine.handle(.tick, now: t0.addingTimeInterval(59)))
        let missed = machine.handle(.tick, now: t0.addingTimeInterval(61))
        XCTAssertEqual(missed?.to, .missed)
    }

    func testIncomingAnswerWaitsForCLCCThenLocalHangUp() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.clip(number: "+8613"), now: t0.addingTimeInterval(1))
        let answering = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(2))
        XCTAssertEqual(answering?.to, .answering)
        XCTAssertNil(answering?.outcome)
        XCTAssertNil(machine.handle(.ataAccepted, now: t0.addingTimeInterval(3)))
        let active = machine.handle(
            .clcc([clcc(1, .incoming, .active, number: "+8613")]),
            now: t0.addingTimeInterval(4)
        )
        XCTAssertEqual(active?.to, .active)
        XCTAssertEqual(machine.callStartedAt, t0.addingTimeInterval(4))
        _ = machine.handle(.hangUpRequested, now: t0.addingTimeInterval(60))
        XCTAssertEqual(machine.phase, .ending)
        let hangUp = machine.handle(.hangUpAccepted, now: t0.addingTimeInterval(61))
        XCTAssertEqual(hangUp?.to, .ended)
        XCTAssertEqual(hangUp?.outcome?.reason, .localHangUp)
        XCTAssertEqual(hangUp?.outcome?.startedAt, t0.addingTimeInterval(4))
    }

    func testIncomingRejected() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.hangUpRequested, now: t0.addingTimeInterval(1))
        XCTAssertEqual(machine.phase, .ending)
        let rejected = machine.handle(.hangUpAccepted, now: t0.addingTimeInterval(2))
        XCTAssertEqual(rejected?.to, .ended)
        XCTAssertEqual(rejected?.outcome?.reason, .rejected)
        XCTAssertNil(rejected?.outcome?.startedAt)
    }

    func testIncomingNoCarrierIsMissed() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        let missed = machine.handle(.noCarrier, now: t0.addingTimeInterval(1))
        XCTAssertEqual(missed?.to, .missed)
        XCTAssertEqual(missed?.outcome?.reason, .missed)
    }

    func testAnsweringEmptyCLCCConcludesMissed() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(1))
        _ = machine.handle(.ataAccepted, now: t0.addingTimeInterval(1.5))
        let missed = machine.handle(.clccEmpty, now: t0.addingTimeInterval(2))
        XCTAssertEqual(missed?.to, .missed)
        XCTAssertEqual(missed?.outcome?.reason, .missed)
    }

    func testAnsweringNoCarrierConcludesMissed() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(1))
        let missed = machine.handle(.noCarrier, now: t0.addingTimeInterval(2))
        XCTAssertEqual(missed?.to, .missed)
        XCTAssertEqual(missed?.outcome?.reason, .missed)
    }

    func testAnsweringTimeoutAdvisesHangUp() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(1))
        _ = machine.handle(.ataAccepted, now: t0.addingTimeInterval(1.5))
        XCTAssertNil(machine.handle(.tick, now: t0.addingTimeInterval(21)))
        let failed = machine.handle(.tick, now: t0.addingTimeInterval(22))
        XCTAssertEqual(failed?.to, .failed)
        XCTAssertEqual(failed?.outcome?.reason, .answerTimeout)
        XCTAssertEqual(failed?.adviseHangUp, true)
    }

    func testAnswerFailureReturnsToIncomingForRetry() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(1))
        let back = machine.handle(.ataFailed, now: t0.addingTimeInterval(2))
        XCTAssertEqual(back?.to, .incoming)
        XCTAssertEqual(machine.phase, .incoming)
    }

    func testHangUpFailureResumesPreviousPhase() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(1))
        _ = machine.handle(.ataAccepted, now: t0.addingTimeInterval(1.5))
        _ = machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(2))
        XCTAssertEqual(machine.phase, .active)
        _ = machine.handle(.hangUpRequested, now: t0.addingTimeInterval(3))
        XCTAssertEqual(machine.phase, .ending)
        let resumed = machine.handle(.hangUpFailed, now: t0.addingTimeInterval(4))
        XCTAssertEqual(resumed?.to, .active)
        XCTAssertEqual(machine.phase, .active)
    }

    func testEndingIgnoresCLCCWhileCommandInFlight() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.hangUpRequested, now: t0.addingTimeInterval(1))
        XCTAssertEqual(machine.phase, .ending)
        XCTAssertNil(machine.handle(.clcc([clcc(1, .incoming, .incoming)]), now: t0.addingTimeInterval(2)))
        XCTAssertEqual(machine.phase, .ending)
    }

    func testEndingTimeoutConcludesWithPendingReason() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.hangUpRequested, now: t0.addingTimeInterval(1))
        XCTAssertNil(machine.handle(.tick, now: t0.addingTimeInterval(11)))
        let ended = machine.handle(.tick, now: t0.addingTimeInterval(12))
        XCTAssertEqual(ended?.to, .ended)
        XCTAssertEqual(ended?.outcome?.reason, .rejected)
        XCTAssertEqual(ended?.adviseHangUp, true)
    }

    func testStrayClipInIdleStartsIncoming() {
        var machine = CallStateMachine()
        let begin = machine.handle(.clip(number: "+8613"), now: t0)
        XCTAssertEqual(begin?.to, .incoming)
        XCTAssertEqual(machine.number, "+8613")
    }

    // MARK: - Outgoing calls

    func testOutgoingCLCCProgression() {
        var machine = CallStateMachine()
        let dialing = machine.handle(.userDialed(number: "10086"), now: t0)
        XCTAssertEqual(dialing?.to, .dialing)
        XCTAssertEqual(machine.direction, .outgoing)
        XCTAssertNil(machine.handle(.clcc([clcc(1, .outgoing, .dialing, number: "10086")]), now: t0.addingTimeInterval(1)))
        let alerting = machine.handle(.clcc([clcc(1, .outgoing, .alerting)]), now: t0.addingTimeInterval(2))
        XCTAssertEqual(alerting?.to, .alerting)
        let active = machine.handle(.clcc([clcc(1, .outgoing, .active)]), now: t0.addingTimeInterval(3))
        XCTAssertEqual(active?.to, .active)
        XCTAssertEqual(machine.callStartedAt, t0.addingTimeInterval(3))
        let ended = machine.handle(.clccEmpty, now: t0.addingTimeInterval(63))
        XCTAssertEqual(ended?.to, .ended)
        XCTAssertEqual(ended?.outcome?.reason, .remoteHangUp)
    }

    func testDialFailsOnBusy() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        let failed = machine.handle(.busy, now: t0.addingTimeInterval(1))
        XCTAssertEqual(failed?.to, .failed)
        XCTAssertEqual(failed?.outcome?.reason, .busy)
    }

    func testDialFailsOnNoCarrier() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        let failed = machine.handle(.noCarrier, now: t0.addingTimeInterval(1))
        XCTAssertEqual(failed?.outcome?.reason, .noCarrier)
    }

    func testAlertingFailsOnNoAnswerFinal() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        _ = machine.handle(.clcc([clcc(1, .outgoing, .alerting)]), now: t0.addingTimeInterval(1))
        let failed = machine.handle(.noAnswer, now: t0.addingTimeInterval(20))
        XCTAssertEqual(failed?.outcome?.reason, .noAnswer)
    }

    func testDialTimeoutAdvisesHangUp() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        XCTAssertNil(machine.handle(.tick, now: t0.addingTimeInterval(44)))
        let failed = machine.handle(.tick, now: t0.addingTimeInterval(46))
        XCTAssertEqual(failed?.to, .failed)
        XCTAssertEqual(failed?.outcome?.reason, .dialTimeout)
        XCTAssertEqual(failed?.adviseHangUp, true)
    }

    func testAlertingTimeoutAdvisesHangUp() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        _ = machine.handle(.clcc([clcc(1, .outgoing, .alerting)]), now: t0.addingTimeInterval(2))
        XCTAssertNil(machine.handle(.tick, now: t0.addingTimeInterval(2 + 74)))
        let failed = machine.handle(.tick, now: t0.addingTimeInterval(2 + 76))
        XCTAssertEqual(failed?.outcome?.reason, .noAnswer)
        XCTAssertEqual(failed?.adviseHangUp, true)
    }

    func testDialFailureCarriesDetail() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        let failed = machine.handle(.dialFailure("BLACKLISTED"), now: t0.addingTimeInterval(1))
        XCTAssertEqual(failed?.outcome?.reason, .dialFailed("BLACKLISTED"))
    }

    func testUserHangUpDuringDialing() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        _ = machine.handle(.hangUpRequested, now: t0.addingTimeInterval(1))
        XCTAssertEqual(machine.phase, .ending)
        let ended = machine.handle(.hangUpAccepted, now: t0.addingTimeInterval(2))
        XCTAssertEqual(ended?.outcome?.reason, .localHangUp)
        XCTAssertNil(ended?.outcome?.startedAt)
    }

    func testHeldThenResumeKeepsStart() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        _ = machine.handle(.clcc([clcc(1, .outgoing, .active)]), now: t0.addingTimeInterval(1))
        let held = machine.handle(.clcc([clcc(1, .outgoing, .held)]), now: t0.addingTimeInterval(10))
        XCTAssertEqual(held?.to, .held)
        let resumed = machine.handle(.clcc([clcc(1, .outgoing, .active)]), now: t0.addingTimeInterval(20))
        XCTAssertEqual(resumed?.to, .active)
        XCTAssertEqual(machine.callStartedAt, t0.addingTimeInterval(1))
    }

    // MARK: - Terminal phases & lifecycle

    func testTerminalLingerReturnsToIdleAndClearsNumber() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.clip(number: "+8613"), now: t0.addingTimeInterval(1))
        _ = machine.handle(.hangUpRequested, now: t0.addingTimeInterval(2))
        _ = machine.handle(.hangUpAccepted, now: t0.addingTimeInterval(2))
        XCTAssertEqual(machine.phase, .ended)
        XCTAssertNil(machine.handle(.tick, now: t0.addingTimeInterval(2 + 5)))
        let idle = machine.handle(.tick, now: t0.addingTimeInterval(2 + 7))
        XCTAssertEqual(idle?.to, .idle)
        XCTAssertNil(machine.number)
        XCTAssertNil(machine.direction)
        XCTAssertEqual(machine.status.phase, .idle)
        XCTAssertEqual(machine.status.number, nil)
        XCTAssertFalse(machine.isTrackingCall)
    }

    func testNewRingDuringTerminalLinger() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        _ = machine.handle(.busy, now: t0.addingTimeInterval(1))
        XCTAssertEqual(machine.phase, .failed)
        let incoming = machine.handle(.ring, now: t0.addingTimeInterval(2))
        XCTAssertEqual(incoming?.from, .failed)
        XCTAssertEqual(incoming?.to, .incoming)
        XCTAssertEqual(machine.direction, .incoming)
        XCTAssertNil(machine.number)
    }

    func testRedialDuringTerminalLinger() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        _ = machine.handle(.busy, now: t0.addingTimeInterval(1))
        let dialing = machine.handle(.userDialed(number: "10086"), now: t0.addingTimeInterval(2))
        XCTAssertEqual(dialing?.from, .failed)
        XCTAssertEqual(dialing?.to, .dialing)
    }

    func testTransportLostDuringActive() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        _ = machine.handle(.clcc([clcc(1, .outgoing, .active)]), now: t0.addingTimeInterval(1))
        let failed = machine.handle(.transportLost, now: t0.addingTimeInterval(2))
        XCTAssertEqual(failed?.outcome?.reason, .transportLost)
    }

    func testUnrelatedInputsAreIgnored() {
        var machine = CallStateMachine()
        XCTAssertNil(machine.handle(.busy, now: t0))
        XCTAssertNil(machine.handle(.noCarrier, now: t0))
        XCTAssertNil(machine.handle(.noAnswer, now: t0))
        XCTAssertNil(machine.handle(.clccEmpty, now: t0))
        XCTAssertNil(machine.handle(.userAnswerRequested, now: t0))
        XCTAssertNil(machine.handle(.ataAccepted, now: t0))
        XCTAssertNil(machine.handle(.ataFailed, now: t0))
        XCTAssertNil(machine.handle(.hangUpRequested, now: t0))
        XCTAssertNil(machine.handle(.hangUpAccepted, now: t0))
        XCTAssertNil(machine.handle(.hangUpFailed, now: t0))
        XCTAssertNil(machine.handle(.transportLost, now: t0))
        XCTAssertNil(machine.handle(.tick, now: t0))
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.hasLiveCall)
        XCTAssertFalse(machine.isTrackingCall)
    }

    func testDialWhileIncomingIsRejectedByMachine() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        XCTAssertNil(machine.handle(.userDialed(number: "10086"), now: t0.addingTimeInterval(1)))
        XCTAssertEqual(machine.phase, .incoming)
    }

    func testAdoptsSoleIncomingEntryFromIdle() {
        var machine = CallStateMachine()
        let begin = machine.handle(
            .clcc([clcc(1, .incoming, .incoming, number: "+8613")]),
            now: t0
        )
        XCTAssertEqual(begin?.from, .idle)
        XCTAssertEqual(begin?.to, .incoming)
        XCTAssertEqual(machine.number, "+8613")
    }

    func testTrackedCallVanishingConcludesBeforeAdoptingNext() {
        var machine = CallStateMachine()
        _ = machine.handle(.userDialed(number: "10086"), now: t0)
        _ = machine.handle(.clcc([clcc(1, .outgoing, .active)]), now: t0.addingTimeInterval(1))
        let ended = machine.handle(
            .clcc([clcc(2, .incoming, .waiting, number: "+8613")]),
            now: t0.addingTimeInterval(2)
        )
        XCTAssertEqual(ended?.to, .ended)
        XCTAssertEqual(ended?.outcome?.reason, .remoteHangUp)
        let adopted = machine.handle(
            .clcc([clcc(2, .incoming, .incoming, number: "+8613")]),
            now: t0.addingTimeInterval(3)
        )
        XCTAssertEqual(adopted?.from, .ended)
        XCTAssertEqual(adopted?.to, .incoming)
        XCTAssertEqual(machine.lastOutcome?.reason, .remoteHangUp)
    }

    // MARK: - R8 answer gating (call epoch + answer intent)

    /// Spec sequence 1: RING -> tick -> CLCC incoming -> CLCC active with no
    /// user action at all. The call must stay incoming, operable, and the
    /// anomaly recorded.
    func testCLCCActiveWithoutUserAnswerKeepsIncoming() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        XCTAssertNil(machine.handle(.tick, now: t0.addingTimeInterval(1)))
        XCTAssertNil(machine.handle(.clcc([clcc(1, .incoming, .incoming)]), now: t0.addingTimeInterval(2)))
        XCTAssertNil(machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(3)))
        XCTAssertEqual(machine.phase, .incoming)
        XCTAssertEqual(machine.clccActiveAnomalies, 1)
        XCTAssertEqual(machine.status.clccActiveAnomalies, 1)
    }

    /// Repeated unanswered `CLCC active` snapshots must not wear the gate
    /// down; every one is counted and ignored.
    func testRepeatedCLCCActiveWithoutAnswerStaysIncoming() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.clip(number: "+8613"), now: t0.addingTimeInterval(1))
        for offset in stride(from: 2.0, through: 20.0, by: 2.0) {
            XCTAssertNil(machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(offset)))
            XCTAssertEqual(machine.phase, .incoming)
        }
        XCTAssertEqual(machine.clccActiveAnomalies, 10)
    }

    /// A stray `ATA OK` nobody requested must not unlock the gate either.
    func testATAAcceptedWithoutRequestIsIgnored() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        XCTAssertNil(machine.handle(.ataAccepted, now: t0.addingTimeInterval(1)))
        XCTAssertEqual(machine.phase, .incoming)
        XCTAssertNil(machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(2)))
        XCTAssertEqual(machine.phase, .incoming)
        XCTAssertEqual(machine.clccActiveAnomalies, 1)
    }

    /// Spec sequence 3: after a failed answer the intent resets, so a CLCC
    /// snapshot claiming active still cannot promote; only a full retry with
    /// accepted `ATA` unlocks the gate.
    func testATAFailureResetsIntentAndGateStaysClosed() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(1))
        _ = machine.handle(.ataAccepted, now: t0.addingTimeInterval(1.5))
        _ = machine.handle(.ataFailed, now: t0.addingTimeInterval(2))
        XCTAssertEqual(machine.phase, .incoming)
        XCTAssertNil(machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(3)))
        XCTAssertEqual(machine.phase, .incoming)
        // A real retry goes through.
        _ = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(4))
        _ = machine.handle(.ataAccepted, now: t0.addingTimeInterval(5))
        let active = machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(6))
        XCTAssertEqual(active?.to, .active)
    }

    /// CLCC active racing the in-flight `ATA` (intent requested, not yet
    /// accepted) stays in answering; once `ATA OK` lands the next snapshot
    /// promotes.
    func testCLCCActiveBeforeATAResultStaysAnswering() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(1))
        XCTAssertNil(machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(2)))
        XCTAssertEqual(machine.phase, .answering)
        XCTAssertEqual(machine.clccActiveAnomalies, 1)
        XCTAssertNil(machine.handle(.ataAccepted, now: t0.addingTimeInterval(3)))
        let active = machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(4))
        XCTAssertEqual(active?.to, .active)
    }

    /// A duplicate answer request is idempotent: one intent, one answering
    /// transition, no double-`ATA` unlocking.
    func testDuplicateAnswerRequestIsIdempotent() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        let first = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(1))
        XCTAssertEqual(first?.to, .answering)
        XCTAssertNil(machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(1.5)))
        XCTAssertEqual(machine.phase, .answering)
    }

    /// Every call gets a fresh epoch; the epoch survives the whole call and
    /// is what async results must bind to.
    func testEpochIncrementsPerCall() {
        var machine = CallStateMachine()
        XCTAssertEqual(machine.callEpoch, 0)
        _ = machine.handle(.ring, now: t0)
        let firstEpoch = machine.callEpoch
        XCTAssertEqual(firstEpoch, 1)
        _ = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(1))
        _ = machine.handle(.ataAccepted, now: t0.addingTimeInterval(2))
        _ = machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(3))
        XCTAssertEqual(machine.callEpoch, firstEpoch)
        _ = machine.handle(.hangUpRequested, now: t0.addingTimeInterval(4))
        _ = machine.handle(.hangUpAccepted, now: t0.addingTimeInterval(5))
        XCTAssertEqual(machine.callEpoch, firstEpoch)
        // Concluding resets the intent for this epoch's post-mortem status.
        _ = machine.handle(.tick, now: t0.addingTimeInterval(6 + 7))
        XCTAssertEqual(machine.phase, .idle)
        _ = machine.handle(.ring, now: t0.addingTimeInterval(14))
        XCTAssertEqual(machine.callEpoch, firstEpoch + 1)
    }

    /// Spec sequence 5: a call first seen as CLCC active with no prior
    /// RING/CLIP tracking is adopted as an externally connected call — a
    /// separate path that never relaxes the tracked-incoming gate.
    func testAdoptsExternallyActiveIncomingCall() {
        var machine = CallStateMachine()
        let adopted = machine.handle(.clcc([clcc(1, .incoming, .active, number: "+8613")]), now: t0)
        XCTAssertEqual(adopted?.from, .idle)
        XCTAssertEqual(adopted?.to, .active)
        XCTAssertTrue(machine.adoptedExternalCall)
        XCTAssertTrue(machine.status.isExternalAdoption)
        XCTAssertEqual(machine.clccActiveAnomalies, 0)
        // Staying active on the next snapshot requires no answer intent.
        XCTAssertNil(machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(1)))
        XCTAssertEqual(machine.phase, .active)
    }

    /// An externally adopted held call may resume active — the gate only
    /// covers tracked incoming/answering phases.
    func testAdoptedExternalHeldResumesActive() {
        var machine = CallStateMachine()
        let adopted = machine.handle(.clcc([clcc(1, .incoming, .held)]), now: t0)
        XCTAssertEqual(adopted?.to, .held)
        XCTAssertTrue(machine.adoptedExternalCall)
        let resumed = machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(1))
        XCTAssertEqual(resumed?.to, .active)
        XCTAssertEqual(machine.clccActiveAnomalies, 0)
    }

    /// Once legitimately active through the full gate, repeated CLCC active
    /// snapshots are stable no-ops.
    func testAnsweredActiveStaysActiveAcrossRepeatedCLCC() {
        var machine = CallStateMachine()
        _ = machine.handle(.ring, now: t0)
        _ = machine.handle(.userAnswerRequested, now: t0.addingTimeInterval(1))
        _ = machine.handle(.ataAccepted, now: t0.addingTimeInterval(2))
        _ = machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(3))
        for offset in stride(from: 4.0, through: 10.0, by: 2.0) {
            XCTAssertNil(machine.handle(.clcc([clcc(1, .incoming, .active)]), now: t0.addingTimeInterval(offset)))
            XCTAssertEqual(machine.phase, .active)
        }
    }
}
