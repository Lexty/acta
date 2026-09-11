import ActaKit
@testable import ActaRuntime
import AppKit
import Foundation
import Testing

/// Ownership, tested **behaviourally**.
///
/// ⚠️ **Counting constructors would prove nothing here.** "One reconciler exists" is not the property
/// that matters; "monitoring is running before anyone opens the menu, survives a recording ending, and
/// is not duplicated by a menu that is built and torn down on every click" is. Each test below is one
/// of those sentences.
///
/// No test may touch `MicrophoneManager.shared` — it reaches the real CoreAudio, the same rule
/// `ControlAPI.shared` carries.
@Suite("Microphone manager ownership")
@MainActor
struct MicrophoneManagerTests {
    // MARK: - The shipped wiring, as a claim a test can read back

    /// ⚠️ The point of `MicrophoneWiring` being a value rather than a hard-coded constructor call: you
    /// cannot ask a default argument what it would have passed.
    @Test("the live wiring builds the real HAL directory and the real clock")
    func liveWiringIsTheRealThing() {
        #expect(MicrophoneWiring.live.makeDirectory() is CoreAudioDeviceDirectory)
        #expect(MicrophoneWiring.live.makeClock() is SystemClock)
        #expect(MicrophoneWiring.live.makeWakeCenter() === NSWorkspace.shared.notificationCenter)
    }

    /// ⚠️ **One directory for the process, and this is the test that says so.** Two would mean two sets
    /// of HAL listeners and two reconcilers racing each other for the same property — Acta fighting
    /// itself. The factory is called once, in `init`, unlike `RecordingDependencies`' factories which
    /// are called once *per recording* because a capture source belongs to exactly one.
    @Test("the directory factory is called exactly once for the manager's whole life")
    func theDirectoryIsBuiltOnce() async {
        let first = FakeAudioDeviceDirectory(devices: [.builtInMic()], defaultInput: nil)
        let builds = Steps()
        // ⚠️ Every call after the first mints a **different** directory, so a factory called more than
        // once is visible as an identity change rather than netting out invisibly.
        let manager = MicrophoneManager(wiring: MicrophoneWiring(
            makeDirectory: { builds.next() == 1 ? first : FakeAudioDeviceDirectory() },
            makeClock: { TestClock() },
            makeWakeCenter: { NotificationCenter() }
        ))
        manager.start()
        manager.start()
        await manager.enableEnforcement()
        manager.refreshInventory()
        // Touch every path that could be tempted to build its own.
        _ = manager.deviceReader.enumerateInputDevices()

        #expect(builds.count == 1)
        // The half handed to a recording is *the same object* the reconciler writes through — two
        // directories would mean two sets of HAL listeners and two writers for one property.
        #expect(manager.deviceReader as AnyObject === first as AnyObject)
    }

    // MARK: - Monitoring starts without a menu and without a recording

    @Test("monitoring is running before anything opens a menu or starts a recording")
    func monitoringStartsAtLaunch() {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                defaultInput: "BuiltInMicrophoneDevice")
        #expect(directory.subscriberCount == 0)

        manager.start()

