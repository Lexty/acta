import ActaKit
@testable import ActaRuntime
import Foundation
import Testing

/// The six scenarios a peer review reproduced against the first version of `MicrophoneReconciler`, each
/// of which it got wrong.
///
/// They live in a file of their own because they share a different kind of fixture from the contract
/// tests: a directory that **fights back**, and sequences that turn on what was true at a particular
/// instant rather than at the end. Every one of them failed before the rework and passes after it; the
/// negative controls are recorded in the commit message.
@Suite("Microphone reconciler, hard cases")
struct MicrophoneReconcilerHardCaseTests {
    private func harness(devices: [AudioInputDevice],
                         defaultInput: String?,
                         order: [String],
                         override: String? = nil)
        -> (FakeAudioDeviceDirectory, TestClock, MicrophoneReconciler) {
        let directory = FakeAudioDeviceDirectory(devices: devices, defaultInput: defaultInput)
        let clock = TestClock()
        let reconciler = MicrophoneReconciler(directory: directory,
                                              clock: clock,
                                              priority: MicrophonePriority(order: order, override: override))
        return (directory, clock, reconciler)
    }

    // MARK: - 1. A competitor faster than the verification read

    /// ⚠️ **The unbounded fight.** A competitor that restores its own choice *before* Acta's first
    /// verification read means Acta's write never visibly wins — so no reversal is ever provable, the
    /// reversal counter stays at zero forever, and every write provokes the notification that starts the
    /// next pass. Bounding candidates *within* a pass does not bound enforcement; the cross-pass
    /// convergence-failure count is what does.
    ///
    /// The fixture's own reversal cap exists only so that a regression fails this test instead of
    /// hanging the suite. Reaching it is itself a failure.
    @Test("a competitor faster than verification is bounded, not fought forever")
    func aFastCompetitorIsBounded() async {
        let fighting = FightingAudioDeviceDirectory(
            devices: [.builtInMic(), .airPods()],
            restoringTo: "00-00-5E-00-53-01:input",
            reversalCap: 12
        )
        let clock = TestClock()
        let reconciler = MicrophoneReconciler(directory: fighting,
                                              clock: clock,
                                              priority: MicrophonePriority(order: ["BuiltInMicrophoneDevice"]))
        await reconciler.enable()
        await reconciler.waitForQuiescence()

        #expect(fighting.reversalCapReached == false)
        #expect(await reconciler.state.status ==
            .suspended(.repeatedConvergenceFailures(MicrophoneEnforcementTuning.conflictsBeforeSuspension)))
        // One pass per charge, one write per pass: the fight is over in three, not nine.
        #expect(fighting.attemptedWrites.count == MicrophoneEnforcementTuning.conflictsBeforeSuspension)
    }

    // MARK: - 2. One displacement is one setback

    /// ⚠️ **A persistent "last device I enforced" charges the same displacement again on every pass that
    /// can still see its aftermath.** Nothing restored the built-in microphone here: the default moved
    /// once and every attempted correction was refused. That is one reversal and three refused writes,
    /// not three reversals.
    @Test("one displacement followed by failing corrections is charged once")
    func oneDisplacementIsOneReversal() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))

        // The default is displaced exactly once, and every correction from here on is refused.
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.scriptWrites([], thereafter: .failed(reason: "refused"))

        for _ in 0 ..< MicrophoneEnforcementTuning.conflictsBeforeSuspension {
            directory.emit(.defaultInputChanged)
            await reconciler.waitForQuiescence()
        }

        // Suspension is right — enforcement must still bound itself — but the *reason* must be the
        // refused writes, not three reversals that never happened.
        #expect(await reconciler.state.status ==
            .suspended(.repeatedConvergenceFailures(MicrophoneEnforcementTuning.conflictsBeforeSuspension)))
    }

    // MARK: - 3. The actor hop loses delivered departures

    /// ⚠️ **Earlier than the coalescing the reconciler protects against.** Both notifications really were
    /// delivered, one of them while the overridden headset was genuinely absent — but if the snapshot is
    /// taken *after* the hop to the actor, the device is simply present again by the time anyone looks,
    /// and the override outlives a disconnect the OS reported.
    ///
    /// The actor is held busy by a write that never converges, so both deliveries land before it can
    /// process either.
    /// ⚠️ **The barrier is a directory call, not a clock sleep** — a peer review demonstrated that
    /// `TestClock.onSleep` does not hold the actor at all (`sleep` is `nonisolated`, and the `await`
    /// before it has already yielded), so an `onSleep` handler proves nothing about ordering and a
    /// negative control run inside one is a sample rather than a proof. `currentDefaultInput()` is
    /// invoked **synchronously from the reconciler's own isolation**: while it runs, no other turn on
    /// that actor can. Both deliveries therefore provably land before the actor can look at anything.
    @Test("a departure delivered while the actor was busy still expires the override")
    func aDepartureDeliveredDuringABusyActorIsNotLost() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"],
                                                 override: "00-00-5E-00-53-01:input")
        let steps = Steps()
        directory.onDefaultRead { _ in
            guard steps.next() == 1 else { return }
            directory.setDevices([.builtInMic()])
            directory.emit(.deviceListChanged)
            directory.setDevices([.builtInMic(), .airPods()])
            directory.emit(.deviceListChanged)
        }
        await reconciler.enable()
        await reconciler.waitForQuiescence()

        #expect(await reconciler.priority.override == nil)
    }

    // MARK: - 1c. The escape routes out of the cross-pass bound

    /// ⚠️ **A working fallback is not a reason to stop counting.** The preferred device's write never
    /// converges, the fallback below it is already the default, so the pass ends `.settled` — and the
    /// competitor's notification starts the next one. Charging only a pass that ended `.refused` leaves
    /// this running forever; a seeded priority list normally *has* a fallback, so this is the ordinary
    /// shape, not a corner.
    @Test("a converging fallback does not launder an unsuccessful preferred write")
    func aSettledFallbackStillChargesTheFailedAttempt() async {
        let fighting = FightingAudioDeviceDirectory(
            devices: [.usbMic(), .builtInMic()],
            restoringTo: "BuiltInMicrophoneDevice",
            reversalCap: 12
        )
        let clock = TestClock()
        let reconciler = MicrophoneReconciler(
            directory: fighting,
            clock: clock,
            priority: MicrophonePriority(order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
        )
        await reconciler.enable()
        await reconciler.waitForQuiescence()

        #expect(fighting.reversalCapReached == false)
        #expect(await reconciler.state.status ==
            .suspended(.repeatedConvergenceFailures(MicrophoneEnforcementTuning.conflictsBeforeSuspension)))
    }

    /// ⚠️ **A failed verification read is an observation error *and* an unsuccessful write.** Reporting
    /// the first must not erase the second, or `.degraded` becomes the second way out of the bound.
    @Test("a failed verification read does not bypass the bound")
    func aFailedVerificationReadStillChargesTheWrite() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        // Enforcing before the first failure, so the assertion at the end is about what the loop did.
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
        directory.setWritesTakeEffect(false)

        for _ in 0 ..< MicrophoneEnforcementTuning.conflictsBeforeSuspension {
            // The pass's observing read succeeds, the pre-write read succeeds, the verification read
            // fails — so every pass reports a read error while its write went nowhere.
            directory.scriptDefaultReads([.device(uid: "00-00-5E-00-53-01:input"),
                                          .device(uid: "00-00-5E-00-53-01:input"),
                                          .failed(reason: "read refused")])
            directory.emit(.defaultInputChanged)
            await reconciler.waitForQuiescence()
        }

        #expect(await reconciler.state.status ==
            .suspended(.repeatedConvergenceFailures(MicrophoneEnforcementTuning.conflictsBeforeSuspension)))
    }

    // MARK: - 2b. The hold must respect priority order, not membership

    /// ⚠️ **Membership in the list is not the comparison.** The USB microphone is unaccounted for, but
    /// the user has just moved the built-in above it — and selecting the built-in requires no inference
    /// about the USB device at all. Holding here means a priority edit visibly does nothing, which is
    /// the one thing feature (B) promises will always take effect immediately.
    @Test("an explicit reorder is honoured over an uncertain lower-priority hold")
    func aReorderIsHonouredOverAnUncertainHold() async {
        let (directory, _, reconciler) = harness(devices: [.usbMic(), .builtInMic()],
                                                 defaultInput: "USBAudioDevice_UID",
                                                 order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
        await reconciler.enable()
        #expect(await reconciler.state.status == .enforcing(uid: "USBAudioDevice_UID"))

        directory.setDevices([.builtInMic()], uninspectable: ["USBAudioDevice_UID"])
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()
        // Still held while the user's order is unchanged — that half stays right.
        #expect(await reconciler.state.status == .uncertain(uid: "USBAudioDevice_UID"))

        await reconciler.setOrder(["BuiltInMicrophoneDevice", "USBAudioDevice_UID"])

        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
    }

    // MARK: - 1d. Disabling ends an in-flight verification, it does not merely outlive it

    /// ⚠️ **The write guard runs when `verify()` returns; the reads happen while it is still running.**
    /// So a reconciler told to stop went on polling the directory for the rest of its verification
    /// deadline — the owner's "nothing reads or writes through this afterwards" was false about the
    /// reconciler itself, and the write guard said nothing because no write was attempted.
    ///
    /// Sampled the instant `disable()` returns, because sampling later lets the poll finish first and
    /// the assertion becomes vacuous. It cannot produce a false failure: if `disable()` happened to land
    /// after the verification had already ended, there is nothing left to read either way.
    @Test("disabling stops a verification already in flight from reading")
    func disablingEndsAnInFlightVerification() async {
        let (directory, clock, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                     defaultInput: "00-00-5E-00-53-01:input",
                                                     order: ["BuiltInMicrophoneDevice"])
        // Accepted, never takes effect: the verification polls until its deadline.
        directory.setWritesTakeEffect(false)

        let steps = Steps()
        let done = Steps()
        let readsAtDisable = IntBox()
        clock.onSleep { _ in
            guard steps.next() == 1 else { return }
            Task {
                await reconciler.disable()
                readsAtDisable.set(directory.defaultReadCount)
                _ = done.next()
            }
        }
        await reconciler.enable()
        for _ in 0 ..< 500 where done.count == 0 { await Task.yield() }
        #expect(done.count == 1, "the disable never completed")

        for _ in 0 ..< 50 { await Task.yield() }

        #expect(directory.defaultReadCount == readsAtDisable.value,
                "the verification kept reading the directory after it was disabled")
    }

    // MARK: - 2c. The hold is a question about each candidate, not about the pass

    /// ⚠️ **A refused higher-ranked write proves nothing about the devices below the held one.** The
    /// pass is rightly allowed to *attempt* the USB microphone, which the user ranks above the
    /// unaccounted-for headset. When that write is refused, the loop must not walk past the headset and
    /// switch the system input to the built-in microphone — the headset's absence is still unproven, and
    /// the built-in is exactly the lower-priority fallback the hold exists to block.
    ///
    /// Asking the question once, before the loop, answers it about a candidate the pass may never act
    /// on. It is now asked about each candidate the loop actually reaches.
    @Test("a refused higher-ranked write does not authorise a lower-ranked switch")
    func aRefusedHigherRankedWriteDoesNotUnblockTheFallback() async {
        let (directory, _, reconciler) = harness(
            devices: [.airPods(), .builtInMic()],
            defaultInput: "00-00-5E-00-53-01:input",
            order: ["USBAudioDevice_UID", "00-00-5E-00-53-01:input", "BuiltInMicrophoneDevice"]
        )
        await reconciler.enable()
        #expect(await reconciler.state.status == .enforcing(uid: "00-00-5E-00-53-01:input"))
        #expect(directory.attemptedWrites.isEmpty)

        // The USB microphone appears, the headset becomes unreadable, and the USB write is refused.
        directory.setDevices([.usbMic(), .builtInMic()], uninspectable: ["00-00-5E-00-53-01:input"])
        directory.scriptWrites([.failed(reason: "refused")], thereafter: .written)
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        // Attempting the higher-ranked device is allowed; falling past the held one is not.
        #expect(directory.attemptedWrites == ["USBAudioDevice_UID"])
        #expect(await reconciler.state.observedDefault == .device(uid: "00-00-5E-00-53-01:input"))
        #expect(await reconciler.state.status == .uncertain(uid: "00-00-5E-00-53-01:input"))
    }

    /// The same hole reached through a verification timeout rather than a refused write.
    @Test("a higher-ranked write that never converges does not authorise a lower-ranked switch")
    func anUnconvergedHigherRankedWriteDoesNotUnblockTheFallback() async {
        let (directory, _, reconciler) = harness(
            devices: [.airPods(), .builtInMic()],
            defaultInput: "00-00-5E-00-53-01:input",
            order: ["USBAudioDevice_UID", "00-00-5E-00-53-01:input", "BuiltInMicrophoneDevice"]
        )
        await reconciler.enable()

        directory.setDevices([.usbMic(), .builtInMic()], uninspectable: ["00-00-5E-00-53-01:input"])
        directory.setWritesTakeEffect(false)
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites == ["USBAudioDevice_UID"])
        #expect(await reconciler.state.status == .uncertain(uid: "00-00-5E-00-53-01:input"))
    }

    /// The converse that keeps the fix from being satisfied by refusing to write at all: a candidate the
    /// user ranks **above** the held device is still written, and the attempt is not blocked.
    @Test("a higher-ranked candidate is still written while a lower-ranked one is held")
    func aHigherRankedCandidateIsStillWritten() async {
        let (directory, _, reconciler) = harness(
            devices: [.airPods(), .builtInMic()],
            defaultInput: "00-00-5E-00-53-01:input",
            order: ["USBAudioDevice_UID", "00-00-5E-00-53-01:input", "BuiltInMicrophoneDevice"]
        )
        await reconciler.enable()

        directory.setDevices([.usbMic(), .builtInMic()], uninspectable: ["00-00-5E-00-53-01:input"])
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites == ["USBAudioDevice_UID"])
        #expect(await reconciler.state.status == .enforcing(uid: "USBAudioDevice_UID"))
    }

    /// ⚠️ **A failure to describe the held device is not a claim about the hardware.** When no candidate
    /// can be selected at all, the reconciler still has to say *why* — and "this Mac has no usable
    /// input" and "nothing you prefer is here" are both assertions the directory has not earned while
    /// it cannot account for the microphone currently in use. Publishing either one presents an
    /// observation failure as ordinary absence, which is the distinction the whole feature rests on.
    ///
    /// Both variants leave the actual default untouched and write nothing; the defect is entirely in
    /// the published diagnosis, which is exactly the kind that survives a suite checking only writes.
    @Test("an unaccounted-for held device is not reported as missing hardware", arguments: [
        ([AudioInputDevice](), MicrophoneEnforcementStatus.noEligibleDevice),
        ([AudioInputDevice.builtInMic()], MicrophoneEnforcementStatus.waitingForPreferredDevice),
    ])
    func anUnknownHeldDeviceOutranksEveryNoCandidateVerdict(
        _ scenario: ([AudioInputDevice], MicrophoneEnforcementStatus)
    ) async {
        let (inspected, wrongVerdict) = scenario
        let (directory, _, reconciler) = harness(
            devices: [.airPods()],
            defaultInput: "00-00-5E-00-53-01:input",
            order: ["USBAudioDevice_UID", "00-00-5E-00-53-01:input"]
        )
        await reconciler.enable()
        #expect(await reconciler.state.status == .enforcing(uid: "00-00-5E-00-53-01:input"))
        #expect(directory.attemptedWrites.isEmpty)

        // The headset is still the actual default; the directory simply cannot describe it.
        directory.setDevices(inspected, uninspectable: ["00-00-5E-00-53-01:input"])
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        let status = await reconciler.state.status
        #expect(status == .uncertain(uid: "00-00-5E-00-53-01:input"))
        #expect(status != wrongVerdict)
        #expect(directory.attemptedWrites.isEmpty)
        #expect(await reconciler.state.observedDefault == .device(uid: "00-00-5E-00-53-01:input"))
    }

    /// The converse, and it was missing until a negative control walked straight through the suite: an
    /// incomplete snapshot that **does** describe the held device has proved something about it, so a
    /// verdict drawn from that description is earned and must be published.
    ///
    /// ⚠️ Here the headset is listed and reported not alive. "Present and unusable" is a fact; laundering
    /// it into "I could not see it" would be the same error as the regression above, pointing the other
    /// way — and it is the error a hold that never checks presence would make.
    @Test("a held device that is described and unusable still yields a real verdict")
    func aDescribedButUnusableHeldDeviceIsNotUncertainty() async {
        let (directory, _, reconciler) = harness(devices: [.airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["00-00-5E-00-53-01:input"])
        await reconciler.enable()
        #expect(await reconciler.state.status == .enforcing(uid: "00-00-5E-00-53-01:input"))

        // Still listed, still described — and no longer usable. An unrelated driver is unreadable, so
        // the snapshot is incomplete and the hold is in play.
        directory.setDevices([.airPods(alive: .no)], uninspectable: ["BlackHole2ch_UID"])
        directory.setDefaultInput(DefaultInputRead.none)
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        #expect(await reconciler.state.status == .noEligibleDevice)
        #expect(await reconciler.state.observedDefault == .noDefault)
    }

    // MARK: - 3b. A proved departure retires the hold, even with nothing to replace it

    /// ⚠️ **One complete snapshot showing the device gone must not be forgotten by the next incomplete
    /// one.** Between them there is a moment where nothing can settle — and if the departure is only
    /// ever retired *by* a settlement, that moment preserves the stale hold and a later partial snapshot
    /// resurrects it. Acta then protects a microphone it has already watched leave.
    @Test("a proved departure retires the hold even when nothing can replace it")
    func aProvedDepartureRetiresTheHoldWithNoReplacement() async {
        let (directory, _, reconciler) = harness(devices: [.usbMic(), .builtInMic()],
                                                 defaultInput: "USBAudioDevice_UID",
                                                 order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
        await reconciler.enable()
        #expect(await reconciler.state.status == .enforcing(uid: "USBAudioDevice_UID"))

        // Everything goes away: the departure is proved, and nothing can be selected in its place.
        directory.setDevices([])
        directory.setDefaultInput(DefaultInputRead.none)
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()
        #expect(await reconciler.state.status == .noEligibleDevice)

        // A later, incomplete snapshot — with an unrelated driver unreadable — must not revive the hold.
        directory.setDevices([.builtInMic(), .airPods()], uninspectable: ["BlackHole2ch_UID"])
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites.last == "BuiltInMicrophoneDevice")
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
    }

    /// The other side of the sequence number: a departure observed **before** the user clicked *Use
    /// now* describes a world that predates their choice and must not retire it.
    ///
    /// The departure has to still be *pending* when the click lands, or the test proves nothing — so it
    /// is delivered while the actor is busy on a write that never converges, and the click follows one
    /// sleep later, before any pass can consume it.
    @Test("a departure still pending when Use now is issued does not retire it")
    func aStaleDepartureDoesNotRetireAFreshUseNow() async {
        let (directory, clock, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                     defaultInput: "00-00-5E-00-53-01:input",
                                                     order: ["BuiltInMicrophoneDevice"])
        directory.setWritesTakeEffect(false)
        let steps = Steps()
        clock.onSleep { _ in
            switch steps.next() {
            case 1:
                // The headset drops out and comes back, both observed, with no override in force.
                directory.setDevices([.builtInMic()])
                directory.emit(.deviceListChanged)
                directory.setDevices([.builtInMic(), .airPods()])
                directory.emit(.deviceListChanged)
            case 2:
                Task { await reconciler.useNow(uid: "00-00-5E-00-53-01:input") }
            default:
                break
            }
        }
        await reconciler.enable()
        await reconciler.waitForQuiescence()

        #expect(await reconciler.priority.override == "00-00-5E-00-53-01:input")
    }

    // MARK: - 4. The forbidden failover

    /// ⚠️ **Keeping the stored preference is only half of not acting on an unproven absence.** The
    /// override survives the incomplete snapshot — and if the reconciler then writes a *different*
    /// device, it has switched the user's microphone away from the one it claims to be holding, on the
    /// strength of an omission that proves nothing. The write is the destructive part.
    @Test("an incomplete snapshot does not switch the system input away from the held device")
    func anIncompleteSnapshotDoesNotFailOver() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["BuiltInMicrophoneDevice"],
                                                 override: "00-00-5E-00-53-01:input")
        await reconciler.enable()
        #expect(await reconciler.state.status == .enforcing(uid: "00-00-5E-00-53-01:input"))
        #expect(directory.attemptedWrites.isEmpty)

        directory.setDevices([.builtInMic()], uninspectable: ["00-00-5E-00-53-01:input"])
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        #expect(await reconciler.priority.override == "00-00-5E-00-53-01:input")
        // The assertions the preference-only version of this test could not make.
        #expect(directory.attemptedWrites.isEmpty)
        #expect(await reconciler.state.status == .uncertain(uid: "00-00-5E-00-53-01:input"))
        #expect(await reconciler.state.observedDefault == .device(uid: "00-00-5E-00-53-01:input"))
    }

    /// The other half of the same rule: a **proved** departure is a different case, and must fail over.
    @Test("a complete snapshot that proves the departure does fail over")
    func aProvedDepartureFailsOver() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["BuiltInMicrophoneDevice"],
                                                 override: "00-00-5E-00-53-01:input")
        await reconciler.enable()

        directory.setDevices([.builtInMic()])
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        #expect(await reconciler.priority.override == nil)
        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
    }

    // MARK: - 5. Observation is not permission to enforce

    /// ⚠️ Three states that published a default which was stale, or `nil` for "I never looked".
    @Test("the observed default is read and published in every non-writing state")
    func theObservedDefaultIsAccurateWhileNotWriting() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods(), .usbMic()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: [])
        // Waiting: an empty list writes nothing, and must still say what the default is.
        await reconciler.enable()
        #expect(await reconciler.state.status == .waitingForPreferredDevice)
        #expect(await reconciler.state.observedDefault == .device(uid: "00-00-5E-00-53-01:input"))

        // Enforcing: the read that confirms convergence updates the cache too.
        await reconciler.setOrder(["BuiltInMicrophoneDevice"])
        #expect(await reconciler.state.observedDefault == .device(uid: "BuiltInMicrophoneDevice"))

        // Paused: still observing. The default moves and the state follows it without a write.
        await reconciler.pause()
        let writesAtPause = directory.attemptedWrites
        directory.setDefaultInput(.device(uid: "USBAudioDevice_UID"))
        directory.emit(.defaultInputChanged)
        await reconciler.waitForQuiescence()

        #expect(await reconciler.state.status == .paused)
        #expect(await reconciler.state.observedDefault == .device(uid: "USBAudioDevice_UID"))
        #expect(directory.attemptedWrites == writesAtPause)
    }

    /// ⚠️ `nil` said both "the OS has no default input" and "I have not read one". They are different
    /// facts and the second one is Acta having no idea.
    @Test("never read and no default are different answers")
    func unreadIsNotTheSameAsNoDefault() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic()],
                                                 defaultInput: nil,
                                                 order: ["BuiltInMicrophoneDevice"])
        #expect(await reconciler.state.observedDefault == .unread)

        await reconciler.enable()
        // The OS answered "no default", then the write landed.
        #expect(await reconciler.state.observedDefault == .device(uid: "BuiltInMicrophoneDevice"))

        // A failed read must not degrade into "there is no default".
        directory.setDefaultInput(.failed(reason: "read refused"))
        directory.emit(.defaultInputChanged)
        await reconciler.waitForQuiescence()

        #expect(await reconciler.state.status == .degraded(reason: "read refused"))
        #expect(await reconciler.state.observedDefault == .device(uid: "BuiltInMicrophoneDevice"))
    }

    // MARK: - 6. The deadline is clock time

    /// ⚠️ **Summing the durations requested is not measuring time.** With a clock that oversleeps, the
    /// old loop slept its full poll count and spanned more than a minute while believing it had honoured
    /// a two-second deadline. One overshooting sleep must end the window.
    @Test("an oversleeping clock ends the verification window at the first overshoot")
    func theVerificationDeadlineIsClockTimeNotSummedSleeps() async {
        let (directory, clock, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                     defaultInput: "00-00-5E-00-53-01:input",
                                                     order: ["BuiltInMicrophoneDevice"])
        directory.setWritesTakeEffect(false)
        // Every sleep costs ten seconds more than it asked for — a machine that slept, or a HAL call
        // that blocked.
        clock.onSleep { _ in clock.advance(by: 10) }

        await reconciler.enable()
        await reconciler.waitForQuiescence()

        #expect(await reconciler.state.status == .writesRefused(uids: ["BuiltInMicrophoneDevice"]))
        // One sleep is enough to blow a two-second deadline; a second one would mean the loop is still
        // counting its own requests.
        #expect(clock.sleepCount == 1)
    }
}
