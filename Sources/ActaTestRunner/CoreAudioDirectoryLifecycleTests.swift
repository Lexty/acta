@testable import ActaRuntime
import Foundation
import Testing

// The **production** coordinator's registration bookkeeping, driven through a scripted HAL.
//
// Collapsing the directory onto one serial queue deleted a whole matrix of possible schedules, but it
// proved nothing about what happens when the HAL *refuses* a registration — and against a real Mac
// those paths are unreachable, because a working machine does not decline to install a listener on
// demand. What is left to get wrong is bookkeeping: whether the successful half of a partial install is
// removed, whether a degraded subscription still says so, whether everything retained is released when
// the directory dies. Each of those failures is silent.

@Test
func aRefusedSecondSystemListenerRemovesTheFirstAndReportsFailure() {
    // ⚠️ Half a subscription is worse than none: a directory that reports device-list changes but never
    // default-input changes is precisely the "unchanged winner, moved default" blind spot the
    // reconciler cannot see past — and it would look like a healthy subscription.
    let hal = FakeAudioHAL()
    hal.refuse(.defaultInput, reason: "scripted refusal")
    let directory = CoreAudioDeviceDirectory(hal: hal)

    guard case .failed(let reason) = directory.observe({ _ in }) else {
        Issue.record("a refused registration must not present as a live subscription")
        return
    }
    #expect(reason.contains("default-input"))
    #expect(hal.added == [.deviceList, .defaultInput], "both registrations should have been attempted")
    #expect(hal.removed == [.deviceList], "the half that succeeded must be removed")
    #expect(hal.liveWatches.isEmpty, "nothing may be left registered after a failed install")
}

@Test
func aRefusedReadinessListenerDegradesTheSubscriptionWithoutBreakingIt() {
    // The subscription is genuinely usable — the system listeners are installed — but one device's
    // readiness will not be watched, and the subscriber is told so rather than left to infer it from
    // silence. Note the rollback: a device watched for liveness but not for its stream configuration is
    // watched for the wrong half of "still a usable microphone", so the half that took is removed.
    let hal = FakeAudioHAL()
    hal.setDevices([(id: 42, uid: "BuiltInMicrophoneDevice")])
    hal.refuse(.deviceStreams(42), reason: "scripted refusal")
    let directory = CoreAudioDeviceDirectory(hal: hal)

    let recorder = Recorder()
    guard case .observing(let token) = directory.observe({ recorder.append($0) }) else {
        Issue.record("the subscription itself must still succeed")
        return
    }
    withExtendedLifetime(token) {
        let degraded = recorder.changes.contains { change in
            if case .observationDegraded = change { return true }
            return false
        }
        #expect(degraded, "a listener that would not install must reach the subscriber, not just the log")
        #expect(hal.removed.contains(.deviceAlive(42)), "the half that took must be rolled back")
        #expect(!hal.liveWatches.contains(.deviceAlive(42)))
    }
}

@Test
func cancellingFromInsideADegradationCallbackIsSafeAndFinal() {
    // ⚠️ The token has to be one the subscriber **already holds**: a callback delivered synchronously
    // during the first `observe` cannot use a token that `observe` has not returned yet. So the first
    // subscription is established against an empty machine, and the degradation is provoked afterwards
    // by a device-list callback.
    let hal = FakeAudioHAL()
    let directory = CoreAudioDeviceDirectory(hal: hal)

    let recorder = Recorder()
    let box = TokenBox()
    guard case .observing(let token) = directory.observe({ change in
        recorder.append(change)
        if case .observationDegraded = change { box.cancelAll() }
    }) else {
        Issue.record("expected a subscription"); return
    }
    box.store([token])

    hal.setDevices([(id: 7, uid: "USBAudioDevice_UID")])
    hal.refuse(.deviceAlive(7), reason: "scripted refusal")
    hal.fire(.deviceList)   // → refresh → readiness refusal → degradation → the handler cancels itself
    directory.waitForPendingDeliveries()

    let before = recorder.changes.count
    #expect(before > 0, "the degradation should have been delivered")
    hal.fire(.deviceList)
    directory.waitForPendingDeliveries()
    #expect(recorder.changes.count == before, "delivery continued after a cancellation from inside a handler")
}

@Test
func droppingTheDirectoryRemovesEverythingItStillHeld() {
    // ⚠️ Every registration the directory holds must be released when it dies, and `deinit` is the only
    // teardown there is — the last-subscriber teardown was deleted deliberately. CoreAudio keeps
    // calling a block until a *matching* removal, so anything missed here fires forever against freed
    // state.
    let hal = FakeAudioHAL()
    hal.setDevices([(id: 11, uid: "BuiltInMicrophoneDevice")])

    do {
        let directory = CoreAudioDeviceDirectory(hal: hal)
        guard case .observing(let token) = directory.observe({ _ in }) else {
            Issue.record("expected a subscription"); return
        }
        withExtendedLifetime(token) {
            #expect(hal.liveWatches.count == 4,
                    "two system listeners and two per-device listeners should be live")
        }
    }

    #expect(hal.liveWatches.isEmpty, "the directory died holding registrations it never removed")
    #expect(Set(hal.removed) == Set([.deviceList, .defaultInput, .deviceAlive(11), .deviceStreams(11)]))
}