        #expect(directory.subscriberCount == 1)
        #expect(manager.inventory.devices.map(\.uid) == ["BuiltInMicrophoneDevice", "00-00-5E-00-53-01:input"])
        #expect(manager.inventory.observedDefault == .device(uid: "BuiltInMicrophoneDevice"))
    }

    /// The menu is built and torn down on every click. A second `start()` must change nothing.
    @Test("starting twice neither duplicates nor restarts the subscription")
    func startIsIdempotent() {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        manager.start()
        manager.start()

        #expect(directory.subscriberCount == 1)
        // ⚠️ `subscriberCount` alone cannot see this: a replaced subscription cancels itself on deinit,
        // so re-registering on every menu click still shows exactly one live subscriber — while the
        // real HAL takes a fresh listener registration each time.
        #expect(directory.observeCount == 1)
    }

    /// ⚠️ **What "opening and closing the menu" actually is, mechanically**: a consumer takes a stream
    /// and drops it. That must not touch the manager's own subscription to the HAL.
    @Test("a consumer subscribing and going away does not disturb monitoring")
    func aConsumerComingAndGoingLeavesMonitoringAlone() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                defaultInput: "BuiltInMicrophoneDevice")
        manager.start()

        for _ in 0 ..< 3 {
            var iterator = manager.inventories().makeAsyncIterator()
            _ = await iterator.next()
        }

        #expect(directory.subscriberCount == 1)
        #expect(manager.inventory.devices.count == 1)
    }

    // MARK: - Both consumers, one directory

    /// The inventory and the reconciler subscribe independently: two subscriptions on one directory,
    /// and a change reaches both.
    @Test("both consumers receive the change, from the one shared directory")
    func bothConsumersSeeTheChange() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        await manager.enableEnforcement()
        #expect(directory.subscriberCount == 2)

        // The headset arrives and macOS moves the default onto it.
        directory.setDevices([.builtInMic(), .airPods()])
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.emit([.deviceListChanged, .defaultInputChanged])
        await manager.reconciler.waitForQuiescence()

        // The reconciler put it back...
        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
        // ...and the inventory saw the new device **through its own subscription**. ⚠️ Pulling
        // `refreshInventory()` here instead would assert that enumeration works and nothing about
        // whether anything was ever delivered.
        let delivered = await awaitInventory(manager) { $0.devices.count == 2 }
        #expect(delivered != nil, "the inventory's own subscription never delivered the change")
    }

    /// ⚠️ **A degraded observation is not just another reason to re-read.** It says the subscription is
    /// live but *incomplete* — a per-device readiness listener could not be installed — so the very
    /// transition that listener existed to catch will never arrive. Handling it as a plain refresh
    /// republishes a clean inventory and the failure vanishes; and it is a different event from
    /// `observe()` itself failing, which is why one field is not enough on its own.
    @Test("a partial-observation failure survives a successful refresh")
    func aDegradedObservationIsNotSwallowedByASuccessfulRefresh() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                defaultInput: "BuiltInMicrophoneDevice")
        manager.start()

        directory.setDevices([.usbMic()])
        directory.emit(.observationDegraded(reason: "readiness listener refused"))

        // Waiting for the USB device proves the callback actually ran; no manual refresh rescues it.
        let delivered = await awaitInventory(manager) { $0.devices.map(\.uid) == ["USBAudioDevice_UID"] }
        #expect(delivered != nil, "the degradation event never reached the inventory")
        #expect(manager.inventory.observationDegraded == "readiness listener refused")
        #expect(manager.inventory.failure == nil)
    }

    /// ⚠️ A recording's device selection gets the **read-only** half. `AudioDeviceReading` has no
    /// `setDefaultInput`, so "a recording never enforces" is a fact about the type rather than a rule
    /// somebody has to remember. Nothing here can assert what does not compile — the test that a
    /// recording gets this half is that this is the type it is handed.
    @Test("a recording is handed the reading half, and it observes the same directory")
    func aRecordingGetsTheReadingHalf() {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.usbMic()], defaultInput: nil)
        manager.start()

        let reader: any AudioDeviceReading = manager.deviceReader
        guard case .devices(let devices, _) = reader.enumerateInputDevices() else {
            Issue.record("the reading half must enumerate the same devices")
            return
        }

        #expect(devices.map(\.uid) == ["USBAudioDevice_UID"])
        #expect(directory.enumerationCount >= 1)
    }

    /// A recording-side observation coming and going must leave the manager's own subscription intact —
    /// this is "a recording stop/restart does not remove the manager's subscription", with the recording
    /// standing in as what it actually does to the directory.
    @Test("a recording's observation coming and going leaves the manager subscribed")
    func aRecordingsObservationDoesNotDisturbTheManager() {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                defaultInput: "BuiltInMicrophoneDevice")
        manager.start()

        for _ in 0 ..< 3 {
            guard case .observing(let subscription) = manager.deviceReader.observe({ _ in }) else {
                Issue.record("the reading half must be observable")
                return
            }
            #expect(directory.subscriberCount == 2)
            subscription.cancel()
        }

        #expect(directory.subscriberCount == 1)
    }

    /// ⚠️ **The capture promise must not depend on permission to enforce globally.** With feature (B)
    /// off the reconciler is unsubscribed by design and its pass returns before expiry ever runs, so a
    /// *Use now* outlived its headset forever and Acta went on trying to record from a device that had
    /// gone. The inventory is the only observer in that state, so it owns this.
    @Test("a capture override expires on a proved departure even with feature (B) off")
    func theCaptureOverrideExpiresWithFeatureBOff() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                   defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        await manager.useNow(uid: "00-00-5E-00-53-01:input")
        #expect(manager.capturePreference.priority.override == "00-00-5E-00-53-01:input")
        #expect(await manager.reconciler.isEnabled == false)

        directory.setDevices([.builtInMic()])
        directory.emit(.deviceListChanged)
        // ⚠️ Waiting on the **published inventory**, not spinning on the override. The expiry happens
        // inside the same `refreshInventory` call that publishes, so this is ordered rather than
        // sampled — polling the override with `Task.yield()` made the test itself flaky, which is the
        // one thing a test may not be.
        let delivered = await awaitInventory(manager) { $0.devices.count == 1 }
        #expect(delivered != nil, "the departure was never delivered")

        #expect(manager.capturePreference.priority.override == nil, "the override outlived its device")
    }

    /// A smoke test for the wiring: a *Use now* issued after an observed leave-and-return survives.
    ///
    /// ⚠️ **It does not prove the ordering guard** — the removal here is consumed before any override
    /// exists, so the comparison is never reached, and its negative control passes. The guard itself is
    /// pinned in `MicrophoneReconcilerHardCaseTests.expiryIsOrderedAgainstUseNow`, where the sequence
    /// numbers are controllable. Recorded rather than left to read as coverage.
    @Test("a departure observed before Use now does not retire it")
    @MainActor
    func aStaleDepartureDoesNotRetireANewerUseNow() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                   defaultInput: "BuiltInMicrophoneDevice")
        manager.start()

        // The headset drops out and returns, both observed, with no override in force.
        directory.setDevices([.builtInMic()])
        directory.emit(.deviceListChanged)
        _ = await awaitInventory(manager) { $0.devices.count == 1 }
        directory.setDevices([.builtInMic(), .airPods()])
        directory.emit(.deviceListChanged)
        _ = await awaitInventory(manager) { $0.devices.count == 2 }

        await manager.useNow(uid: "00-00-5E-00-53-01:input")

        #expect(manager.capturePreference.priority.override == "00-00-5E-00-53-01:input")
    }

    /// ⚠️ The other half: an **incomplete** snapshot proves nothing, and must leave the override alone.
    @Test("an incomplete snapshot does not expire a capture override")
    func anIncompleteSnapshotKeepsTheCaptureOverride() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                   defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        await manager.useNow(uid: "00-00-5E-00-53-01:input")

        directory.setDevices([.builtInMic()], uninspectable: ["00-00-5E-00-53-01:input"])
        directory.emit(.deviceListChanged)
        await awaitInventory(manager) { $0.uninspectable.isEmpty == false }

        #expect(manager.capturePreference.priority.override == "00-00-5E-00-53-01:input")
    }

    /// ⚠️ **The hole that made a list edit unreachable.** The capture preference used to be copied only
    /// by the deduplicated enforcement-status mirror, so with feature (B) off an edit republished the
    /// same `.disabled` state, emitted nothing, and never arrived — permanently.
    @Test("a list edit reaches capture with feature (B) off")
    func aListEditReachesCaptureWithFeatureBOff() async {
        let (_, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .usbMic()],
                                                           defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        #expect(await manager.reconciler.isEnabled == false)

        await manager.setPriorityOrder(["USBAudioDevice_UID"])

        // Asserted on the command's completion, not after a wait: the command finishing is what has to
        // mean the capture resolver can see the change.
        #expect(manager.capturePreference.priority.order == ["USBAudioDevice_UID"])
    }

    // MARK: - Shutdown

    /// ⚠️ **The name says "this app's consumers", not "the HAL listeners", because the second would be
    /// false.** `CoreAudioDeviceDirectory` removes its raw registrations only in `deinit`; cancelling a
    /// subscription removes a subscriber. The manager and reconciler keep the directory alive, and in
    /// production the manager is a singleton, so those registrations live until the process exits.
    /// What is guaranteed, and what this asserts, is that nothing in Acta reads or writes through the
    /// directory afterwards.
    @Test("shutdown stops this app's consumers, awaited")
    func shutdownStopsTheAppsConsumers() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                defaultInput: "00-00-5E-00-53-01:input")
        manager.start()
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        await manager.enableEnforcement()
        #expect(directory.subscriberCount == 2)

        await manager.shutdown()
        // ⚠️ **The main actor is held here on purpose.** The old synchronous shutdown kicked off an
        // unstructured `Task { await disable() }` and returned; any incidental `await` afterwards —
        // including the `await` in the assertion below — hands that task the suspension it needs and
        // rescues the bug. Blocking first is what makes "it was already true when shutdown returned"
        // a claim rather than a coin toss.
        holdMainActor()
        #expect(directory.subscriberCount == 0)
        #expect(await manager.reconciler.isEnabled == false)
    }

    /// The defect the awaited shutdown exists for: a device change arriving in the window the old
    /// version left open produced a corrective write **after** shutdown had supposedly finished.
    @Test("nothing is written after shutdown returns")
    func noWriteEscapesAfterShutdown() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        await manager.enableEnforcement()

        await manager.shutdown()
        holdMainActor()
        let writesAtShutdown = directory.attemptedWrites
        #expect(directory.subscriberCount == 0, "the reconciler still held its subscription on return")

        // Exactly the change that would have provoked a correction a moment earlier.
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.emit([.deviceListChanged, .defaultInputChanged])
        await manager.reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites == writesAtShutdown)
    }

    /// ⚠️ **Cancelling a task does not withdraw a value it has already been handed.** The mirror can be
    /// suspended holding a state received before cancellation and publish it afterwards, into a manager
    /// that has shut down. Joining the task and fencing on the lifetime epoch is what closes it; here
    /// the state change is issued before shutdown and must not land after it.
    @Test("a state in flight when shutdown runs does not land afterwards")
    func theMirrorCannotPublishAfterShutdown() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        await manager.enableEnforcement()
        _ = await awaitEnforcement(manager) { $0.status == .enforcing(uid: "BuiltInMicrophoneDevice") }

        // Issued before shutdown, so the mirror may already be holding it.
        await manager.reconciler.pause()
        await manager.shutdown()
        let afterShutdown = manager.enforcement

        // Give any surviving mirror turn every chance to run.
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(manager.enforcement.status == afterShutdown.status)
        #expect(directory.subscriberCount == 0)
    }

    /// ⚠️ Sleep is the one interval during which the world changes with **no HAL notification
    /// delivered**, so the reconciler's `wake` trigger is worthless without a source pulling it — and
    /// until this task nothing did: it was an endpoint with no caller.
    @Test("the wake source is installed while monitoring and removed on shutdown")
    func theWakeSourceFollowsMonitoring() async {
        let (_, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                           defaultInput: "BuiltInMicrophoneDevice")
        #expect(manager.isObservingWake == false)

        manager.start()
        #expect(manager.isObservingWake)

        await manager.shutdown()
        #expect(manager.isObservingWake == false)
    }

    /// ⚠️ **Registration lifetime is not the behaviour, and asserting only it left the handler's whole
    /// body untested** — replacing it with a no-op passed the suite. I had claimed this needed a
    /// sleeping Mac; it does not. A synthetic post into the manager's own notification centre exercises
    /// the real installed handler, and only *actual* OS sleep/wake stays manual.
    @Test("a wake reconciles a world that changed with no notification delivered")
    func aWakeReconcilesWhatSleepHid() async {
        let (directory, _, center, manager) = makeTestMicrophoneManager(
            devices: [.builtInMic(), .airPods()],
            defaultInput: "BuiltInMicrophoneDevice"
        )
        manager.start()
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        await manager.enableEnforcement()
        #expect(directory.attemptedWrites.isEmpty)

        // Exactly what sleep looks like from here: the world moved and nothing was reported.
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        // ⚠️ Waiting for `enforcing(built-in)` would prove nothing on its own: that is already the
        // state, and a stream replays it immediately. The evidence of *fresh* reconciliation is the
        // write that did not exist a moment ago.
        let corrected = await awaitCondition { directory.attemptedWrites == ["BuiltInMicrophoneDevice"] }
        #expect(corrected, "the wake handler never reconciled")
        // The mirror is one hop behind the reconciler by construction, so this waits too rather than
        // sampling the instant the write lands.
        let mirrored = await awaitCondition {
            MainActor.assumeIsolated { manager.enforcement.status } == .enforcing(uid: "BuiltInMicrophoneDevice")
        }
        #expect(mirrored, "the enforcement mirror never caught up")
    }

    /// ⚠️ **The drain is not redundant with `verify()`'s per-iteration guard, and this is what tells
    /// them apart.** The guard stops the next property *read* when verification resumes; the drain
    /// waits for the owned pass to actually **finish**. Both leave the read count unchanged across
    /// shutdown, which is why the read-count tests cannot distinguish them — and why I had wrongly
    /// recorded the drain as untested-and-probably-redundant. Holding the sleep makes the difference
    /// observable: without the drain, shutdown returns while its own pass is still suspended.
    @Test("shutdown waits for the pass it owns, not merely for its next read")
    func shutdownWaitsForTheOwnedPass() async {
        let directory = FakeAudioDeviceDirectory(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input")
        let clock = GatedClock()
        let manager = MicrophoneManager(wiring: MicrophoneWiring(makeDirectory: { directory },
                                                                 makeClock: { clock },
                                                                 makeWakeCenter: { NotificationCenter() }))
        // Accepted, never takes effect: the verification sleeps, and the gate parks it there.
        directory.setWritesTakeEffect(false)
        clock.hold()
        manager.start()
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])

        let enabling = Task { await manager.enableEnforcement() }
        let parked = await awaitCondition { clock.isHoldingSleeper }
        #expect(parked, "the verification never reached a sleep to be held at")

        // ⚠️ Bounded release, so a **repaired** implementation — which waits for this pass — finishes
        // instead of hanging the suite. A test whose correct path deadlocks is not a test.
        let releaser = Task { try? await Task.sleep(for: .milliseconds(300)); clock.release() }

        await manager.shutdown()
        let stillSuspended = clock.isHoldingSleeper

        releaser.cancel()
        clock.release()
        await enabling.value

        #expect(stillSuspended == false,
                "shutdown returned while the pass it owns was still suspended")
    }

    /// ⚠️ Removing the observer stops *future* notifications and does nothing about a Task this one has
    /// already queued — the same lifetime hole the inventory callback was fenced against.
    @Test("a wake already queued when shutdown runs does not act afterwards")
    func aQueuedWakeDoesNotActAfterShutdown() async {
        let (directory, _, center, manager) = makeTestMicrophoneManager(
            devices: [.builtInMic()],
            defaultInput: "BuiltInMicrophoneDevice"
        )
        manager.start()
        let enumerationsBefore = directory.enumerationCount

        // Posted while the main actor is ours, so the handler's Task is queued and cannot start.
        directory.setDevices([.usbMic()])
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await manager.shutdown()
        holdMainActor()
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(directory.enumerationCount == enumerationsBefore,
                "a queued wake re-enumerated after shutdown")
        #expect(manager.inventory.devices.map(\.uid) == ["BuiltInMicrophoneDevice"])
    }

    /// ⚠️ **`disable()` stops new work; it does not end a pass already inside its verification poll.**
    /// That poll goes on *reading* the directory, so "nothing reads or writes through the directory
    /// after shutdown" was false for the reconciler itself — the write guard caught the write and said
    /// nothing about the reads. Shutdown drains the in-flight pass now, which is only meaningful
    /// because `disable()` is awaited first.
    @Test("no read escapes an awaited shutdown, including from a verification in flight")
    func noReadEscapesAfterShutdown() async {
        let (directory, clock, _, manager) = makeTestMicrophoneManager(
            devices: [.builtInMic(), .airPods()],
            defaultInput: "00-00-5E-00-53-01:input"
        )
        // Accepted, never takes effect: the verification polls until its deadline.
        directory.setWritesTakeEffect(false)
        manager.start()
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])

        let steps = Steps()
        let shutdownDone = Steps()
        // ⚠️ **Sampled inside the shutdown task, the instant it returns.** Sampling after a yield loop
        // in the test instead lets the verification finish first and the assertion becomes vacuous —
        // which is exactly what happened, and both negative controls passed against it.
        let readsAtReturn = IntBox()
        clock.onSleep { _ in
            guard steps.next() == 1 else { return }
            Task { @MainActor in
                await manager.shutdown()
                readsAtReturn.set(directory.defaultReadCount)
                _ = shutdownDone.next()
            }
        }
        await manager.enableEnforcement()
        // Let the shutdown task, started from inside the verification, run to completion.
        for _ in 0 ..< 500 where shutdownDone.count == 0 { await Task.yield() }
        #expect(shutdownDone.count == 1, "shutdown never completed")

        holdMainActor()
        for _ in 0 ..< 50 { await Task.yield() }

        #expect(directory.defaultReadCount == readsAtReturn.value,
                "the verification kept polling the directory after shutdown returned")
    }

    // MARK: - Enforcement is opt-in

    /// ⚠️ Constructing the manager must not start writing anything. Feature (B) changes state every
    /// other application on the machine depends on, so it is off until asked.
    @Test("monitoring alone writes nothing")
    func monitoringDoesNotEnforce() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                defaultInput: "00-00-5E-00-53-01:input")
        manager.start()
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        directory.emit([.deviceListChanged, .defaultInputChanged])
        await manager.reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites.isEmpty)
        #expect(manager.enforcement.status == .disabled)
        // The inventory is live regardless — the chooser has to work with feature (B) switched off.
        #expect(manager.inventory.devices.count == 2)
    }

    // MARK: - The route the menu uses

    @Test("the façade hands the menu the same manager it was built with")
    @available(macOS 15.0, *)
    func theFacadeExposesTheManager() {
        let (_, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()], defaultInput: nil)
        let harness = ControllerHarness(label: "microphone-route")
        let api = ControlAPI(controller: harness.controller, microphone: manager)

        #expect(api.microphone === manager)
    }

    // MARK: - Failure is reported, never mistaken for an empty machine

    @Test("an enumeration failure keeps the known devices and says so")
    func anEnumerationFailureIsNotAnEmptyMachine() {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        #expect(manager.inventory.devices.count == 2)

        directory.failEnumeration(reason: "kAudioHardwareUnknownPropertyError")
        manager.refreshInventory()

        #expect(manager.inventory.failure == "kAudioHardwareUnknownPropertyError")
        #expect(manager.inventory.devices.count == 2)
    }

    @Test("a failed subscription is recorded rather than looking like a quiet machine")
    func aFailedSubscriptionIsRecorded() {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                defaultInput: "BuiltInMicrophoneDevice")
        directory.failObservation(reason: "AudioObjectAddPropertyListenerBlock failed")
        manager.start()

        #expect(manager.inventory.observationDegraded == "AudioObjectAddPropertyListenerBlock failed")
        // ⚠️ And it is not confused with an enumeration failure: the devices were read fine.
        #expect(manager.inventory.failure == nil)
        #expect(manager.inventory.devices.count == 1)

        // A registration that failed once is retried, not given up on.
        directory.allowObservation()
        manager.refreshInventory()

        #expect(directory.subscriberCount == 1)
        #expect(manager.inventory.observationDegraded == nil)
    }
}

