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
func aQueuedCallbackCannotReviveADeadDirectory() {
    // The callbacks capture `self` weakly precisely so that a HAL delivery arriving after the owner has
    // gone does nothing at all — no delivery, and no fresh registration behind the coordinator's back.
    let hal = FakeAudioHAL()
    hal.setDevices([(id: 5, uid: "USBAudioDevice_UID")])
    let recorder = Recorder()

    do {
        let directory = CoreAudioDeviceDirectory(hal: hal)
        guard case .observing(let token) = directory.observe({ recorder.append($0) }) else {
            Issue.record("expected a subscription"); return
        }
        withExtendedLifetime(token) { #expect(!hal.liveWatches.isEmpty) }
    }

    let deliveredBefore = recorder.changes.count
    let addedBefore = hal.added.count
    hal.fire(.deviceList)   // nothing is registered any more, so this is a no-op by construction
    hal.fire(.defaultInput)
    #expect(recorder.changes.count == deliveredBefore, "a dead directory delivered a change")
    #expect(hal.added.count == addedBefore, "a dead directory registered something new")
}