@Test
func aDeliveryThatOutlivesItsOwnerDoesNothingAtAll() {
    // ⚠️ **This test replaces one that could not fail.** Its first version dropped the directory and
    // then asked the fake to fire — but the fake only fires *live* registrations, and deinit had removed
    // them all, so zero closures ran and the assertions passed against nothing. The case that matters is
    // the opposite one: a delivery captured while the registration was live, invoked after the owner is
    // gone. That is what a real HAL callback already in flight looks like.
    let hal = FakeAudioHAL()
    hal.setDevices([(id: 3, uid: "BuiltInMicrophoneDevice")])
    let recorder = Recorder()

    weak var weakDirectory: CoreAudioDeviceDirectory?
    var saved: (queue: DispatchQueue, fire: @Sendable () -> Void)?
    do {
        let directory = CoreAudioDeviceDirectory(hal: hal)
        weakDirectory = directory
        guard case .observing(let token) = directory.observe({ recorder.append($0) }) else {
            Issue.record("expected a subscription"); return
        }
        withExtendedLifetime(token) {
            saved = hal.savedDelivery(for: .deviceList)   // captured while the registration is live
            #expect(saved != nil)
        }
    }

    #expect(weakDirectory == nil, "the directory outlived its scope; the rest of this test proves nothing")
    let deliveredBefore = recorder.changes.count
    let addedBefore = hal.added.count

    // Release the delivery on its real queue — the HAL's own execution domain, not the caller's.
    let delivery = try? #require(saved)
    delivery?.queue.sync { delivery?.fire() }

    #expect(recorder.changes.count == deliveredBefore, "a delivery reached a subscriber after the owner died")
    #expect(hal.added.count == addedBefore, "a dead directory registered something new")
}

@Test
func theLastOwnerMayBeReleasedFromTheHALsOwnQueue() {
    // ⚠️ `deinit` is not guaranteed to run on the coordinator: a HAL callback's temporary strong
    // reference can be the last owner and drop it on the HAL queue. That is the ownership argument the
    // deinit comment makes, and this is the arrangement it claims to survive.
    let hal = FakeAudioHAL()
    hal.setDevices([(id: 9, uid: "USBAudioDevice_UID")])

    weak var weakDirectory: CoreAudioDeviceDirectory?
    final class Box: @unchecked Sendable { var directory: CoreAudioDeviceDirectory? }
    let box = Box()
    var halQueue: DispatchQueue?

    do {
        let directory = CoreAudioDeviceDirectory(hal: hal)
        weakDirectory = directory
        guard case .observing(let token) = directory.observe({ _ in }) else {
            Issue.record("expected a subscription"); return
        }
        // ⚠️ The **actual** queue the registration was made on, not a freshly made one with a
        // HAL-sounding name. A stand-in queue tests the shape of the arrangement; this tests the
        // arrangement.
        halQueue = hal.savedDelivery(for: .deviceList)?.queue
        token.cancel()
        box.directory = directory
    }
    #expect(weakDirectory != nil, "the box should still hold the only reference")

    guard let halQueue else { Issue.record("no registration queue was captured"); return }
    halQueue.sync { box.directory = nil }

    #expect(weakDirectory == nil)
    #expect(hal.liveWatches.isEmpty, "registrations survived a release from the HAL execution domain")
}

@Test
func aDeviceReplacedUnderTheSameNumericIDRetiresTheOldListener() {
    // ⚠️ **A production bug, found by the seam rather than by the machine.** `AudioObjectID` is
    // ephemeral and the HAL may hand a recycled one to a different device; identity is the UID. The
    // refresh compared ids alone, so it kept the old listener because "42 is still present" and went on
    // labelling every readiness change with the *previous* device's UID — a listener pointed at the
    // wrong device, reporting confidently, forever.
    let hal = FakeAudioHAL()
    hal.setDevices([(id: 42, uid: "DeviceA_UID")])
    let directory = CoreAudioDeviceDirectory(hal: hal)

    let recorder = Recorder()
    guard case .observing(let token) = directory.observe({ recorder.append($0) }) else {
        Issue.record("expected a subscription"); return
    }
    withExtendedLifetime(token) {
        hal.setDevices([(id: 42, uid: "DeviceB_UID")])
        hal.fire(.deviceList)
        directory.waitForPendingDeliveries()

        #expect(hal.removed.contains(.deviceAlive(42)), "the replaced device's listener must be retired")
        hal.fire(.deviceAlive(42))
        directory.waitForPendingDeliveries()

        let labels: [String] = recorder.changes.compactMap { change in
            if case .readinessChanged(let uid) = change { return uid }
            return nil
        }
        // ⚠️ An **exact** sequence, not `allSatisfy` plus `!contains`. Both of those are true of an
        // empty array, so the pair of them would have passed a build that announced nothing at all —
        // the same vacuity that has already bitten this file once.
        #expect(labels == ["DeviceB_UID"], "expected exactly one announcement, under B's identity")
    }
}

