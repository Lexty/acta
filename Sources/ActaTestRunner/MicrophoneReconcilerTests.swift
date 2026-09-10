import ActaKit
@testable import ActaRuntime
import Foundation
import Testing

/// The reconciler's contract, driven entirely through `FakeAudioDeviceDirectory` and `TestClock`.
///
/// **What these tests can and cannot prove.** Everything below is the *decision logic*: which device
/// wins, when a write is issued, what a failure is allowed to conclude, and when Acta stops fighting.
/// None of it proves that CoreAudio accepts a write or that a HAL listener ever fires — the seam ends
/// below all of this, and that gap is listed in the plan's "Not verified automatically" section.
///
/// **Enforcement while idle needs no test here, and saying so is more honest than writing one.** This
/// reconciler names no recording type, holds no controller and has no notion of a session — a test
/// asserting "it still enforces while nothing is recording" would be asserting that a type it cannot
/// reach did not affect it. The real question — that exactly one reconciler exists for the app's
/// lifetime and survives recording start/stop — is about *ownership*, and it is Task 4's acceptance.
@Suite("Microphone reconciler")
struct MicrophoneReconcilerTests {
    // MARK: - Harness

    /// A `@Sendable` counter for the `onSleep` hook, which cannot capture a mutable local.
    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

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

    // MARK: - The core promise