/// ⚠️ **A synchronous mirror that only some paths update is a mirror that lies on the others.**
/// `managementEnabled` exists so a settings write can read the enablement without suspending; a review
/// found `stopEnforcement()` leaving it `true` while the reconciler was disabled, which is exactly the
/// stale answer the mirror was introduced to replace.
@Test("a stopped manager does not claim enforcement is still enabled")
@MainActor
@available(macOS 15.0, *)
func aStoppedManagerDoesNotClaimEnforcementEnabled() async {
    let (_, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                       defaultInput: "BuiltInMicrophoneDevice")
    manager.start()
    _ = await manager.enableManagement()
    #expect(manager.managementEnabled, "the test never got management on")

    await manager.stopEnforcement()

    #expect(await manager.reconciler.isEnabled == false)
    #expect(manager.managementEnabled == false,
            "the mirror still claimed enforcement was on after the manager had stopped it")
}

/// The same for the two direct switches, which also never assigned it.
@Test("the direct enforcement switches keep the mirror honest")
@MainActor
@available(macOS 15.0, *)
func theDirectEnforcementSwitchesUpdateTheMirror() async {
    let (_, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                       defaultInput: "BuiltInMicrophoneDevice")
    manager.start()
    await manager.enableEnforcement()
    #expect(manager.managementEnabled)
    await manager.disableEnforcement()
    #expect(manager.managementEnabled == false)
}

