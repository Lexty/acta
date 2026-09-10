import ActaKit
@testable import ActaRuntime
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
            makeClock: { TestClock() }
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
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
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
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
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
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
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
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
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
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
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
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.usbMic()], defaultInput: nil)
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
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
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

    // MARK: - Shutdown

    /// ⚠️ **The name says "this app's consumers", not "the HAL listeners", because the second would be
    /// false.** `CoreAudioDeviceDirectory` removes its raw registrations only in `deinit`; cancelling a
    /// subscription removes a subscriber. The manager and reconciler keep the directory alive, and in
    /// production the manager is a singleton, so those registrations live until the process exits.
    /// What is guaranteed, and what this asserts, is that nothing in Acta reads or writes through the
    /// directory afterwards.
    @Test("shutdown stops this app's consumers, awaited")
    func shutdownStopsTheAppsConsumers() async {
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
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
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
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
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
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
    /// until this task nothing did: it was an endpoint with no caller. What a test can reach is that the
    /// source is installed while monitoring and removed on shutdown; the notification itself needs a
    /// human to sleep a Mac, and is listed as such in the plan.
    @Test("the wake source is installed while monitoring and removed on shutdown")
    func theWakeSourceFollowsMonitoring() async {
        let (_, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                        defaultInput: "BuiltInMicrophoneDevice")
        #expect(manager.isObservingWake == false)

        manager.start()
        #expect(manager.isObservingWake)

        await manager.shutdown()
        #expect(manager.isObservingWake == false)
    }

    // MARK: - Enforcement is opt-in

    /// ⚠️ Constructing the manager must not start writing anything. Feature (B) changes state every
    /// other application on the machine depends on, so it is off until asked.
    @Test("monitoring alone writes nothing")
    func monitoringDoesNotEnforce() async {
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
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
        let (_, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()], defaultInput: nil)
        let harness = ControllerHarness(label: "microphone-route")
        let api = ControlAPI(controller: harness.controller, microphone: manager)

        #expect(api.microphone === manager)
    }

    // MARK: - Failure is reported, never mistaken for an empty machine

    @Test("an enumeration failure keeps the known devices and says so")
    func anEnumerationFailureIsNotAnEmptyMachine() {
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
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
        let (directory, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
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
