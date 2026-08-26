import Foundation

/// Resolution state of one incoming caller's identity (R12).
enum CallerIdentityStatus: Equatable, Sendable {
    /// Inside the bounded RING→CLIP merge window; no number has arrived yet.
    /// Not yet "unknown" — the banner is deliberately held so the first
    /// notification can show the real number or contact name.
    case pending
    /// A caller number is known (CLIP- or CLCC-sourced).
    case resolved
    /// The network explicitly withheld the number (`+CLIP` with no usable
    /// number while a call rings). Distinct from "still merging".
    case withheld
}

/// Caller identity bound to exactly one call epoch (R12). Old epochs' CLIP,
/// CLCC, and contact-lookup results are dropped by the coordinator, so a
/// late answer from a previous call can never relabel a newer one.
struct IncomingCallerIdentity: Equatable, Sendable {
    /// Where the caller number came from; `+CLIP` wins over `+CLCC`.
    enum NumberSource: Equatable, Sendable {
        case none
        case clip
        case clcc
    }

    var epoch: Int
    var status: CallerIdentityStatus = .pending
    /// The number exactly as the modem reported it.
    var rawNumber: String?
    /// `+`-and-digits normalization used for contact matching.
    var normalizedNumber: String?
    /// Contact display name once resolved from the in-memory snapshot.
    var displayName: String?
    var source: NumberSource = .none
    /// True once the bounded merge window expired without a number; only
    /// then may a banner say "unknown" instead of "resolving".
    var mergeWindowElapsed = false
    var updatedAt: Date?

    /// Records the caller number from CLIP or CLCC.
    mutating func resolve(number: String, source: NumberSource, at now: Date) {
        rawNumber = number
        normalizedNumber = Self.normalized(number)
        self.source = source
        status = .resolved
        mergeWindowElapsed = true
        updatedAt = now
    }

    /// Marks the network as explicitly withholding the number.
    mutating func markWithheld(at now: Date) {
        status = .withheld
        rawNumber = nil
        normalizedNumber = nil
        mergeWindowElapsed = true
        updatedAt = now
    }

    /// Keeps `+` and digits only, matching `PhoneNumberMatcher`'s dialing
    /// conventions well enough for suffix-based contact lookups.
    static func normalized(_ number: String) -> String {
        String(number.filter { $0 == "+" || $0.isNumber })
    }
}

/// The single display derivator for caller identity (R12): notification
/// banner, call surface, phone status text, and call-history rows all pass
/// their localized strings through here so the fallback chain — contact name
/// + number, number, withheld, unknown — can never diverge between surfaces.
enum CallerIdentityDerivator {
    struct Display: Equatable, Sendable {
        /// Primary line: contact name, number, withheld or unknown text.
        var title: String
        /// The raw number under a contact name, when both are known.
        var subtitle: String?
        var isPending = false
        var isWithheld = false
        var isUnknown = false

        /// Redacted timeline token; never contains names or numbers.
        var timelineToken: String {
            if isPending { return "identity=pending" }
            if isWithheld { return "identity=withheld" }
            if isUnknown { return "identity=unknown" }
            return subtitle == nil ? "identity=number" : "identity=contact"
        }
    }

    static func display(
        identity: IncomingCallerIdentity?,
        pendingText: String,
        unknownText: String,
        withheldText: String
    ) -> Display {
        guard let identity else {
            return Display(title: unknownText, subtitle: nil, isUnknown: true)
        }
        switch identity.status {
        case .resolved:
            let displayedNumber = PhoneNumberDisplay.internationalized(identity.rawNumber)
            if let name = identity.displayName, !name.isEmpty {
                return Display(title: name, subtitle: displayedNumber)
            }
            if let number = displayedNumber, !number.isEmpty {
                return Display(title: number, subtitle: nil)
            }
            return Display(title: unknownText, subtitle: nil, isUnknown: true)
        case .withheld:
            return Display(title: withheldText, subtitle: nil, isWithheld: true)
        case .pending:
            return identity.mergeWindowElapsed
                ? Display(title: unknownText, subtitle: nil, isUnknown: true)
                : Display(title: pendingText, subtitle: nil, isPending: true)
        }
    }

    /// Same priority chain for a bare number + optional contact name; used
    /// by call-history rows and outgoing calls that have no tracked identity.
    static func display(number: String?, contactName: String?, unknownText: String) -> Display {
        let displayedNumber = PhoneNumberDisplay.internationalized(number)
        if let contactName, !contactName.isEmpty {
            return Display(title: contactName, subtitle: displayedNumber)
        }
        if let number = displayedNumber, !number.isEmpty {
            return Display(title: number, subtitle: nil)
        }
        return Display(title: unknownText, subtitle: nil, isUnknown: true)
    }
}