/// ⚠️ **The manager's application queue is a second writer with its own timeline**, and the adapter's
/// permission fence cannot reach it. A settings value captured before an explicit Off — which is how
/// the control protocol and the launch application deliver settings — wrote the Mac's input after the
/// Off had been proved effective. A final persisted "off" does not undo an OS write that already
/// escaped.
@Test("a settings application queued before an explicit Off does not write after it")
@MainActor
@available(macOS 15.0, *)
func aQueuedManagementFieldDoesNotWriteAfterAnOff() async {
    let directory = FakeAudioDeviceDirectory(devices: [.builtInMic(), .usbMic()],
                                             defaultInput: "BuiltInMicrophoneDevice")
    let clock = GatedClock()
    let manager = MicrophoneManager(wiring: MicrophoneWiring(makeDirectory: { directory },
                                                             makeClock: { clock },
                                                             makeWakeCenter: { NotificationCenter() }))
    manager.start()
    manager.refreshInventory()
    await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
    _ = await manager.enableManagement()

    // Something else takes the input, so the next pass has work, cannot converge, and parks.
    directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
    directory.setWritesTakeEffect(false)
    clock.hold()
    manager.applySettings(RecordingSettings(microphonePriority: ["BuiltInMicrophoneDevice"],
                                            managesSystemDefaultInput: true))
    let held = await awaitCondition { clock.isHoldingSleeper }
    #expect(held, "no application parked — nothing was queued behind one")

    // Captured while the feature is on, queued behind the parked application.
    manager.applySettings(RecordingSettings(microphonePriority: ["BuiltInMicrophoneDevice"],
                                            managesSystemDefaultInput: true))

    await manager.disableManagement()
    #expect(await manager.reconciler.isEnabled == false, "the Off did not take effect")
    let writesAtOff = directory.attemptedWrites

    directory.setWritesTakeEffect(true)
    clock.release()
    await manager.reconciler.waitForQuiescence()

    let wroteAgain = await awaitCondition(timeoutMilliseconds: 500) {
        directory.attemptedWrites != writesAtOff
    }
    #expect(wroteAgain == false,
            "a management field queued before the Off wrote the Mac's input after it")
    #expect(await manager.reconciler.isEnabled == false)
}