    @Test("the preferred device is written when the actual default is something else")
    func enablingEnforcesThePreferredDevice() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()

        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
    }

    @Test("the default already being the preferred device writes nothing")
    func aMatchingDefaultIsNotRewritten() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()

        #expect(directory.attemptedWrites.isEmpty)
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
    }

    /// ⚠️ **The test the whole "do not diff winners" rule exists for.** The winner is the built-in
    /// microphone before the headset connects and the built-in microphone after it — unchanged, twice —
    /// while the *actual* default moves underneath. A reconciler that compares this pass's winner with
    /// the last one concludes there is nothing to do and leaves the user on the headset, which is
    /// precisely the bug being fixed.
    @Test("an unchanged winner with a moved actual default still writes")
    func anUnchangedWinnerStillWritesWhenTheActualDefaultMoved() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        #expect(directory.attemptedWrites.isEmpty)

        // The headset connects: the same winner, a different actual default.
        directory.setDevices([.builtInMic(), .airPods()])
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.emit([.deviceListChanged, .defaultInputChanged])
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
    }

    /// The measured fact behind this: at 0.4 s resolution the default's flip and the device's appearance
    /// landed in the same sample, both times. So neither order may be the one that works.
    @Test("both notification orders reach the same enforcement", arguments: [
        [DeviceChange.deviceListChanged, .defaultInputChanged],
        [DeviceChange.defaultInputChanged, .deviceListChanged],
    ])
    func eitherNotificationOrderEnforces(_ changes: [DeviceChange]) async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()

        directory.setDevices([.builtInMic(), .airPods()])
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.emit(changes)
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
    }

    @Test("duplicate and coalesced notifications produce one write")
    func burstsAreCoalescedIntoOneWrite() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()

        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.emit([.defaultInputChanged, .defaultInputChanged, .deviceListChanged,
                        .defaultInputChanged, .deviceListChanged])
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
    }

    /// The notification Acta's own write provokes must be a no-op, or the first write is the first step
    /// of a loop.
    @Test("the notification caused by Acta's own write does not write again")
    func actasOwnWriteNotificationIsANoOp() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])

        directory.emit(.defaultInputChanged)
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
    }

    @Test("the default is re-read immediately before every write")
    func theActualDefaultIsReReadBeforeWriting() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        // At least the pre-write read and the verification read; never zero, which is what a reconciler
        // that trusts a cached default would show.
        #expect(directory.defaultReadCount >= 2)
    }

    // MARK: - Triggers with no notification behind them

    @Test("a priority edit reconciles even though no notification fires")
    func aPreferenceEditReconciles() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .usbMic()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        #expect(directory.attemptedWrites.isEmpty)

        await reconciler.setOrder(["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])

        #expect(directory.attemptedWrites == ["USBAudioDevice_UID"])
    }

    @Test("Use now reconciles even though no notification fires")
    func useNowReconciles() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()

        await reconciler.useNow(uid: "00-00-5E-00-53-01:input")

        #expect(directory.attemptedWrites == ["00-00-5E-00-53-01:input"])
        #expect(await reconciler.state.status == .enforcing(uid: "00-00-5E-00-53-01:input"))
        // ⚠️ Never promoted into the persistent list — borrowing a headset is not a preference change.
        #expect(await reconciler.priority.order == ["BuiltInMicrophoneDevice"])
    }

    @Test("resuming automatic selection retires the override and reconciles")
    func resumingAutomaticSelectionRetiresTheOverride() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"],
                                                 override: "00-00-5E-00-53-01:input")
        await reconciler.enable()
        #expect(directory.attemptedWrites == ["00-00-5E-00-53-01:input"])

        await reconciler.resumeAutomaticSelection()

        #expect(await reconciler.priority.override == nil)
        #expect(directory.attemptedWrites == ["00-00-5E-00-53-01:input", "BuiltInMicrophoneDevice"])
    }

    @Test("a readiness change reconciles without the device list moving")
    func aReadinessChangeReconciles() async {
        let (directory, _, reconciler) = harness(devices: [.usbMic(), .builtInMic()],
                                                 defaultInput: "USBAudioDevice_UID",
                                                 order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
        await reconciler.enable()
        #expect(directory.attemptedWrites.isEmpty)

        // The USB microphone is still listed and is no longer alive — presence is not availability.
        directory.setDevices([
            AudioInputDevice(uid: "USBAudioDevice_UID", name: "USB Microphone", transport: .usb,
                             inputChannels: 1, canBeSystemDefault: .yes, isAlive: .no,
                             isRunningSomewhere: false),
            .builtInMic(),
        ])
        directory.emit(.readinessChanged(uid: "USBAudioDevice_UID"))
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
    }

    // MARK: - The startup race

    /// A change delivered between the first enumeration and the observer's installation reaches nobody
    /// and is absent from the snapshot already taken. Subscribing **first** is what removes the window,
    /// and this pins the ordering rather than describing it.
    @Test("the subscription is installed before the first enumeration")
    func subscriptionPrecedesTheFirstEnumeration() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()

        #expect(directory.enumerationCountAtSubscribe == 0)
        #expect(directory.subscriberCount == 1)
    }

    // MARK: - Failures conclude nothing about the hardware

    @Test("an enumeration failure is reported and clears no preferences")
    func anEnumerationFailureIsNotADisconnect() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"],
                                                 override: "00-00-5E-00-53-01:input")
        await reconciler.enable()

        directory.failEnumeration(reason: "kAudioHardwareUnknownPropertyError")
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        #expect(await reconciler.state.status == .degraded(reason: "kAudioHardwareUnknownPropertyError"))
        #expect(await reconciler.priority.override == "00-00-5E-00-53-01:input")
        #expect(await reconciler.priority.order == ["BuiltInMicrophoneDevice"])

        // Recovery: the same devices come back and enforcement resumes on the untouched preferences.
        directory.setDevices([.builtInMic(), .airPods()])
        directory.setDefaultInput(.device(uid: "BuiltInMicrophoneDevice"))
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        #expect(await reconciler.state.status == .enforcing(uid: "00-00-5E-00-53-01:input"))
    }

    @Test("a failed default-input read is degraded, not a missing default")
    func aFailedReadIsDegraded() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        directory.setDefaultInput(.failed(reason: "read refused"))
        await reconciler.enable()

        #expect(await reconciler.state.status == .degraded(reason: "read refused"))
        #expect(directory.attemptedWrites.isEmpty)
    }

    /// ⚠️ The third outcome that hides: a directory that registered nothing looks exactly like a quiet
    /// machine. Enforcement still runs on the triggers that are not notifications — the point is that
    /// the degradation is *stated*.
    @Test("a failed subscription is visible and does not stop enforcement")
    func aFailedSubscriptionIsVisible() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["BuiltInMicrophoneDevice"])
        directory.failObservation(reason: "AudioObjectAddPropertyListenerBlock failed")
        await reconciler.enable()

        #expect(await reconciler.state.observationDegraded == "AudioObjectAddPropertyListenerBlock failed")
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
    }

    @Test("a subscription that failed once is retried and recovers")
    func aFailedSubscriptionIsRetried() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["BuiltInMicrophoneDevice"])
        directory.failObservation(reason: "registration refused")
        await reconciler.enable()
        #expect(directory.subscriberCount == 0)

        directory.allowObservation()
        await reconciler.wake()

        #expect(directory.subscriberCount == 1)
        #expect(await reconciler.state.observationDegraded == nil)
    }

    // MARK: - Refused writes

    @Test("a refused write falls through to the next preferred device")
    func aRefusedWriteFallsThrough() async {
        let (directory, _, reconciler) = harness(devices: [.unknownEligibility(), .builtInMic()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["MysteryDevice_UID", "BuiltInMicrophoneDevice"])
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.scriptWrites([.failed(reason: "kAudioHardwareIllegalOperationError")])
        await reconciler.enable()

        #expect(directory.attemptedWrites == ["MysteryDevice_UID", "BuiltInMicrophoneDevice"])
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
    }

    @Test("a device that vanished between selection and write falls through")
    func anUnknownDeviceOnWriteFallsThrough() async {
        let (directory, _, reconciler) = harness(devices: [.usbMic(), .builtInMic()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
        directory.scriptWrites([.unknownDevice(uid: "USBAudioDevice_UID")])
        await reconciler.enable()

        #expect(directory.attemptedWrites == ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
    }

    /// ⚠️ The three sentences this outcome must not become. The USB microphone is plugged in and the OS
    /// is refusing it: that is neither success, nor "waiting for a preferred microphone to appear", nor
    /// "this Mac has no usable input".
    @Test("every preferred device refused is its own status")
    func allPreferredCandidatesRefusedIsItsOwnStatus() async {
        let (directory, _, reconciler) = harness(devices: [.usbMic(), .builtInMic()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["USBAudioDevice_UID"])
        directory.scriptWrites([.failed(reason: "refused")], thereafter: .failed(reason: "refused"))
        await reconciler.enable()

        let status = await reconciler.state.status
        #expect(status == .writesRefused(uids: ["USBAudioDevice_UID"]))
        #expect(status != .waitingForPreferredDevice)
        #expect(status != .noEligibleDevice)
        #expect(status != .enforcing(uid: "USBAudioDevice_UID"))
    }

    @Test("a write that reports success but never takes effect is a refusal, not a conflict")
    func aWriteThatNeverTakesEffectFallsThrough() async {
        let (directory, _, reconciler) = harness(devices: [.usbMic(), .builtInMic()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
        directory.setWritesTakeEffect(false)
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        await reconciler.enable()

        // The USB write is issued, never converges within the deadline, and the built-in is tried next.
        #expect(directory.attemptedWrites == ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
        #expect(await reconciler.state.status == .writesRefused(uids: ["USBAudioDevice_UID",
                                                                      "BuiltInMicrophoneDevice"]))
    }

    // MARK: - Verification

    /// ⚠️ A briefly stale read is the OS being asynchronous, not a fight. Spending the conflict budget on
    /// it would suspend enforcement on a machine where nothing is competing at all.
    @Test("a delayed convergence is not a conflict")
    func delayedConvergenceIsNotAConflict() async {
        let (directory, clock, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                     defaultInput: "00-00-5E-00-53-01:input",
                                                     order: ["BuiltInMicrophoneDevice"])
        directory.setWritesTakeEffect(false)
        // The pre-write read, then one stale read, then the write has landed.
        directory.scriptDefaultReads([.device(uid: "00-00-5E-00-53-01:input"),
                                      .device(uid: "00-00-5E-00-53-01:input"),
                                      .device(uid: "BuiltInMicrophoneDevice")])
        await reconciler.enable()

        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
        // It waited rather than concluding from the first read.
        #expect(clock.sleepCount >= 1)
    }

    // MARK: - The conflict budget

    /// Three reversals inside the window: something keeps putting the default back, and Acta stops
    /// rather than ping-ponging with it.
    @Test("three reversals inside the window suspend enforcement")
    func repeatedReversalsSuspendEnforcement() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()

        for _ in 0 ..< MicrophoneEnforcementTuning.conflictsBeforeSuspension {
            directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
            directory.emit(.defaultInputChanged)
            await reconciler.waitForQuiescence()
        }

        #expect(await reconciler.state.status ==
            .suspended(conflicts: MicrophoneEnforcementTuning.conflictsBeforeSuspension))
        // The last reversal is not fought: one write fewer than reversals.
        #expect(directory.attemptedWrites.count == MicrophoneEnforcementTuning.conflictsBeforeSuspension - 1)
    }

    @Test("a suspended reconciler issues no further writes")
    func suspensionStopsWriting() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        for _ in 0 ..< MicrophoneEnforcementTuning.conflictsBeforeSuspension {
            directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
            directory.emit(.defaultInputChanged)
            await reconciler.waitForQuiescence()
        }
        let writesAtSuspension = directory.attemptedWrites.count

        directory.emit([.defaultInputChanged, .deviceListChanged])
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites.count == writesAtSuspension)
    }

    @Test("explicit resume clears the suspension and enforces again")
    func resumeClearsSuspension() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        for _ in 0 ..< MicrophoneEnforcementTuning.conflictsBeforeSuspension {
            directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
            directory.emit(.defaultInputChanged)
            await reconciler.waitForQuiescence()
        }

        await reconciler.resume()

        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
    }

    /// ⚠️ Suspension is a **latch**, not a count that ages out. If pruning the rolling window un-suspended
    /// by itself, Acta would walk straight back into the ping-pong it just backed out of.
    @Test("the counting window ageing out does not lift suspension")
    func theWindowAgeingOutDoesNotLiftSuspension() async {
        let (directory, clock, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                     defaultInput: "BuiltInMicrophoneDevice",
                                                     order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        for _ in 0 ..< MicrophoneEnforcementTuning.conflictsBeforeSuspension {
            directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
            directory.emit(.defaultInputChanged)
            await reconciler.waitForQuiescence()
        }

        clock.advance(by: MicrophoneEnforcementTuning.conflictWindow + 1)
        await reconciler.wake()

        #expect(await reconciler.state.status ==
            .suspended(conflicts: MicrophoneEnforcementTuning.conflictsBeforeSuspension))
    }

    @Test("a long enough quiet period lifts suspension at the next trigger")
    func aQuietPeriodLiftsSuspension() async {
        let (directory, clock, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                     defaultInput: "BuiltInMicrophoneDevice",
                                                     order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        for _ in 0 ..< MicrophoneEnforcementTuning.conflictsBeforeSuspension {
            directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
            directory.emit(.defaultInputChanged)
            await reconciler.waitForQuiescence()
        }
        let writesAtSuspension = directory.attemptedWrites.count

        clock.advance(by: MicrophoneEnforcementTuning.quietResetInterval)
        await reconciler.wake()

        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
        #expect(directory.attemptedWrites.count == writesAtSuspension + 1)
    }

    // MARK: - Pause, disable, and in-flight writes

    @Test("pausing issues no compensating write")
    func pausingIssuesNoCompensatingWrite() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        let writesBefore = directory.attemptedWrites

        await reconciler.pause()
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.emit([.defaultInputChanged, .deviceListChanged])
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites == writesBefore)
        #expect(await reconciler.state.status == .paused)
    }

    @Test("disabling issues no compensating write and unsubscribes")
    func disablingIssuesNoCompensatingWrite() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["BuiltInMicrophoneDevice"])
        await reconciler.enable()
        let writesBefore = directory.attemptedWrites

        await reconciler.disable()

        #expect(directory.attemptedWrites == writesBefore)
        #expect(await reconciler.state.status == .disabled)
        #expect(directory.subscriberCount == 0)
    }

    /// A pause landing while a write is being verified: the completion must produce no follow-up write
    /// and no false success. ⚠️ It cannot un-issue the write already made — the requirement is what
    /// happens *after* it, not a rollback.
    @Test("a pause during an in-flight write stops the pass without publishing success")
    func pauseDuringAnInFlightWriteStopsThePass() async {
        let (directory, clock, reconciler) = harness(devices: [.usbMic(), .builtInMic()],
                                                     defaultInput: "00-00-5E-00-53-01:input",
                                                     order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
        directory.setWritesTakeEffect(false)
        let steps = Steps()
        clock.onSleep { _ in
            if steps.next() == 1 { Task { await reconciler.pause() } }
        }
        await reconciler.enable()
        await reconciler.waitForQuiescence()

        // The USB write was issued before the pause and cannot be un-issued; nothing followed it.
        #expect(directory.attemptedWrites == ["USBAudioDevice_UID"])
        #expect(await reconciler.state.status == .paused)
    }

    @Test("a disable during an in-flight write stops the pass without publishing success")
    func disableDuringAnInFlightWriteStopsThePass() async {
        let (directory, clock, reconciler) = harness(devices: [.usbMic(), .builtInMic()],
                                                     defaultInput: "00-00-5E-00-53-01:input",
                                                     order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
        directory.setWritesTakeEffect(false)
        let steps = Steps()
        clock.onSleep { _ in
            if steps.next() == 1 { Task { await reconciler.disable() } }
        }
        await reconciler.enable()
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites == ["USBAudioDevice_UID"])
        #expect(await reconciler.state.status == .disabled)
        #expect(directory.subscriberCount == 0)
    }

    /// A preference edit landing mid-write: the stale completion publishes nothing, and the *new*
    /// preference is what the actual result is reconciled against.
    @Test("a preference edit during an in-flight write is reconciled against the new preference")
    func aPreferenceEditDuringAnInFlightWriteWins() async {
        let (directory, clock, reconciler) = harness(devices: [.usbMic(), .builtInMic()],
                                                     defaultInput: "00-00-5E-00-53-01:input",
                                                     order: ["USBAudioDevice_UID"])
        directory.setWritesTakeEffect(false)
        let steps = Steps()
        clock.onSleep { _ in
            if steps.next() == 1 {
                directory.setWritesTakeEffect(true)
                Task { await reconciler.setOrder(["BuiltInMicrophoneDevice"]) }
            }
        }
        await reconciler.enable()
        await reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites.last == "BuiltInMicrophoneDevice")
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
    }

    // MARK: - The override and what may retire it

    @Test("the override retires when its device disconnects")
    func theOverrideExpiresOnDisconnect() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"],
                                                 override: "00-00-5E-00-53-01:input")
        await reconciler.enable()
        #expect(await reconciler.priority.override == "00-00-5E-00-53-01:input")

        directory.setDevices([.builtInMic()])
        directory.setDefaultInput(.device(uid: "BuiltInMicrophoneDevice"))
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        #expect(await reconciler.priority.override == nil)
        #expect(await reconciler.state.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
    }

    /// ⚠️ **An incomplete snapshot is not a disconnect.** One driver that will not answer must not retire
    /// a *Use now* the user is still wearing.
    @Test("the override survives an incomplete snapshot that omits its device")
    func theOverrideSurvivesAnIncompleteSnapshot() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "BuiltInMicrophoneDevice",
                                                 order: ["BuiltInMicrophoneDevice"],
                                                 override: "00-00-5E-00-53-01:input")
        await reconciler.enable()

        directory.setDevices([.builtInMic()], uninspectable: ["00-00-5E-00-53-01:input"])
        directory.emit(.deviceListChanged)
        await reconciler.waitForQuiescence()

        #expect(await reconciler.priority.override == "00-00-5E-00-53-01:input")
    }

    /// ⚠️ **The sequence that breaks a naive coalescer**: the override's device disappears and reconnects
    /// with the same UID while one pass is still running, so the next snapshot contains it and looks
    /// like nothing happened. The override must still have expired.
    @Test("a disconnect observed during a pass expires the override even after the device returns")
    func aDisconnectDuringAPassSurvivesCoalescing() async {
        let (directory, clock, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                     defaultInput: "BuiltInMicrophoneDevice",
                                                     order: ["BuiltInMicrophoneDevice"],
                                                     override: "00-00-5E-00-53-01:input")
        // A write that never converges keeps the first pass suspended long enough for the two device-list
        // notifications to be delivered into it and coalesced.
        directory.setWritesTakeEffect(false)
        directory.setDefaultInput(.device(uid: "BuiltInMicrophoneDevice"))
        let steps = Steps()
        clock.onSleep { _ in
            switch steps.next() {
            case 1:
                directory.setDevices([.builtInMic()])
                directory.emit(.deviceListChanged)
            case 2:
                directory.setDevices([.builtInMic(), .airPods()])
                directory.emit(.deviceListChanged)
            default:
                break
            }
        }
        await reconciler.enable()
        await reconciler.waitForQuiescence()

        #expect(await reconciler.priority.override == nil)
    }

    // MARK: - Nothing to choose

    @Test("an empty priority list is waiting, not an error")
    func anEmptyListWaits() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: [])
        await reconciler.enable()

        #expect(await reconciler.state.status == .waitingForPreferredDevice)
        #expect(directory.attemptedWrites.isEmpty)
    }

    @Test("a machine with no default-eligible input reports exactly that")
    func noEligibleDeviceIsItsOwnStatus() async {
        let (directory, _, reconciler) = harness(devices: [.teamsLoopback()],
                                                 defaultInput: nil,
                                                 order: ["MSLoopbackDriverDevice_UID"])
        await reconciler.enable()

        #expect(await reconciler.state.status == .noEligibleDevice)
        #expect(directory.attemptedWrites.isEmpty)
    }

    // MARK: - The state stream

    @Test("states() replays the current state and then every distinct one")
    func statesReplaysAndThenStreams() async {
        let (directory, _, reconciler) = harness(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input",
                                                 order: ["BuiltInMicrophoneDevice"])
        var iterator = await reconciler.states().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.status == .disabled)

        await reconciler.enable()
        let second = await iterator.next()
        #expect(second?.status == .enforcing(uid: "BuiltInMicrophoneDevice"))
        #expect(second?.preferred == "BuiltInMicrophoneDevice")
        #expect(second?.actualDefault == "BuiltInMicrophoneDevice")
        _ = directory
    }
}