/// Pure-value coordinator for the bounded RING→CLIP identity merge window
/// and same-identifier banner replacement (R12). Timing decisions are made
/// from injected clocks so every sequence — CLIP at 50/300/700 ms, CLCC
/// fallback, late contacts, stale epochs — is unit-testable.
struct IncomingCallIdentityCoordinator: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case none
        /// A bare RING started a call; hold the first banner until `until`
        /// so +CLIP can enrich it before it is ever shown.
        case holdBanner(until: Date)
        /// Post the first banner for this epoch now.
        case postBanner
        /// Replace the already-posted banner's content in place (same
        /// request identifier, same category and actions).
        case replaceBanner
    }

    private(set) var identity: IncomingCallerIdentity?
    /// True while this epoch's banner is on the notification center.
    private(set) var bannerPosted = false
    /// High-water mark of concluded epochs; events at or below it are dead.
    private var lastConcludedEpoch = 0

    /// A call began (or re-entered `.incoming`) with an optional
    /// already-known number. Idempotent per epoch; re-entry after a retracted
    /// banner (failed answer, call still ringing) re-posts or re-arms.
    mutating func incomingBegan(
        epoch: Int,
        number: String?,
        at now: Date,
        mergeWindow: TimeInterval
    ) -> Decision {
        if let identity, identity.epoch == epoch {
            guard !bannerPosted else { return .none }
            if identity.status == .pending, !identity.mergeWindowElapsed {
                return .holdBanner(until: now.addingTimeInterval(mergeWindow))
            }
            bannerPosted = true
            return .postBanner
        }
        var newIdentity = IncomingCallerIdentity(epoch: epoch)
        bannerPosted = false
        if let number, !number.isEmpty {
            newIdentity.resolve(number: number, source: .none, at: now)
            identity = newIdentity
            bannerPosted = true
            return .postBanner
        }
        identity = newIdentity
        return .holdBanner(until: now.addingTimeInterval(mergeWindow))
    }

    /// `+CLIP` arrived for the epoch. A nil/empty number means the network
    /// explicitly withheld the caller's identity. Wrong-epoch results are
    /// dropped.
    mutating func clipArrived(number: String?, epoch: Int, at now: Date) -> Decision {
        guard seedIfNeeded(epoch: epoch) else { return .none }
        guard identity?.status != .resolved else { return .none }
        if let number, !number.isEmpty {
            identity?.resolve(number: number, source: .clip, at: now)
        } else {
            identity?.markWithheld(at: now)
        }
        return emitBannerDecision()
    }

    /// A matching-direction `AT+CLCC` entry supplied the caller number after
    /// CLIP never arrived (fallback source; CLIP keeps priority).
    mutating func clccNumber(number: String, epoch: Int, at now: Date) -> Decision {
        guard seedIfNeeded(epoch: epoch) else { return .none }
        guard identity?.status != .resolved else { return .none }
        identity?.resolve(number: number, source: .clcc, at: now)
        return emitBannerDecision()
    }

    /// The async contact lookup completed. Only a real name replaces the
    /// banner; a miss keeps the number.
    mutating func contactResolved(name: String?, epoch: Int, at now: Date) -> Decision {
        guard identity?.epoch == epoch else { return .none }
        guard let name, !name.isEmpty, identity?.displayName != name else { return .none }
        identity?.displayName = name
        identity?.updatedAt = now
        return emitBannerDecision()
    }

    /// The bounded merge window expired with no number: the banner may now
    /// show the explicit unknown text.
    mutating func mergeWindowExpired(epoch: Int, at now: Date) -> Decision {
        guard identity?.epoch == epoch,
              identity?.status == .pending,
              identity?.mergeWindowElapsed != true
        else { return .none }
        identity?.mergeWindowElapsed = true
        identity?.updatedAt = now
        bannerPosted = true
        return .postBanner
    }

    /// The banner for this epoch was retracted (user accepted/declined, call
    /// ended, or epoch superseded). Allows a same-epoch re-post later.
    mutating func bannerRetracted(epoch: Int) {
        guard identity?.epoch == epoch else { return }
        bannerPosted = false
    }

    /// The epoch concluded; its identity is dropped so late CLIP/CLCC or
    /// contact results for it can never reach a newer call.
    mutating func callEnded(epoch: Int) {
        lastConcludedEpoch = max(lastConcludedEpoch, epoch)
        guard identity?.epoch == epoch else { return }
        identity = nil
        bannerPosted = false
    }

    /// Seeds a fresh identity for epochs the coordinator has not seen (CLIP
    /// arriving before any RING, or a CLCC adopt). Returns false when the
    /// event belongs to a stale or already-concluded epoch.
    private mutating func seedIfNeeded(epoch: Int) -> Bool {
        if let identity, identity.epoch == epoch { return true }
        guard epoch > lastConcludedEpoch,
              identity == nil || identity!.epoch < epoch
        else { return false }
        identity = IncomingCallerIdentity(epoch: epoch)
        bannerPosted = false
        return true
    }

    private mutating func emitBannerDecision() -> Decision {
        if bannerPosted {
            return .replaceBanner
        }
        bannerPosted = true
        return .postBanner
    }
}