/// ⚠️ **Feature (B)'s promise, through the entry point production actually uses.** `ActaApp` hands the
/// persisted settings to `applySettings` at launch — the *queued* form — and every other test drives
/// the direct `apply`. After several rounds of rework around that queue (a management generation, a
/// field-scoped variant, an acknowledgement path that deliberately applies nothing), the one thing none
/// of them checked was that a user who had switched the feature on still gets it switched on when the
/// app starts.
@Test("launching with management persisted on enforces the saved list")
@MainActor
@available(macOS 15.0, *)
func launchingWithManagementOnEnforcesTheSavedList() async {
    let directory = FakeAudioDeviceDirectory(devices: [.builtInMic(), .airPods()],
                                             defaultInput: "00-00-5E-00-53-01:input")
    let clock = TestClock()
    let manager = MicrophoneManager(wiring: MicrophoneWiring(makeDirectory: { directory },
                                                             makeClock: { clock },
                                                             makeWakeCenter: { NotificationCenter() }))
    manager.start()
    manager.refreshInventory()

    // Exactly what the app does on launch: the whole persisted value, through the queued form.
    manager.applySettings(RecordingSettings(microphonePriority: ["BuiltInMicrophoneDevice"],
                                            managesSystemDefaultInput: true))

    let enforced = await awaitCondition {
        directory.attemptedWrites == ["BuiltInMicrophoneDevice"]
    }
    let wrote = "launching did not put the Mac's input back on the saved list: "
        + "\(directory.attemptedWrites)"
    #expect(enforced, "\(wrote)")
    let enabled = await awaitAsyncCondition { await manager.reconciler.isEnabled }
    #expect(enabled, "the feature was persisted on and did not come on at launch")
    // ⚠️ Awaited, not sampled: `managementEnabled` is assigned at the *end* of the application, after
    // the reconciler is already enforcing, so reading it the moment enforcement starts reads the gap
    // rather than the outcome. The mirror is synchronous to read, not instantaneous to update.
    let mirrored = await awaitCondition { MainActor.assumeIsolated { manager.managementEnabled } }
    #expect(mirrored, "the synchronous mirror never caught up with the launch application")
}

