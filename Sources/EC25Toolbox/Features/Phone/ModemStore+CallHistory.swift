import Foundation

/// SIM-scoped call-history persistence and missed-call acknowledgement.
extension ModemStore {
    /// Swaps visible history and recordings when EID/ICCID changes, so data
    /// from different cards or profiles never mixes.
    func reloadCallLogForCurrentScope() {
        let scope = currentSIMMessageScope()
        guard scope.id != callLogScope.id else { return }
        callLogScope = scope
        state.callLog = callLogStore.load(scope: scope)
        state.recordings = callRecordingStore.load(scope: scope)
    }

    func addCallEvent(title: String, detail: String, failed: Bool = false) {
        state.callLog.insert(
            CallEvent(
                title: title,
                detail: detail,
                failed: failed,
                moduleID: moduleIdentifier,
                moduleSerialNumber: moduleSerialNumber,
                moduleName: moduleDisplayName
            ),
            at: 0
        )
        if state.callLog.count > 30 {
            state.callLog.removeLast(state.callLog.count - 30)
        }
        callLogStore.replace(state.callLog, scope: callLogScope)
    }

    /// Clears the menu-bar missed-call badge only after history becomes
    /// visible. Records stay in the scoped call log.
    func acknowledgeMissedCalls() {
        let now = Date()
        var changed = false
        for index in state.callLog.indices where state.callLog[index].isUnacknowledgedMissedCall {
            state.callLog[index].acknowledgedAt = now
            changed = true
        }
        guard changed else { return }
        callLogStore.replace(state.callLog, scope: callLogScope)
    }
}
