import Foundation

/// What the enforcement of the Mac's default input is currently doing — the one value the menu renders
/// and the one thing tests assert against.
///
/// ⚠️ **The four "not enforcing" answers are deliberately four cases, not one.** "Your preferred
/// microphone is not plugged in", "this Mac has no usable input at all", "the OS is rejecting every
/// preferred device" and "you paused me" are four different sentences to a user and four different next
/// actions. Collapsing any pair of them produces the exact failure this feature exists to avoid: a
/// status that reads as ordinary waiting while something is actually wrong.
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

    /// The user paused enforcement. ⚠️ Pausing issues **no compensating write**: whatever the default
    /// is when Pause happens stays, because undoing a write the user may have wanted is not "stop".
    case paused

    /// The conflict budget tripped: something kept moving the default off the enforced device, and Acta
    /// stopped fighting rather than ping-ponging with it.
    case suspended(conflicts: Int)

    /// The OS refused to answer a question Acta needed answered (enumeration or the default-input read).
    /// ⚠️ Not "there are no devices" and not "the default is unset" — see `DeviceEnumeration`.
    case degraded(reason: String)
}

/// Everything the UI needs about enforcement, in one value.
///
/// `preferred` and `actualDefault` are **carried separately on purpose** (plan decision 6): System
/// Settings showing the right device does not prove Acta's own capture followed, and the reverse holds
/// too. A single "current microphone" field would make the two indistinguishable exactly when they
/// disagree, which is the only time anyone looks.
public struct MicrophoneEnforcementState: Equatable, Sendable {
    /// What enforcement is doing.
    public var status: MicrophoneEnforcementStatus
    /// The device the policy chose this pass, if it chose one.
    public var preferred: String?
    /// The system default as last actually read from the OS. `nil` means the OS answered "no default".
    public var actualDefault: String?
    /// Set when change notification is only partially installed: the subscription is live but some
    /// transitions will never be reported. ⚠️ Carried even while the status is otherwise healthy,
    /// because that is precisely when it hides.
    public var observationDegraded: String?

    public init(status: MicrophoneEnforcementStatus,
                preferred: String? = nil,
                actualDefault: String? = nil,
                observationDegraded: String? = nil) {
        self.status = status
        self.preferred = preferred
        self.actualDefault = actualDefault
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
    /// Reversals within `conflictWindow` that trip suspension.
    public static let conflictsBeforeSuspension = 3

    /// The rolling window reversals are counted over, in seconds.
    public static let conflictWindow: Double = 60

    /// How long after a successful write the default is given to become the written device.
    ///
    /// ⚠️ This bound is what separates **delayed convergence from a fight**. The read immediately after
    /// a write can legitimately still show the old device; treating that first stale read as a conflict
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

/// The conflict budget: how many times the default was moved off the device Acta had already put there.
///
/// Pure and in `ActaKit` because every interesting case is a sequence of timestamps — three reversals
/// spanning 59 seconds versus 61, a suspension that outlives the counting window, a quiet period that
/// lifts it — and a live machine cannot be asked to produce any of them on demand.
///
/// ⚠️ **Suspension is a latch, not a count.** Pruning the rolling window would otherwise un-suspend by
/// itself sixty seconds later and put Acta straight back into the ping-pong it just backed out of. The
/// latch clears on exactly three things: an explicit resume, a fresh enable, and `quietResetInterval`
/// with no conflict.
public struct ConflictBudget: Equatable, Sendable {
    private var conflicts: [Double] = []
    private var lastConflictAt: Double?
    private var suspended = false
    private var suspendedAfterCount = 0

    public init() {}

    /// Conflicts inside the current window, right now.
    public var conflictCount: Int { conflicts.count }

    /// How many conflicts had accumulated at the moment suspension tripped; `0` while not suspended.
    ///
    /// ⚠️ **This, not `conflictCount`, is what the status reports.** The rolling window keeps draining
    /// while suspension latches, so a suspended reconciler asked an hour later how many conflicts it saw
    /// would answer "none" — a status line that contradicts itself, and one no user could act on.
    public var suspendedAfter: Int { suspendedAfterCount }

    public var isSuspended: Bool { suspended }

    /// Drop conflicts that have aged out, and lift suspension after a long enough quiet period.
    ///
    /// Call it at the top of every pass: it is where both time-based rules happen, and neither of them
    /// has a timer behind it.
    public mutating func refresh(at now: Double) {
        conflicts.removeAll { now - $0 >= MicrophoneEnforcementTuning.conflictWindow }
        if let last = lastConflictAt, now - last >= MicrophoneEnforcementTuning.quietResetInterval {
            reset()
        }
    }

    /// Record one reversal. Returns `true` if this is the one that trips suspension.
    @discardableResult
    public mutating func recordConflict(at now: Double) -> Bool {
        conflicts.removeAll { now - $0 >= MicrophoneEnforcementTuning.conflictWindow }
        conflicts.append(now)
        lastConflictAt = now
        let tripped = !suspended && conflicts.count >= MicrophoneEnforcementTuning.conflictsBeforeSuspension
        if tripped {
            suspended = true
            suspendedAfterCount = conflicts.count
        }
        return tripped
    }

    /// Explicit resume, or a fresh enable.
    public mutating func reset() {
        conflicts.removeAll()
        lastConflictAt = nil
        suspended = false
        suspendedAfterCount = 0
    }
}