@Test
func aRefusedRemovalIsReportedRatherThanPassingForACleanTeardown() {
    // ⚠️ The seam used to promise removal "never fails". It cannot: `AudioHardware.h` documents the call
    // as returning success or failure, and a `Void` return can only hide a refusal. The caller cannot
    // retry — but the listener really is still installed, and that must stay observable rather than
    // being indistinguishable from a clean teardown.
    let hal = FakeAudioHAL()
    hal.setDevices([(id: 4, uid: "BuiltInMicrophoneDevice")])
    hal.refuseRemoval(of: .deviceAlive(4))

    do {
        let directory = CoreAudioDeviceDirectory(hal: hal)
        guard case .observing(let token) = directory.observe({ _ in }) else {
            Issue.record("expected a subscription"); return
        }
        withExtendedLifetime(token) { #expect(hal.liveWatches.count == 4) }
    }

    // Everything the HAL accepted is gone; the one it refused is still installed — which is the leak,
    // and it belongs to the HAL, not to the bookkeeping.
    #expect(hal.liveWatches == [.deviceAlive(4)])
    #expect(Set(hal.removed) == Set([.deviceList, .defaultInput, .deviceStreams(4)]))
}

@Test
func aSavedDeliveryFromAReplacedRegistrationAnnouncesNothing() {
    // ⚠️ The narrow window the coordinator guard exists for: A's readiness delivery is captured while
    // A is live, A is then replaced by B under the same numeric id, and the *saved* A delivery is
    // executed afterwards — which is what a HAL callback already in flight during a replacement looks
    // like. Without the guard it announces A, and everything above believes the departed device just
    // changed state.
    let hal = FakeAudioHAL()
    hal.setDevices([(id: 42, uid: "DeviceA_UID")])
    let directory = CoreAudioDeviceDirectory(hal: hal)

    let recorder = Recorder()
    guard case .observing(let token) = directory.observe({ recorder.append($0) }) else {
        Issue.record("expected a subscription"); return
    }
    withExtendedLifetime(token) {
        guard let savedA = hal.savedDelivery(for: .deviceAlive(42)) else {
            Issue.record("no readiness delivery was captured for A"); return
        }

        hal.setDevices([(id: 42, uid: "DeviceB_UID")])
        hal.fire(.deviceList)
        directory.waitForPendingDeliveries()

        savedA.queue.sync { savedA.fire() }      // the in-flight callback from the replaced registration
        directory.waitForPendingDeliveries()
        hal.fire(.deviceAlive(42))               // and then a genuine one from B
        directory.waitForPendingDeliveries()

        let labels: [String] = recorder.changes.compactMap { change in
            if case .readinessChanged(let uid) = change { return uid }
            return nil
        }
        #expect(labels == ["DeviceB_UID"], "the saved delivery from A's registration announced something")
    }
}

@Test
func workQueuedWhileAliveDoesNothingOnceTheOwnerIsGone() {
    // ⚠️ The case a plain drop cannot reach: work genuinely **queued** on the coordinator while the
    // directory was alive, held there by a latch, with the owner released before it runs. Draining it
    // needs a handle to the queue that outlives the directory, which is why the queue is captured up
    // front — asking the directory to drain would itself require a live owner and prove nothing.
    let hal = FakeAudioHAL()
    hal.setDevices([(id: 6, uid: "USBAudioDevice_UID")])
    let recorder = Recorder()

    weak var weakDirectory: CoreAudioDeviceDirectory?
    var coordinator: DispatchQueue?
    let latch = DispatchSemaphore(value: 0)
    let blocked = DispatchSemaphore(value: 0)
    // ⚠️ The token deliberately **outlives** the directory. Cancelling — or letting it deinit — while
    // the coordinator is latched would deadlock, since cancellation runs there; and dropping the
    // subscription before firing would make the test vacuous, because a callback with no subscriber
    // proves nothing. Its owner reference is weak, so once the directory is gone its cancellation is a
    // no-op.
    var token: (any AudioDeviceObservation)?

    do {
        let directory = CoreAudioDeviceDirectory(hal: hal)
        weakDirectory = directory
        coordinator = directory.coordinatorQueueForTesting
        guard case .observing(let observation) = directory.observe({ recorder.append($0) }) else {
            Issue.record("expected a subscription"); return
        }
        token = observation
        // Occupy the coordinator so the callback's work is queued behind the latch rather than run.
        coordinator?.async { blocked.signal(); latch.wait() }
        blocked.wait()
        hal.fire(.deviceList)   // enqueues the coordinator hop behind the blocked block
    }

    // The owner is released while its queued work is still parked.
    #expect(weakDirectory == nil, "the directory must be gone before the queued work runs")
    let deliveredBefore = recorder.changes.count
    let addedBefore = hal.added.count

    latch.signal()
    coordinator?.sync {}   // drain through the retained handle, not through the dead directory

    #expect(recorder.changes.count == deliveredBefore, "queued work delivered after its owner died")
    #expect(hal.added.count == addedBefore, "queued work registered something after its owner died")
    _ = token
}
