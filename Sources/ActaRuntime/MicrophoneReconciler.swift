import ActaKit
import Foundation

/// Holds the Mac's default input on the user's priority list, for as long as it is enabled.
///
/// **Why this is a policy and not a classifier.** The public HAL callback carries no originator and no
/// "the user did this" flag, and the flip after a headset connects was measured to be unordered
/// relative to the device's appearance at 0.4 s resolution. So intent is not recoverable: Acta cannot
/// tell the user reaching for System Settings from macOS helpfully switching to a headset. What is left
/// is choosing a behaviour that **cannot loop** (`EnforcementBudget`).
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
/// - **Bounded across passes, not only within one.** Candidates are bounded inside a pass by the device
///   count, and that is *not* enough: a competitor that restores its choice faster than the
///   verification read means no reversal is ever provable, and a reconciler counting only reversals
///   writes forever. See `EnforcementSetback.convergenceFailure`.
/// - **Absence is proved, never inferred, and that binds writes as well as preferences.** An override
///   is retired only on `.absent`; and while the device Acta is holding is merely *unaccounted for*
///   (`.unknown`), no other device is written either — keeping the stored pin while switching the
///   system input away from it is the same unproven conclusion with a friendlier face.
/// - **Observation is not permission to enforce.** Paused, suspended and waiting all keep reading the
///   world and publishing what they see; only writing stops.
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

    // ⚠️ `nonisolated` because the directory's change handler is **synchronous and off the actor**, and
    // it has real work to do there — see `ObservationInbox`. A handler that could only hop to the actor
    // could not observe anything at the moment it was told to.
    private nonisolated let directory: any AudioDeviceDirectory
    private nonisolated let clock: any SelfCheckClock
    private nonisolated let inbox = ObservationInbox()

    private var priorityStorage: MicrophonePriority
    private var enabled = false
    private var paused = false
    private var budget = EnforcementBudget()

    /// A **consumable** token: set when a write is verified, cleared the moment a displacement is
    /// charged against it.
    ///
    /// ⚠️ **Consumable is the whole point, and a persistent "last device I enforced" is the bug it
    /// replaces.** A displacement is one event; the displaced *state* persists until something fixes
    /// it. Charging a reversal on every pass that can still see that state turns one headset connection
    /// into three reversals and suspends on a fight that never happened. It rearms only on the next
    /// verified settlement.
    private var enforcedAndUnchallenged: String?

    /// The last device a write was verified onto, **not** consumed by anything. This is what
    /// `.uncertain` protects: the selection Acta is currently holding, which must not be abandoned on
    /// the strength of a snapshot that could not describe it.
    private var confirmedSelection: String?

    private var observation: (any AudioDeviceObservation)?
    private var observationDegraded: String?

    /// The system default as last actually read. Kept apart from `published` deliberately: mutating the
    /// published value in place to record a read would corrupt the dedupe memory, so a later genuine
    /// emission could look like a repeat and vanish.
    private var observedDefault: ObservedDefaultInput = .unread

    /// Bumped by every state change a caller makes — enable, disable, pause, resume, a preference edit,
    /// *Use now*. A pass captures it before its first suspension and compares afterwards: a completion
    /// that comes back into a changed world publishes nothing and takes no follow-up action.
    private var generation: UInt64 = 0

    private var published: MicrophoneEnforcementState = .disabled
    private var continuations: [UUID: AsyncStream<MicrophoneEnforcementState>.Continuation] = [:]

    private var pendingTriggers: [Trigger] = []
    private var isRunning = false
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    /// The uid set of the last **complete** snapshot, and every departure observed since a pass consumed
    /// them — each tagged with the sequence number of the observation that revealed it.
    ///
    /// ⚠️ **The sequence number is what stops a stale departure from retiring a fresh *Use now*.** A
    /// removal seen before the user clicked describes a world that predates their choice, and applying
    /// it afterwards would expire the override they just made.
    private var lastCompleteUIDs: Set<String>?
    private var observedRemovals: [(seq: UInt64, uid: String)] = []
    /// The sequence number in force when the current override was set. Removals at or below it are
    /// history, not evidence.
    private var overrideSetAtSeq: UInt64 = 0

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

    /// Turn enforcement on: subscribe, reset the budget, and reconcile immediately.
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
        enforcedAndUnchallenged = nil
        confirmedSelection = nil
        // Nothing is being read any more, so claiming to know the default would be a stale assertion.
        observedDefault = .unread
        pendingTriggers.removeAll()
        publish(.disabled)
    }

    /// Suspend *writing* without unsubscribing.
    ///
    /// The subscription stays so the actual default remains observable while paused — the menu must be
    /// able to show what the system default is even when Acta is not holding it. Like `disable()`, this
    /// issues no compensating write, and the pass it schedules reads the world without touching it.
    public func pause() async {
        generation &+= 1
        paused = true
        // Published straight away: the user clicked, and the answer must not wait on a pass. The pass
        // scheduled below then re-reads the world, because pausing withdraws permission to write and
        // nothing else.
        publish(.paused, preferred: published.preferred)
        await schedule(.wake)
    }

    /// Explicit resume: clears the budget's latch as well as the pause.
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
        // Everything observed up to now happened before the user made this choice.
        overrideSetAtSeq = inbox.highWaterMark
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

    /// Returns once no pass is running, none is pending, and no delivered observation is unconsumed.
    /// Test-facing; production has no reason to wait, and using it to sequence production work would
    /// serialize the app behind the HAL.
    func waitForQuiescence() async {
        guard !isQuiescent else { return }
        await withCheckedContinuation { quiescenceWaiters.append($0) }
    }

    private var isQuiescent: Bool { !isRunning && pendingTriggers.isEmpty && inbox.isEmpty }

    private func wakeQuiescenceWaitersIfIdle() {
        guard isQuiescent else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Observation

    private func subscribeIfNeeded() {
        guard observation == nil else { return }
        let outcome = directory.observe { [weak self] change in
            guard let self else { return }
            // ⚠️ **The snapshot is taken HERE, in the delivery, and not after the hop to the actor.**
            // The actor may be busy for an arbitrary interval, and a device that leaves and returns
            // inside that interval is simply present again by the time the actor looks — so a departure
            // that really was reported becomes invisible, and an override the user is no longer wearing
            // survives forever. Enumerating on the delivery is the only place where "what the machine
            // looked like when it said something changed" is still knowable. It is safe:
            // `enumerateInputDevices()` takes no lock of ours and no queue of the directory's.
            let snapshot: DeviceEnumeration? = change == .deviceListChanged
                ? self.directory.enumerateInputDevices()
                : nil
            self.inbox.append(change: change, snapshot: snapshot)
            Task { await self.drainInbox() }
        }
        switch outcome {
        case .observing(let subscription):
            observation = subscription
            observationDegraded = nil
        case .failed(let reason):
            // ⚠️ The third outcome, and the one that hides: a directory that registered nothing looks
            // exactly like a quiet machine. Enforcement continues — the other triggers still fire — and
            // every pass retries the registration.
            observation = nil
            observationDegraded = reason
        }
    }

    /// Consume delivered observations **in arrival order**, whatever order their tasks happen to run in.
    private func drainInbox() async {
        let items = inbox.drain()
        guard !items.isEmpty else { wakeQuiescenceWaitersIfIdle(); return }
        for item in items {
            if let snapshot = item.snapshot { noteSnapshot(snapshot, seq: item.seq) }
            switch item.change {
            case .deviceListChanged:
                pendingTriggers.append(.deviceListChanged)
            case .defaultInputChanged:
                pendingTriggers.append(.defaultInputChanged)
            case .readinessChanged(let uid):
                pendingTriggers.append(.readinessChanged(uid: uid))
            case .observationDegraded(let reason):
                observationDegraded = reason
                pendingTriggers.append(.deviceListChanged)
            }
        }
        await runDriver()
        wakeQuiescenceWaitersIfIdle()
    }

    // MARK: - The driver loop

    private func schedule(_ trigger: Trigger) async {
        pendingTriggers.append(trigger)
        await runDriver()
        wakeQuiescenceWaitersIfIdle()
    }

    private func runDriver() async {
        guard !isRunning else { return }
        isRunning = true
        while !pendingTriggers.isEmpty {
            pendingTriggers.removeAll()
            await runPass()
        }
        isRunning = false
    }

    // MARK: - One reconciliation pass

    private func runPass() async {
        guard enabled else { publish(.disabled); return }
        // ⚠️ Retried on every pass, not only at `enable()`. A registration that failed once must not
        // leave the reconciler permanently blind: a directory that registered nothing looks exactly like
        // a quiet machine forever after.
        subscribeIfNeeded()
        budget.refresh(at: clock.now)

        // ⚠️ **Look first, unconditionally.** Being paused or suspended withdraws permission to *write*,
        // never permission to *observe* — a paused reconciler that stops reading shows a default that
        // moved minutes ago, and one that never reads at all publishes "unread" while the OS has an
        // answer.
        let enumeration = directory.enumerateInputDevices()
        noteSnapshot(enumeration, seq: inbox.mint())
        let read = directory.currentDefaultInput()
        record(read)

        if paused { publish(.paused, preferred: published.preferred); return }
        if let cause = budget.suspension {
            publish(.suspended(cause), preferred: published.preferred)
            return
        }

        guard case .devices(let devices, let uninspectable) = enumeration else {
            if case .failed(let reason) = enumeration { publish(.degraded(reason: reason)) }
            return
        }
        if case .failed(let reason) = read { publish(.degraded(reason: reason)); return }
        let snapshotComplete = uninspectable.isEmpty

        let removals = observedRemovals
        observedRemovals.removeAll()
        expireOverride(devices: devices, snapshotComplete: snapshotComplete, removals: removals)
        retireHoldOnProvedDeparture(devices: devices, snapshotComplete: snapshotComplete, removals: removals)

        if let held = uncertainHold(devices: devices, snapshotComplete: snapshotComplete) {
            publish(.uncertain(uid: held), preferred: held)
            return
        }

        let generationAtStart = generation
        let (outcome, unsuccessful) = await reconcile(devices: devices, generationAtStart: generationAtStart)

        // ⚠️ **The charge is on the attempt, not on how the pass happened to end**, and that is the
        // whole correction here. Charging only a pass that returned `.refused` left two ways out. A
        // preferred device whose write never converges, with a working fallback below it, ends the pass
        // `.settled` on the fallback — and the competitor's notification starts the next pass, forever.
        // A verification *read* that fails ends it `.degraded` — an observation error, correctly, but
        // one that must not erase the fact that the write was unsuccessful. Neither may bypass the
        // bound. `.abandoned` is the one exception: the user paused, disabled or edited, and their own
        // action must not be charged against them.
        var charged = false
        if unsuccessful, case .abandoned = outcome {} else if unsuccessful {
            charged = budget.record(.convergenceFailure, at: clock.now)
        }
        if charged, let cause = budget.suspension {
            publish(.suspended(cause), preferred: published.preferred)
            return
        }

        switch outcome {
        case .settled(let uid):
            publish(.enforcing(uid: uid), preferred: uid)
        case .waiting:
            publish(.waitingForPreferredDevice)
        case .noEligibleDevice:
            publish(.noEligibleDevice)
        case .degraded(let reason):
            publish(.degraded(reason: reason), preferred: published.preferred)
        case .abandoned:
            // A stale completion: no follow-up action, and nothing published that could read as success.
            break
        case .suspended(let cause):
            publish(.suspended(cause), preferred: published.preferred)
        case .refused(let uids):
            publish(.writesRefused(uids: uids), preferred: uids.first)
        }
    }

    /// The device whose absence this snapshot could not rule out, when holding it is the right call.
    ///
    /// ⚠️ **Membership in the list is not the comparison that matters** — preference *order* is. A held
    /// device that is merely unaccounted for must be held against a **lower-priority** fallback, because
    /// switching to that fallback would be acting on an absence nobody proved. It must **not** be held
    /// against a device the user ranks *above* it: selecting that one requires no inference about the
    /// held device at all, and feature (B) promises a priority edit reconciles immediately. The case
    /// this closes: confirm the USB microphone, have it go unreadable, then reorder the list to put the
    /// built-in first — and watch nothing happen.
    private func uncertainHold(devices: [AudioInputDevice], snapshotComplete: Bool) -> String? {
        guard !snapshotComplete, let held = heldSelection() else { return nil }
        guard MicrophonePolicy.presence(of: held, in: devices, snapshotComplete: snapshotComplete) == .unknown
        else { return nil }
        guard let heldRank = preferenceRank(of: held) else { return nil }
        if case .selected(let candidate) = MicrophonePolicy.select(from: devices,
                                                                   priority: priorityStorage,
                                                                   purpose: .systemDefault),
           let candidateRank = preferenceRank(of: candidate.uid),
           candidateRank < heldRank {
            // The user prefers what this snapshot *can* offer. No inference about the held device is
            // needed to choose it.
            return nil
        }
        return held
    }

    /// Where a uid sits in the user's preferences: the override outranks the whole list, and a uid the
    /// list does not name has no rank at all.
    private func preferenceRank(of uid: String) -> Int? {
        if priorityStorage.override == uid { return -1 }
        return priorityStorage.order.firstIndex(of: uid)
    }

    /// A **proved** departure retires the held selection, even when nothing can replace it in this pass.
    ///
    /// ⚠️ Without this, one complete snapshot that showed the device gone is forgotten the moment a
    /// later *incomplete* snapshot arrives: `confirmedSelection` still names the departed device, so the
    /// uncertainty hold resurrects it and Acta protects a microphone it has already watched leave. The
    /// *preferences* are untouched — this retires the evidence, not the user's choice.
    private func retireHoldOnProvedDeparture(devices: [AudioInputDevice],
                                             snapshotComplete: Bool,
                                             removals: [(seq: UInt64, uid: String)]) {
        guard let confirmed = confirmedSelection else { return }
        let departed = removals.contains { $0.uid == confirmed }
            || MicrophonePolicy.presence(of: confirmed,
                                         in: devices,
                                         snapshotComplete: snapshotComplete) == .absent
        guard departed else { return }
        confirmedSelection = nil
        // A device that is gone cannot be reversed off the default, either.
        enforcedAndUnchallenged = nil
    }

    private enum PassOutcome {
        case settled(uid: String)
        case waiting
        case noEligibleDevice
        case refused([String])
        case degraded(String)
        case abandoned
        /// The budget tripped during this pass. ⚠️ Its own outcome rather than `.abandoned`: a
        /// suspension nobody publishes is a reconciler that silently stopped working.
        case suspended(SuspensionCause)
    }

    private func reconcile(devices: [AudioInputDevice],
                           generationAtStart: UInt64) async -> (PassOutcome, unsuccessful: Bool) {
        var unsuccessful = false
        // ⚠️ Refusals are per **pass**, never persisted. A device the OS rejected once must be tried
        // again the next time something changes: the rejection may have been about the state the machine
        // was in, and a permanent blacklist would quietly retire a working microphone forever. The
        // cross-pass bound is the budget, not this set.
        var refused: Set<String> = []
        // Every iteration adds one uid to `refused`, and `select` answers
        // `.allPreferredCandidatesRefused` once they are all in it; the count is belt and braces.
        for _ in 0 ... devices.count {
            switch MicrophonePolicy.select(from: devices,
                                           priority: priorityStorage,
                                           purpose: .systemDefault,
                                           refused: refused) {
            case .noEligibleDevice:
                return (.noEligibleDevice, unsuccessful)
            case .noPreferredDeviceAvailable:
                return (.waiting, unsuccessful)
            case .allPreferredCandidatesRefused(let uids):
                return (.refused(uids), unsuccessful)
            case .selected(let device):
                switch await enforce(device.uid, generationAtStart: generationAtStart) {
                case .settled:
                    return (.settled(uid: device.uid), unsuccessful)
                case .abandoned:
                    return (.abandoned, unsuccessful)
                case .suspended(let cause):
                    return (.suspended(cause), unsuccessful)
                case .degraded(let reason, let afterWrite):
                    // A read that failed *before* any write is an observation error and nothing more.
                    return (.degraded(reason), unsuccessful || afterWrite)
                case .tryNext:
                    unsuccessful = true
                    refused.insert(device.uid)
                }
            }
        }
        return (.refused(Array(refused)), unsuccessful)
    }

    private enum Attempt {
        case settled
        case tryNext
        case abandoned
        case suspended(SuspensionCause)
        /// ⚠️ `afterWrite` is what keeps a failed *verification* read from laundering an unsuccessful
        /// write into a pure observation error. It is both: report the read failure, charge the write.
        case degraded(String, afterWrite: Bool)
    }

    /// Re-read, write only on a mismatch, verify, and decide what the outcome means.
    private func enforce(_ uid: String, generationAtStart: UInt64) async -> Attempt {
        // Never diff winners: the comparison is always against a default read from the OS right now.
        let current = directory.currentDefaultInput()
        record(current)
        switch current {
        case .failed(let reason):
            return .degraded(reason, afterWrite: false)
        case .device(let actual) where actual == uid:
            // Already there — including when this pass was triggered by the notification from Acta's own
            // successful write. That is what keeps a write from being the first step of a loop.
            settle(uid)
            return .settled
        case .device, .none:
            if enforcedAndUnchallenged == uid {
                // ⚠️ Consumed here. One displacement is one setback, however many passes can still see
                // its aftermath; it rearms only when a write is verified again.
                enforcedAndUnchallenged = nil
                if budget.record(.reversal, at: clock.now), let cause = budget.suspension {
                    return .suspended(cause)
                }
            }
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
            settle(uid)
            return .settled
        case .readFailed(let reason):
            return .degraded(reason, afterWrite: true)
        case .diverged:
            // Not charged here: the charge is one per pass, in `runPass`. Falling through to the next
            // candidate is what lets a known-good device below an uncertain one still be reached.
            return .tryNext
        }
    }

    private func settle(_ uid: String) {
        enforcedAndUnchallenged = uid
        confirmedSelection = uid
        observedDefault = .device(uid: uid)
    }

    private enum Verification { case converged, diverged, readFailed(String) }

    /// Give a successful write until `verificationDeadline` of **clock time** to become the default.
    ///
    /// ⚠️ **The deadline is read from the clock, not accumulated from the durations requested.** Summing
    /// requested sleeps ignores oversleep, a slow HAL call and a machine that slept in the middle; a
    /// two-second deadline can then span a minute and a half of real time while the code believes it is
    /// being punctual. The iteration cap is a second bound, for a clock that does not move.
    private func verify(target: String) async -> Verification {
        let deadline = clock.now + MicrophoneEnforcementTuning.verificationDeadline
        let maxPolls = Int(MicrophoneEnforcementTuning.verificationDeadline
            / MicrophoneEnforcementTuning.verificationPollInterval) + 2
        var polls = 0
        while true {
            let read = directory.currentDefaultInput()
            record(read)
            switch read {
            case .device(let uid) where uid == target:
                return .converged
            case .failed(let reason):
                return .readFailed(reason)
            case .device, .none:
                break
            }
            polls += 1
            if clock.now >= deadline || polls >= maxPolls { return .diverged }
            await clock.sleep(for: MicrophoneEnforcementTuning.verificationPollInterval)
        }
    }

    // MARK: - Presence, the override, and what Acta is holding

    private func record(_ read: DefaultInputRead) {
        switch read {
        case .device(let uid): observedDefault = .device(uid: uid)
        case .none: observedDefault = .noDefault
        case .failed: break // ⚠️ A failed read is not "no default" — keep the last thing actually seen.
        }
    }

    /// The selection `.uncertain` protects: the override if there is one, otherwise the device a write
    /// was last verified onto — and only while the list still prefers it, since an explicit edit is the
    /// user changing their mind rather than an absence being inferred.
    private func heldSelection() -> String? {
        if let override = priorityStorage.override { return override }
        if let confirmed = confirmedSelection, priorityStorage.order.contains(confirmed) { return confirmed }
        return nil
    }

    /// Record a snapshot, and remember any device that left since the last complete one.
    ///
    /// ⚠️ **Only a complete snapshot updates the baseline.** A device missing from a snapshot that
    /// admits it could not describe every driver has not been shown to be gone, and letting it set the
    /// baseline would manufacture a departure out of one unreadable device.
    private func noteSnapshot(_ enumeration: DeviceEnumeration, seq: UInt64) {
        guard case .devices(let devices, let uninspectable) = enumeration, uninspectable.isEmpty else { return }
        let present = Set(devices.map(\.uid))
        if let previous = lastCompleteUIDs {
            for uid in previous.subtracting(present) { observedRemovals.append((seq: seq, uid: uid)) }
        }
        lastCompleteUIDs = present
    }

    /// The override expires on its device's **disconnect** — never on a timer, and never by being
    /// promoted into the persistent list.
    private func expireOverride(devices: [AudioInputDevice],
                                snapshotComplete: Bool,
                                removals: [(seq: UInt64, uid: String)]) {
        guard let override = priorityStorage.override else { return }

        // A departure seen *after* the user chose this device. Removals from before their click describe
        // a world that predates the choice and are not evidence about it.
        if removals.contains(where: { $0.seq > overrideSetAtSeq && $0.uid == override }) {
            priorityStorage.override = nil
            return
        }
        switch MicrophonePolicy.presence(of: override, in: devices, snapshotComplete: snapshotComplete) {
        case .absent:
            priorityStorage.override = nil
        case .present, .unknown:
            // ⚠️ `.unknown` deliberately keeps the override — and `runPass` additionally declines to
            // write anything else while it holds, because retaining the preference is only half of not
            // acting on an unproven absence.
            break
        }
    }

    // MARK: - Publishing

    private func publish(_ status: MicrophoneEnforcementStatus, preferred: String? = nil) {
        let next = MicrophoneEnforcementState(status: status,
                                              preferred: preferred,
                                              observedDefault: observedDefault,
                                              observationDegraded: observationDegraded)
        guard next != published else { return }
        published = next
        for continuation in continuations.values { continuation.yield(next) }
    }
}

