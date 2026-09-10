import ActaKit
import Foundation

/// Holds the Mac's default input on the user's priority list, for as long as it is enabled.
///
/// **Why this is a policy and not a classifier.** The public HAL callback carries no originator and no
/// "the user did this" flag, and the flip after a headset connects was measured to be unordered
/// relative to the device's appearance at 0.4 s resolution. So intent is not recoverable: Acta cannot
/// tell the user reaching for System Settings from macOS helpfully switching to a headset. What is left
/// is choosing a behaviour that **cannot loop** — enforce, verify, and stop fighting after a bounded
/// number of reversals (`ConflictBudget`).
///
/// **The invariants, each of which has a test:**
///
/// - **Serialized.** One reconciliation pass at a time. Triggers arriving during a pass are coalesced
///   into the next one; the driver loop, not the caller, decides when to run.
/// - **Never diff winners.** The chosen device staying the same across two passes says nothing: the
///   built-in microphone can remain the winner throughout a headset connection while the *actual*
///   default moves. Every comparison is against a default read from the OS in this pass.
/// - **Re-read, write only on mismatch, verify after.** Which is also what makes the notification
///   caused by Acta's own successful write a no-op instead of the first step of a loop.
/// - **Absence is proved, never inferred.** An override is retired only on `.absent` — a device missing
///   from an incomplete snapshot is `.unknown`, and a fallback selection is not evidence that anything
///   left. `MicrophonePolicy.select` takes no completeness input by design, so this check is the
///   caller's and must be repeated at every consumer that acts on loss.
/// - **Nothing destructive on failure.** An enumeration failure, a failed read, or a lost subscription
///   leaves the priority list and the override exactly as they were. "I could not look" is not "your
///   devices went away".
///
/// Time comes from `SelfCheckClock` — the same seam, for the same reason: the verification deadline and
/// the conflict window are both *read* from the clock, so a seam that only replaced sleeping would look
/// like it worked and prove nothing.
public actor MicrophoneReconciler {
    /// Everything that must cause a reconciliation.
    ///
    /// ⚠️ **Two of these have no HAL notification behind them at all** — `preferenceEdited` and
    /// `useNow`. A reconciler wired only to device notifications does nothing when the user edits the
    /// list, which is the moment they are most certainly watching. The enum exists so that list is
    /// visible in the code rather than implied by which methods happen to call `schedule`.
    public enum Trigger: Equatable, Sendable {
        case enabled
        case resumed
        case wake
        case deviceListChanged
        case defaultInputChanged
        case readinessChanged(uid: String)
        case preferenceEdited
        case useNow
        case overrideCleared
    }

    private let directory: any AudioDeviceDirectory
    private let clock: any SelfCheckClock

    private var priorityStorage: MicrophonePriority
    private var enabled = false
    private var paused = false
    private var budget = ConflictBudget()

    /// The uid of the device Acta most recently **verified** into the system default. It is the
    /// precondition for calling a mismatch a reversal: a fight requires that Acta's write visibly won
    /// at least once, and a write that never took effect established nothing to reverse.
    private var lastEnforced: String?

    private var observation: (any AudioDeviceObservation)?
    private var observationDegraded: String?

    /// The system default as last actually read from the OS.
    ///
    /// ⚠️ **Kept apart from `published`, deliberately.** Mutating the published value in place to
    /// record a read would corrupt the dedupe memory: `publish` suppresses a state equal to the last
    /// one, so a silent edit can make a later, genuine emission look like a repeat and vanish.
    private var lastReadDefault: String?

    /// Bumped by every state change a caller makes — enable, disable, pause, resume, a preference edit,
    /// *Use now*. A pass captures it before its first suspension and compares afterwards: a completion
    /// that comes back into a changed world publishes nothing and takes no follow-up action.
    private var generation: UInt64 = 0

    private var published: MicrophoneEnforcementState = .disabled
    private var continuations: [UUID: AsyncStream<MicrophoneEnforcementState>.Continuation] = [:]

    private var pendingTriggers: [Trigger] = []
    private var isRunning = false
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    /// Notifications that have been *received* but not yet turned into a trigger.
    ///
    /// ⚠️ **A directory handler is synchronous and this is an actor, so the hop between them is a real
    /// gap** — the handler can only start a `Task`, and when it returns the actor has not seen anything
    /// yet. Without this counter `waitForQuiescence()` would answer "idle" for a change that is
    /// certainly coming, and every notification-driven test would be a race dressed up as a pass. The
    /// counter is bumped **inside the handler, before the hop**, which is the only place where "a change
    /// has been delivered" is a fact rather than a hope.
    private nonisolated let inflightDeliveries = DeliveryCounter()

    /// A counter the synchronous directory handler can touch. Not the actor's state, on purpose: actor
    /// state cannot be reached without an await, which is exactly what the handler cannot do.
    private final class DeliveryCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func decrement() { lock.lock(); value -= 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// The uid set of the last **complete** snapshot, and the departures observed since the last pass
    /// consumed them.
    ///
    /// ⚠️ **This pair is what stops coalescing from eating a disconnect.** The sequence that breaks a
    /// snapshot-only reconciler: *override on X → X disappears → X reconnects with the same UID →
    /// coalescing delivers only the final snapshot, which contains X.* The override should have expired
    /// on the disappearance and instead stays alive forever. So a device-list notification arriving
    /// while a pass is already running takes its own snapshot, and the departure it reveals is
    /// remembered until a pass consumes it.
    ///
    /// ⚠️ **Stated detection limit:** if a device leaves and returns with **no notification delivered in
    /// between** — a coalescing that happens inside the HAL, or a subscription that was not yet
    /// installed — nothing here can see it, and the override survives. That is not handled; it is
    /// bounded by the fact that the override also expires on explicit resume.
    private var lastCompleteUIDs: Set<String>?
    private var observedRemovals: Set<String> = []

    public init(directory: any AudioDeviceDirectory,
                clock: any SelfCheckClock = SystemClock(),
                priority: MicrophonePriority = .empty) {
        self.directory = directory
        self.clock = clock
        priorityStorage = priority
    }

    // MARK: - State

    public var state: MicrophoneEnforcementState { published }
    public var priority: MicrophonePriority { priorityStorage }
    public var isEnabled: Bool { enabled }
    public var isPaused: Bool { paused }

    /// A stream of enforcement states: the current one first, then every distinct one after it.
    ///
    /// Registration and replay happen inside the same actor turn, so there is no fetch-then-subscribe
    /// gap — the same guarantee `ControlAPI.states()` makes, for the same reason.
    public func states() -> AsyncStream<MicrophoneEnforcementState> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(published)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropContinuation(id) }
            }
        }
    }

    private func dropContinuation(_ id: UUID) { continuations[id] = nil }

    // MARK: - Commands

    /// Turn enforcement on: subscribe, reset the conflict budget, and reconcile immediately.
    public func enable() async {
        generation &+= 1
        enabled = true
        paused = false
        budget.reset()
        subscribeIfNeeded()
        await schedule(.enabled)
    }

    /// Turn enforcement off.
    ///
    /// ⚠️ **No compensating write.** Whatever the default input is at this moment stays; Acta stops
    /// managing it. Restoring "what it was before Acta started" would be a write the user never asked
    /// for, issued at the exact moment they said stop.
    public func disable() async {
        generation &+= 1
        enabled = false
        paused = false
        observation?.cancel()
        observation = nil
        observationDegraded = nil
        lastEnforced = nil
        pendingTriggers.removeAll()
        publish(.disabled)
    }

    /// Suspend enforcement without unsubscribing.
    ///
    /// The subscription stays so the *actual* default remains observable while paused — the menu must be
    /// able to show what the system default is even when Acta is not holding it. Like `disable()`, this
    /// issues no compensating write.
    public func pause() async {
        generation &+= 1
        paused = true
        publish(.paused, preferred: published.preferred, actual: lastReadDefault)
    }

    /// Explicit resume: clears the conflict budget's latch as well as the pause.
    public func resume() async {
        generation &+= 1
        paused = false
        budget.reset()
        await schedule(.resumed)
    }

    /// Replace the ordered priority list.
    ///
    /// ⚠️ Takes the order alone, never a whole `MicrophonePriority`, so that no caller can promote a
    /// *Use now* into the persistent list by handing back the value it read. Borrowing a headset for one
    /// call is not a preference change.
    public func setOrder(_ order: [String]) async {
        generation &+= 1
        priorityStorage.order = order
        await schedule(.preferenceEdited)
    }

    /// *Use now*: a temporary override that outranks the list until its device disconnects or the user
    /// resumes automatic selection.
    public func useNow(uid: String) async {
        generation &+= 1
        priorityStorage.override = uid
        await schedule(.useNow)
    }

    /// Retire the temporary override and go back to the list.
    public func resumeAutomaticSelection() async {
        generation &+= 1
        priorityStorage.override = nil
        await schedule(.overrideCleared)
    }

    /// Reconcile after the machine wakes. Nothing about wake is special here — it is on the trigger list
    /// because sleep is the one gap during which the world changes with no notification delivered.
    public func wake() async { await schedule(.wake) }

    /// Returns once no pass is running and none is pending. Test-facing; production has no reason to
    /// wait, and using it to sequence production work would serialize the app behind the HAL.
    func waitForQuiescence() async {
        guard !isQuiescent else { return }
        await withCheckedContinuation { quiescenceWaiters.append($0) }
    }

    private var isQuiescent: Bool {
        !isRunning && pendingTriggers.isEmpty && inflightDeliveries.count == 0
    }

    private func wakeQuiescenceWaitersIfIdle() {
        guard isQuiescent else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Observation

    private func subscribeIfNeeded() {
        guard observation == nil else { return }
        switch directory.observe({ [weak self] change in
            guard let self else { return }
            // Counted here, synchronously, so the change is already visible to `waitForQuiescence()`
            // before this handler returns — see `inflightDeliveries`.
            inflightDeliveries.increment()
            Task { await self.handle(change) }
        }) {
        case .observing(let subscription):
            observation = subscription
            observationDegraded = nil
        case .failed(let reason):
            // ⚠️ The third outcome, and the one that hides: a directory that registered nothing looks
            // exactly like a quiet machine. Enforcement continues — the other triggers still fire — but
            // the state says out loud that changes will be missed.
            observation = nil
            observationDegraded = reason
        }
    }

    private func handle(_ change: DeviceChange) async {
        defer {
            inflightDeliveries.decrement()
            wakeQuiescenceWaitersIfIdle()
        }
        switch change {
        case .deviceListChanged:
            await schedule(.deviceListChanged)
        case .defaultInputChanged:
            await schedule(.defaultInputChanged)
        case .readinessChanged(let uid):
            await schedule(.readinessChanged(uid: uid))
        case .observationDegraded(let reason):
            observationDegraded = reason
            await schedule(.deviceListChanged)
        }
    }

    // MARK: - The driver loop

    private func schedule(_ trigger: Trigger) async {
        // A device-list change arriving while a pass is running is the one that coalescing would eat.
        // Take its snapshot now, so the departure it carries survives into the next pass.
        if trigger == .deviceListChanged, isRunning {
            noteSnapshot(directory.enumerateInputDevices())
        }
        pendingTriggers.append(trigger)
        guard !isRunning else { return }

        isRunning = true
        while !pendingTriggers.isEmpty {
            let batch = pendingTriggers
            pendingTriggers.removeAll()
            await runPass(triggers: batch)
        }
        isRunning = false
        wakeQuiescenceWaitersIfIdle()
    }

    // MARK: - One reconciliation pass

    private func runPass(triggers: [Trigger]) async {
        guard enabled else { publish(.disabled); return }
        // ⚠️ Retried on every pass, not only at `enable()`. A registration that failed once must not
        // leave the reconciler permanently blind: the failure is usually about the state the HAL was in,
        // and a directory that registered nothing looks exactly like a quiet machine forever after.
        subscribeIfNeeded()
        budget.refresh(at: clock.now)
        if paused { publish(.paused, preferred: published.preferred, actual: lastReadDefault); return }
        if budget.isSuspended {
            publish(.suspended(conflicts: budget.suspendedAfter),
                    preferred: published.preferred, actual: lastReadDefault)
            return
        }

        let generationAtStart = generation

        let enumeration = directory.enumerateInputDevices()
        noteSnapshot(enumeration)
        guard case .devices(let devices, let uninspectable) = enumeration else {
            if case .failed(let reason) = enumeration { publish(.degraded(reason: reason)) }
            return
        }
        let removals = observedRemovals
        observedRemovals.removeAll()
        expireOverride(devices: devices, snapshotComplete: uninspectable.isEmpty, removals: removals)

        // ⚠️ Refusals are per **pass**, never persisted. A device the OS rejected once must be tried
        // again the next time something changes: the rejection may have been about the state the machine
        // was in, and a permanent blacklist would quietly retire a working microphone forever.
        var refused: Set<String> = []
        // Bounded by the device count: every iteration adds one uid to `refused`, and `select` returns
        // `.allPreferredCandidatesRefused` once they are all in it. The bound is belt and braces.
        for _ in 0...devices.count {
            let selection = MicrophonePolicy.select(from: devices,
                                                    priority: priorityStorage,
                                                    purpose: .systemDefault,
                                                    refused: refused)
            switch selection {
            case .noEligibleDevice:
                publish(.noEligibleDevice, preferred: nil, actual: lastReadDefault)
                return
            case .noPreferredDeviceAvailable:
                publish(.waitingForPreferredDevice, preferred: nil, actual: lastReadDefault)
                return
            case .allPreferredCandidatesRefused(let uids):
                // ⚠️ Carried through as its own status rather than folded into waiting: the device is
                // plugged in and the OS is saying no, which is the one state that should raise an alarm.
                publish(.writesRefused(uids: uids), preferred: uids.first, actual: lastReadDefault)
                return
            case .selected(let device):
                switch await enforce(device.uid, generationAtStart: generationAtStart) {
                case .settled:
                    return
                case .tryNext:
                    refused.insert(device.uid)
                case .abandoned:
                    return
                }
            }
        }
    }

    private enum Attempt { case settled, tryNext, abandoned }

    /// Re-read, write only on a mismatch, verify, and decide what the outcome means.
    private func enforce(_ uid: String, generationAtStart: UInt64) async -> Attempt {
        // Never diff winners: the comparison is always against a default read from the OS right now.
        switch directory.currentDefaultInput() {
        case .failed(let reason):
            publish(.degraded(reason: reason), preferred: uid, actual: lastReadDefault)
            return .abandoned
        case .device(let current) where current == uid:
            lastReadDefault = current
            // Already there — including when this pass was triggered by the notification from Acta's own
            // successful write. That is what keeps a write from being the first step of a loop.
            lastEnforced = uid
            publish(.enforcing(uid: uid), preferred: uid, actual: uid)
            return .settled
        case .device(let current):
            if lastEnforced == uid, budget.recordConflict(at: clock.now) {
                // Acta had already put this device there and something moved it, three times inside the
                // window. Stop fighting rather than ping-pong with whatever is on the other side.
                publish(.suspended(conflicts: budget.suspendedAfter), preferred: uid, actual: current)
                return .abandoned
            }
            lastReadDefault = current
        case .none:
            lastReadDefault = nil
        }

        switch directory.setDefaultInput(uid: uid) {
        case .unknownDevice, .failed:
            return .tryNext
        case .written:
            break
        }

        let verdict = await verify(target: uid)

        // ⚠️ The stale-completion rule, stated as what is actually achievable: a late completion cannot
        // un-issue an OS write, so the requirement is that it produces **no follow-up action** and **no
        // false success published**. A preference change that landed while this was in flight has
        // already queued its own pass, which reconciles the actual result against the new preference.
        guard generation == generationAtStart, enabled, !paused else { return .abandoned }

        switch verdict {
        case .converged:
            lastEnforced = uid
            publish(.enforcing(uid: uid), preferred: uid, actual: uid)
            return .settled
        case .readFailed(let reason):
            publish(.degraded(reason: reason), preferred: uid, actual: lastReadDefault)
            return .abandoned
        case .diverged:
            // ⚠️ A write that reported success and never took effect is treated as a **refusal for this
            // pass**, not as a conflict. The conflict budget exists to end a ping-pong with a human, and
            // a ping-pong needs Acta's write to have visibly won at least once; this one never did.
            // Falling through to the next candidate is bounded, and the resulting status says the OS
            // refused rather than pretending the device is missing.
            return .tryNext
        }
    }

    private enum Verification { case converged, diverged, readFailed(String) }

    /// Give a successful write until `verificationDeadline` to actually become the default.
    ///
    /// ⚠️ **This bound is the whole distinction between delayed convergence and a fight.** The read
    /// immediately after a write can legitimately still show the previous device; a single read would
    /// call that a conflict and spend the budget on the OS being asynchronous.
    private func verify(target: String) async -> Verification {
        var elapsed = 0.0
        while true {
            switch directory.currentDefaultInput() {
            case .device(let uid) where uid == target:
                return .converged
            case .device(let uid):
                lastReadDefault = uid
            case .none:
                lastReadDefault = nil
            case .failed(let reason):
                return .readFailed(reason)
            }
            if elapsed >= MicrophoneEnforcementTuning.verificationDeadline { return .diverged }
            await clock.sleep(for: MicrophoneEnforcementTuning.verificationPollInterval)
            elapsed += MicrophoneEnforcementTuning.verificationPollInterval
        }
    }

    // MARK: - Presence and the override

    /// Record a snapshot, and remember any device that left since the last complete one.
    ///
    /// ⚠️ **Only a complete snapshot updates the baseline.** A device missing from a snapshot that
    /// admits it could not describe every driver has not been shown to be gone, and letting it set the
    /// baseline would manufacture a departure out of one unreadable device.
    private func noteSnapshot(_ enumeration: DeviceEnumeration) {
        guard case .devices(let devices, let uninspectable) = enumeration, uninspectable.isEmpty else { return }
        let present = Set(devices.map(\.uid))
        if let previous = lastCompleteUIDs {
            observedRemovals.formUnion(previous.subtracting(present))
        }
        lastCompleteUIDs = present
    }

    /// The override expires on its device's **disconnect** — never on a timer, and never by being
    /// promoted into the persistent list.
    private func expireOverride(devices: [AudioInputDevice], snapshotComplete: Bool, removals: Set<String>) {
        guard let override = priorityStorage.override else { return }
        if removals.contains(override) {
            // Seen to leave while a pass was running, even though it is back in this snapshot.
            priorityStorage.override = nil
            return
        }
        switch MicrophonePolicy.presence(of: override, in: devices, snapshotComplete: snapshotComplete) {
        case .absent:
            priorityStorage.override = nil
        case .present, .unknown:
            // ⚠️ `.unknown` deliberately keeps the override. An incomplete snapshot is not a disconnect,
            // and a fallback selection made from one is not evidence that anything left.
            break
        }
    }

    // MARK: - Publishing

    private func publish(_ status: MicrophoneEnforcementStatus,
                         preferred: String? = nil,
                         actual: String? = nil) {
        let next = MicrophoneEnforcementState(status: status,
                                              preferred: preferred,
                                              actualDefault: actual,
                                              observationDegraded: observationDegraded)
        guard next != published else { return }
        published = next
        for continuation in continuations.values { continuation.yield(next) }
    }
}