/// The conflict budget on its own, from literals — every case here is a sequence of timestamps a live
/// machine cannot be asked to produce.
@Suite("Conflict budget")
struct ConflictBudgetTests {
    @Test("fewer conflicts than the threshold does not suspend")
    func belowThresholdDoesNotSuspend() {
        var budget = ConflictBudget()
        for i in 0 ..< (MicrophoneEnforcementTuning.conflictsBeforeSuspension - 1) {
            #expect(budget.recordConflict(at: Double(i)) == false)
        }
        #expect(budget.isSuspended == false)
    }

    @Test("the threshold inside the window suspends, and reports the count")
    func thresholdInsideTheWindowSuspends() {
        var budget = ConflictBudget()
        var tripped = false
        for i in 0 ..< MicrophoneEnforcementTuning.conflictsBeforeSuspension {
            tripped = budget.recordConflict(at: Double(i))
        }
        #expect(tripped)
        #expect(budget.isSuspended)
        #expect(budget.conflictCount == MicrophoneEnforcementTuning.conflictsBeforeSuspension)
    }

    @Test("conflicts spread wider than the window never reach the threshold")
    func conflictsOutsideTheWindowDoNotAccumulate() {
        var budget = ConflictBudget()
        let step = MicrophoneEnforcementTuning.conflictWindow + 1
        for i in 0 ..< (MicrophoneEnforcementTuning.conflictsBeforeSuspension + 2) {
            #expect(budget.recordConflict(at: Double(i) * step) == false)
        }
        #expect(budget.isSuspended == false)
    }

