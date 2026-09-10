import Foundation

/// The system default input **as Acta last observed it** — with the third answer that the plain
/// `String?` this replaced could not express.
///
/// ⚠️ **"There is no default input" and "I have not read the default" are different facts, and a
/// `nil` said both.** The first is a real state of a Mac with no input hardware; the second is Acta
/// having no idea, which is what a status line shows before the first read and after a failed one.
/// A menu that renders them identically tells the user their microphone vanished every time a query
/// failed — the same class of error as `DeviceEnumeration.failed` versus an empty list.
public enum ObservedDefaultInput: Equatable, Sendable {
    /// Never successfully read: the starting state, and what a failed read leaves behind **only when no
    /// read has ever succeeded**. ⚠️ A failed read after a successful one keeps the last device actually
    /// seen — the newer fact is "I could not look again", not "everything I knew is void".
    case unread
    /// The OS answered, and there is no default input device.
    case noDefault
    case device(uid: String)

    public var uid: String? {
        if case .device(let uid) = self { return uid }
        return nil
    }
}

/// Why enforcement suspended itself.
///
/// ⚠️ **Two causes, because sampling cannot establish intent and the code must not pretend it can.**
/// A reversal is a fact Acta can prove: it wrote a device, verified the OS agreed, and later found the
/// default somewhere else. A convergence failure proves only that a pass spent writes and achieved
/// nothing — the competitor may be a human in System Settings, or the OS may simply be refusing. Both
/// have to bound enforcement; only one of them is evidence of a fight.
public enum SuspensionCause: Equatable, Sendable {
    /// Acta's verified selection was displaced this many times inside the window.
    case repeatedReversals(Int)
    /// This many reconciliation passes **within the counting window** issued a write that did not end
    /// with the default on it. ⚠️ Not "in a row": the history is deliberately retained across a
    /// successful settlement, because a reset on settlement is exactly what a fast competitor could
    /// drive by letting one write through.
    case repeatedConvergenceFailures(Int)
}

/// What the enforcement of the Mac's default input is currently doing — the one value the menu renders
/// and the one thing tests assert against.
///
/// ⚠️ **The "not enforcing" answers are deliberately separate cases, not one.** "Your preferred
/// microphone is not plugged in", "this Mac has no usable input at all", "the OS is rejecting every
/// preferred device", "I cannot see well enough to act" and "you paused me" are five different
/// sentences to a user and five different next actions. Collapsing any pair produces the exact failure
/// this feature exists to avoid: a status that reads as ordinary waiting while something is wrong.
public enum MicrophoneEnforcementStatus: Equatable, Sendable {
    /// Feature (B) is off. Acta is not touching the system default at all.
    case disabled

    /// The system default input is the preferred device, verified by a read.
    case enforcing(uid: String)

    /// Usable devices exist; none of them is on the priority list. The system default is left alone.
    case waitingForPreferredDevice

    /// Nothing on this machine can be the system default input.
    case noEligibleDevice

    /// Every preferred device that is present had its write refused by the OS during this pass.
    /// ⚠️ Distinct from `waitingForPreferredDevice` — the device is *there* and the OS said no.
    case writesRefused(uids: [String])

    /// The snapshot could not describe the device Acta is currently holding, so **nothing was
    /// changed**.
    ///
    /// ⚠️ **This case exists because retiring a preference is not the only destructive act.** Keeping
    /// the stored pin while writing a *different* device into the system default switches the user's
    /// microphone on the strength of an absence that was never proved — the honest answer is to hold
    /// and say why.
    case uncertain(uid: String)

    /// The user paused enforcement. ⚠️ Pausing issues **no compensating write**: whatever the default
    /// is when Pause happens stays, because undoing a write the user may have wanted is not "stop".
    case paused

    /// Enforcement bounded itself — see `SuspensionCause`.
    case suspended(SuspensionCause)

    /// The OS refused to answer a question Acta needed answered (enumeration or the default-input read).
    /// ⚠️ Not "there are no devices" and not "the default is unset" — see `DeviceEnumeration`.
    case degraded(reason: String)
}

/// Everything the UI needs about enforcement, in one value.
///
/// `preferred` and `observedDefault` are **carried separately on purpose** (plan decision 6): System
/// Settings showing the right device does not prove Acta's own capture followed, and the reverse holds
/// too. A single "current microphone" field would make the two indistinguishable exactly when they
/// disagree, which is the only time anyone looks.
public struct MicrophoneEnforcementState: Equatable, Sendable {
    /// What enforcement is doing.
    public var status: MicrophoneEnforcementStatus
    /// The device the policy chose, if it chose one.
    public var preferred: String?
    /// The system default as last actually read from the OS.
    ///
    /// ⚠️ **Updated on every successful read, including the one that confirms a write converged, and
    /// including while paused or suspended.** Being told not to *act* is not being told not to *look*:
    /// a paused reconciler that stops reading shows the user a default that moved minutes ago.
    public var observedDefault: ObservedDefaultInput
    /// Set when change notification is only partially installed: the subscription is live but some
    /// transitions will never be reported. ⚠️ Carried even while the status is otherwise healthy,
    /// because that is precisely when it hides.
    public var observationDegraded: String?

    public init(status: MicrophoneEnforcementStatus,
                preferred: String? = nil,
                observedDefault: ObservedDefaultInput = .unread,
                observationDegraded: String? = nil) {
        self.status = status
        self.preferred = preferred
        self.observedDefault = observedDefault
        self.observationDegraded = observationDegraded
    }