/// ⚠️ **The converse of the per-field authority, and the thing it could plausibly break.** Invalidating
/// a field whose intent has moved must not turn into "a direct command always beats a settings
/// application": one submitted *after* the edit is the newer intent and has to win. Without this, the
/// authority would quietly make the control protocol and the launch application unable to change
/// anything the menu had ever touched.
@Test("a settings application submitted after a direct edit still wins")
@MainActor
@available(macOS 15.0, *)
func aSettingsApplicationSubmittedAfterADirectEditWins() async {
    let (_, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .usbMic()],
                                                       defaultInput: "BuiltInMicrophoneDevice")
    manager.start()
    manager.refreshInventory()

    // Direct commands first — the menu's path.
    await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
    manager.setCaptureChoice(.followPriority)

    // Then a whole-settings application, submitted afterwards: the newer intent for both fields.
    manager.applySettings(RecordingSettings(microphonePriority: ["USBAudioDevice_UID"],
                                            managesSystemDefaultInput: false,
                                            captureMicrophoneChoice: .systemDefault))

    let applied = await awaitAsyncCondition {
        guard await manager.reconciler.priority.order == ["USBAudioDevice_UID"] else { return false }
        return await MainActor.run { manager.capturePreference.snapshot.choice == .systemDefault }
    }
    #expect(applied, "a settings application submitted after a direct edit was discarded as stale")
}