    @Test("suspension outlives the counting window")
    func suspensionIsALatch() {
        var budget = ConflictBudget()
        for i in 0 ..< MicrophoneEnforcementTuning.conflictsBeforeSuspension {
            budget.recordConflict(at: Double(i))
        }
        // Far enough that every one of the recorded conflicts has aged out of the window.
        budget.refresh(at: MicrophoneEnforcementTuning.conflictWindow
            + Double(MicrophoneEnforcementTuning.conflictsBeforeSuspension))
        #expect(budget.isSuspended)
        #expect(budget.conflictCount == 0)
        // ⚠️ And the reported count survives the drain — see `suspendedAfter`.
        #expect(budget.suspendedAfter == MicrophoneEnforcementTuning.conflictsBeforeSuspension)
    }

    @Test("a long enough quiet period lifts the latch")
    func aQuietPeriodResetsTheLatch() {
        var budget = ConflictBudget()
        for i in 0 ..< MicrophoneEnforcementTuning.conflictsBeforeSuspension {
            budget.recordConflict(at: Double(i))
        }
        // Measured from the *last* conflict, not from zero.
        budget.refresh(at: MicrophoneEnforcementTuning.quietResetInterval
            + Double(MicrophoneEnforcementTuning.conflictsBeforeSuspension))
        #expect(budget.isSuspended == false)
    }

    @Test("reset clears the latch and the count")
    func resetClearsEverything() {
        var budget = ConflictBudget()
        for i in 0 ..< MicrophoneEnforcementTuning.conflictsBeforeSuspension {
            budget.recordConflict(at: Double(i))
        }
        budget.reset()
        #expect(budget.isSuspended == false)
        #expect(budget.conflictCount == 0)
        #expect(budget.suspendedAfter == 0)
    }
}