    public static let disabled = MicrophoneEnforcementState(status: .disabled)
}

/// The enforcement constants, fixed here rather than at implementation time.
///
/// They live in `ActaKit` for the reason `SelfCheckTuning` does: a threshold written once in the
/// runtime and again in a test asserts only that the test agrees with itself. A test that must pin
/// "three reversals in a minute" reads it from here, and changing the number fails that test.
public enum MicrophoneEnforcementTuning {
    /// Setbacks of one kind within `conflictWindow` that trip suspension.
    public static let conflictsBeforeSuspension = 3

    /// The rolling window setbacks are counted over, in seconds.
    public static let conflictWindow: Double = 60

    /// How long after a successful write the default is given to become the written device.
    ///
    /// ⚠️ This bound is what separates **delayed convergence from a fight**. The read immediately after
    /// a write can legitimately still show the old device; treating that first stale read as a setback
    /// would spend the budget on the OS simply being asynchronous.
    public static let verificationDeadline: Double = 2

    /// How often the default is re-read while waiting for a write to converge.
    public static let verificationPollInterval: Double = 0.25

    /// After this much quiet, suspension lifts and the budget resets.
    ///
    /// ⚠️ **It lifts on the next trigger after the quiet period, not on a timer.** There is no wake-up
    /// scheduled for it: a suspended reconciler is deliberately doing nothing, and a timer whose only
    /// job is to resume a fight is worse than waiting for the next thing that happens on the machine.
    public static let quietResetInterval: Double = 300
}

/// One thing that went wrong while enforcing.
public enum EnforcementSetback: Equatable, Sendable {
    /// A verified selection was displaced. ⚠️ Charged **once per displacement**, not once per pass that
    /// can still see it: the displaced state persists until something fixes it, and re-charging it every
    /// time a correction fails would suspend on one event wearing three hats.
    case reversal
    /// A pass issued at least one write and ended with the default somewhere else.
    ///
    /// ⚠️ **This is the bound that "a reversal" alone cannot provide.** A competitor that restores its
    /// own choice faster than the verification read means Acta's write never visibly wins, so no
    /// reversal is ever provable — and a reconciler that only counts reversals writes forever, each
    /// write provoking the notification that starts the next pass. Bounding candidates *within* a pass
    /// is not bounding enforcement.
    case convergenceFailure
}

/// The budget that bounds enforcement: how much may go wrong before Acta stops writing.
///
/// Pure and in `ActaKit` because every interesting case is a sequence of timestamps — three setbacks
/// spanning 59 seconds versus 61, a suspension that outlives the counting window, a quiet period that
/// lifts it — and a live machine cannot be asked to produce any of them on demand.
///
/// ⚠️ **Suspension is a latch, not a count.** Pruning the rolling window would otherwise un-suspend by
/// itself sixty seconds later and put Acta straight back into what it just backed out of. The latch
/// clears on exactly three things: an explicit resume, a fresh enable, and `quietResetInterval` with no
/// setback. In particular **nothing a notification carries clears it** — including the notifications
/// Acta's own writes provoke, which would otherwise let a fast competitor reset the limit it exists to
/// impose.
public struct EnforcementBudget: Equatable, Sendable {
    private var reversals: [Double] = []
    private var convergenceFailures: [Double] = []
    private var lastSetbackAt: Double?
    private var cause: SuspensionCause?

    public init() {}

    /// Non-`nil` exactly while suspended, and it says why.
    public var suspension: SuspensionCause? { cause }
    public var isSuspended: Bool { cause != nil }

    /// Setbacks of each kind inside the current window, right now.
    public var reversalCount: Int { reversals.count }
    public var convergenceFailureCount: Int { convergenceFailures.count }

    /// Drop setbacks that have aged out, and lift suspension after a long enough quiet period.
    ///
    /// Call it at the top of every pass: it is where both time-based rules happen, and neither of them
    /// has a timer behind it.
    public mutating func refresh(at now: Double) {
        prune(at: now)
        if let last = lastSetbackAt, now - last >= MicrophoneEnforcementTuning.quietResetInterval {
            reset()
        }
    }

    /// Record one setback. Returns `true` if this is the one that trips suspension.
    @discardableResult
    public mutating func record(_ setback: EnforcementSetback, at now: Double) -> Bool {
        prune(at: now)
        lastSetbackAt = now
        switch setback {
        case .reversal:
            reversals.append(now)
            return trip(.repeatedReversals(reversals.count), reached: reversals.count)
        case .convergenceFailure:
            convergenceFailures.append(now)
            return trip(.repeatedConvergenceFailures(convergenceFailures.count),
                        reached: convergenceFailures.count)
        }
    }

    /// Explicit resume, or a fresh enable.
    public mutating func reset() {
        reversals.removeAll()
        convergenceFailures.removeAll()
        lastSetbackAt = nil
        cause = nil
    }

    private mutating func trip(_ newCause: SuspensionCause, reached count: Int) -> Bool {
        guard cause == nil, count >= MicrophoneEnforcementTuning.conflictsBeforeSuspension else {
            return false
        }
        // ⚠️ The cause is captured at the moment the latch trips and never recomputed. The rolling
        // window keeps draining underneath, so a suspended reconciler asked an hour later how many
        // setbacks it saw would answer "none" — a status line that contradicts itself.
        cause = newCause
        return true
    }

    private mutating func prune(at now: Double) {
        let window = MicrophoneEnforcementTuning.conflictWindow
        reversals.removeAll { now - $0 >= window }
        convergenceFailures.removeAll { now - $0 >= window }
    }
}