/// A manager parked mid-pass, for the two seeding timelines below.
@MainActor
@available(macOS 15.0, *)
private func makeGatedManager(devices: [AudioInputDevice], defaultInput: String?)
    -> (FakeAudioDeviceDirectory, GatedClock, MicrophoneManager) {
    let directory = FakeAudioDeviceDirectory(devices: devices, defaultInput: defaultInput)
    let clock = GatedClock()
    let manager = MicrophoneManager(wiring: MicrophoneWiring(makeDirectory: { directory },
                                                             makeClock: { clock },
                                                             makeWakeCenter: { NotificationCenter() }))
    manager.start()
    manager.refreshInventory()
    return (directory, clock, manager)
}

/// ⚠️ **A command that seeded nothing must not speak for the list.** `enableManagement` advanced the
/// order authority on every call, but seeding only replaces an *empty* list — so the ordinary case, a
/// user with a list who switches the feature on, withdrew a priority change it had never replaced. The
/// persisted value kept the change while the reconciler was left on the old one.
@Test("enabling with a list already set does not discard a pending order change")
@MainActor
@available(macOS 15.0, *)
func aNoOpSeedDoesNotDiscardAPendingOrderChange() async {
    let (directory, clock, manager) = makeGatedManager(devices: [.builtInMic(), .usbMic()],
                                                       defaultInput: "BuiltInMicrophoneDevice")
    await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
    _ = await manager.enableManagement()

    // Something else takes the input, so the next application has work and parks.
    directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
    directory.setWritesTakeEffect(false)
    clock.hold()
    manager.applySettings(RecordingSettings(microphonePriority: ["BuiltInMicrophoneDevice"],
                                            managesSystemDefaultInput: true))
    let held = await awaitCondition { clock.isHoldingSleeper }
    #expect(held, "no application parked — nothing was queued behind one")

    // A later request that really does change the list, and then an Enable that seeds nothing.
    manager.applySettings(RecordingSettings(microphonePriority: ["USBAudioDevice_UID"],
                                            managesSystemDefaultInput: true))
    _ = await manager.enableManagement()

    clock.release()
    let applied = await awaitAsyncCondition {
        await manager.reconciler.priority.order == ["USBAudioDevice_UID"]
    }
    #expect(applied, "a no-op Enable withdrew a priority change it had not replaced")
}

/// The converse, and the protection that must survive the fix above: an Enable that **really seeds**
/// — an empty list — does replace the list, and an application captured before it must not put the old
/// one back.
@Test("an Enable that really seeds does speak for the list")
@MainActor
@available(macOS 15.0, *)
func aRealSeedClaimsTheOrder() async {
    let (directory, clock, manager) = makeGatedManager(devices: [.builtInMic(), .usbMic()],
                                                       defaultInput: "USBAudioDevice_UID")
    await manager.setPriorityOrder(["USBAudioDevice_UID"])
    _ = await manager.enableManagement()

    directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
    directory.setWritesTakeEffect(false)
    clock.hold()
    manager.applySettings(RecordingSettings(microphonePriority: ["USBAudioDevice_UID"],
                                            managesSystemDefaultInput: true))
    let held = await awaitCondition { clock.isHoldingSleeper }
    #expect(held, "no application parked")

    // ⚠️ The order of these three lines is the whole test. Emptying the list claims the order itself,
    // so a request submitted *before* it is invalidated by that and proves nothing about seeding. The
    // request has to be captured **after** the emptying and **before** the seed, so the only thing that
    // can supersede it is the seed.
    await manager.setPriorityOrder([])
    manager.applySettings(RecordingSettings(microphonePriority: ["USBAudioDevice_UID"],
                                            managesSystemDefaultInput: true))
    let seeded = await manager.enableManagement()
    #expect(seeded.isEmpty == false, "the Enable seeded nothing, so it claimed no order to defend")
    #expect(seeded != ["USBAudioDevice_UID"], "the seed happened to reproduce the old list")

    clock.release()
    let replaced = await awaitAsyncCondition(timeoutMilliseconds: 300) {
        await manager.reconciler.priority.order != seeded
    }
    #expect(replaced == false,
            "a request captured before a real seed overwrote the list that seed had just chosen")
}

