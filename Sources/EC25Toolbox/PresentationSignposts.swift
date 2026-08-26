import Foundation
import os

/// Signpost points for the popover presentation path (R9; R13 keeps the
/// click/prepare/didShow/first-frame points and drops the content-driven
/// resize instrumentation together with the sizing machinery). Instruments'
/// os_signpost list shows the click→prepare→show→first-frame timeline so
/// warm/cold open latency stays attributable to a concrete stage.
enum PresentationSignpost {
    static let signposter = OSSignposter(
        subsystem: "ing.fuyaoskyrocket.ec25toolbox",
        category: "popover-presentation"
    )

    static func statusItemClick() {
        signposter.emitEvent("statusItemClick")
    }

    static func prepareBegin() -> OSSignpostIntervalState {
        signposter.beginInterval("preparePopoverForPresentation")
    }

    static func prepareEnd(_ state: OSSignpostIntervalState) {
        signposter.endInterval("preparePopoverForPresentation", state)
    }

    static func popoverDidShow() {
        signposter.emitEvent("popoverDidShow")
    }

    static func swiftuiFirstFrame(generation: Int) {
        signposter.emitEvent("swiftuiFirstFrame", "generation \(generation)")
    }
}