/// Observations as the directory delivered them: **in order, with the world as it looked at the time**.
///
/// ⚠️ **This type exists because the hop from a synchronous handler to an actor is a real gap, not a
/// formality.** Two things are lost across it if nothing is captured on the near side. The first is
/// *what was true when the change happened* — the actor may be busy for an arbitrary interval, and a
/// device that leaves and returns inside it is simply present again by the time the actor enumerates,
/// so a departure that was genuinely reported becomes invisible. The second is *order*: each delivery
/// starts its own unstructured `Task`, and nothing sequences them. Both are fixed by writing the
/// observation down where it arrives and letting the actor consume the record.
///
/// ⚠️ **Remaining, honest limit**: a change the directory never reports at all — coalesced inside the
/// HAL, or occurring before the subscription existed — is still invisible here. Nothing in this file
/// can see what was never delivered.
private final class ObservationInbox: @unchecked Sendable {
    struct Observation {
        let seq: UInt64
        let change: DeviceChange
        /// The device list as it was at delivery. `nil` for changes that do not concern the list.
        let snapshot: DeviceEnumeration?
    }

    private let lock = NSLock()
    private var items: [Observation] = []
    private var nextSeq: UInt64 = 1

    func append(change: DeviceChange, snapshot: DeviceEnumeration?) {
        lock.lock()
        defer { lock.unlock() }
        items.append(Observation(seq: nextSeq, change: change, snapshot: snapshot))
        nextSeq &+= 1
    }

    /// Mint a sequence number for an observation the actor makes itself, so a pass's own snapshot orders
    /// correctly against the delivered ones.
    func mint() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let seq = nextSeq
        nextSeq &+= 1
        return seq
    }

    /// The highest sequence number issued so far: everything at or below it is already history.
    var highWaterMark: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nextSeq &- 1
    }

    func drain() -> [Observation] {
        lock.lock()
        defer { lock.unlock() }
        let drained = items
        items.removeAll()
        return drained
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty
    }
}