/// ⚠️ **The acknowledgement-versus-command distinction again, now in the return from seeding.** The
/// order authority used to be claimed *after* the reconciliation the Enable awaited, so a request
/// submitted once the seed had already changed the list — but before the manager heard back — was
/// invalidated by that older intent finishing late. The claim now happens in the same synchronous turn
/// as the decision that justifies it.
@Test("a request submitted after a seed changed the list is not cancelled by the seed finishing late")
@MainActor
@available(macOS 15.0, *)
func aDelayedSeedAcknowledgementDoesNotCancelANewerOrder() async {
    let (directory, clock, manager) = makeGatedManager(devices: [.builtInMic(), .usbMic()],
                                                       defaultInput: "00-00-5E-00-53-01:input")
    directory.setWritesTakeEffect(false)
    clock.hold()

    // The Enable is left running: it seeds, then parks on its verification deadline.
    let enable = Task { @MainActor in await manager.enableManagement() }
    let seeded = await awaitAsyncCondition { await manager.reconciler.priority.order.isEmpty == false }
    #expect(seeded, "the seed never reached the list, so there was nothing to submit after it")
    #expect(await manager.reconciler.isEnabled)

    // ⚠️ **Both of these happen in one main-actor turn, and that is the whole test.** Releasing the
    // clock lets the Enable finish, but its acknowledgement needs the main actor — which this turn is
    // holding — so the request below is submitted while that acknowledgement is pending. Submitting it
    // first and releasing later lets the request simply finish before the acknowledgement, which proves
    // nothing: written that way, the test passed against the defect.
    clock.release()
    // ⚠️ **Wait for the reconciler to finish without giving up the main actor.** Releasing and
    // submitting in one turn is not enough: which of the two pending main-actor continuations runs
    // first then decides the outcome, and written that way the test passed against the defect. Blocking
    // here — bounded — leaves the Enable's acknowledgement *ready* to run and held back only by this
    // turn, so the request below is unambiguously submitted while it is still pending.
    let quiescent = DispatchSemaphore(value: 0)
    let reconciler = manager.reconciler
    Task.detached { await reconciler.waitForQuiescence(); quiescent.signal() }
    #expect(blockUntilSignalled(quiescent),
            "the reconciler never settled, so nothing was pending when the request was submitted")

    manager.applySettings(RecordingSettings(microphonePriority: ["USBAudioDevice_UID"],
                                            managesSystemDefaultInput: true,
                                            captureMicrophoneChoice: .systemDefault))

    _ = await enable.value

    let applied = await awaitAsyncCondition {
        await manager.reconciler.priority.order == ["USBAudioDevice_UID"]
    }
    #expect(applied, "the Enable's late acknowledgement cancelled a request submitted after its seed")
    // The choice landing proves the request reached its final publication rather than being dropped.
    #expect(manager.capturePreference.snapshot.choice == .systemDefault)
}

/// ⚠️ **"Was the writer" is not "is still the writer".** The main-actor mirror of the list used to be
/// corrected from the seed's own return value whenever this command had done the seeding — but both of
/// those flags describe the seed, neither notices a newer `setPriorityOrder` arriving during the
/// reconciliation the Enable awaited, and the returned order was read before that await. So a cleared
/// list came back as a stale non-empty one, and the next Enable then declined to seed a list that
/// really was empty: the user is left on "waiting for a preferred microphone" with a perfectly good
/// built-in microphone attached. A stale mirror is worse than no mirror, because the decision it feeds
/// looks well-founded.
@Test("a seed completing late does not restore a list that was cleared while it ran")
@MainActor
@available(macOS 15.0, *)
func aSeedCompletionDoesNotRestoreAClearedKnownOrder() async {
    let (directory, clock, manager) = makeGatedManager(devices: [.builtInMic(), .usbMic()],
                                                       defaultInput: "00-00-5E-00-53-01:input")
    directory.setWritesTakeEffect(false)
    clock.hold()

    let enable = Task { @MainActor in await manager.enableManagement() }
    let seeded = await awaitAsyncCondition { await manager.reconciler.priority.order.isEmpty == false }
    #expect(seeded, "the seed never reached the list, so there was nothing to supersede")

    // The user clears the list while that Enable is still reconciling.
    await manager.setPriorityOrder([])
    #expect(await manager.reconciler.priority.order.isEmpty, "the list was not actually cleared")
    #expect(manager.capturePreference.priority.order.isEmpty)

    clock.release()
    _ = await enable.value
    #expect(await manager.reconciler.priority.order.isEmpty,
            "the late completion changed the list itself, not only the mirror")

    // The proof that the mirror matters: an empty list must seed again.
    await manager.disableManagement()
    let returned = await manager.enableManagement()
    #expect(returned.isEmpty == false,
            "a stale mirror made the manager decline to seed a list that really was empty: \(returned)")
    #expect(await manager.reconciler.priority.order.isEmpty == false)
}
