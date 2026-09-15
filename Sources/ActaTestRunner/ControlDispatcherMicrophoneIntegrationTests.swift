import ActaControlProtocol
import ActaKit
import ActaRuntime
import Foundation
import Testing

// The barrier tests in `ControlDispatcherConfinementTests` drive a **fake** `ControlServing`, so they
// prove the dispatcher waits on whatever it is handed — and would pass unchanged if
// `ControlAPI.settleMicrophoneSettings()` became a no-op. That forwarding is the production half, and
// this file is where it is checked: a real `ControlAPI` over a real `MicrophoneManager` wired to a fake
// directory and a held clock. Nothing here touches `ControlAPI.shared`.
//
// ⚠️ **The parking is deterministic, not hopeful.** `TestClock.hold()` parks the application inside the
// manager, so "the acknowledgement came too early" is a fact the test can see rather than a race it
// might lose.

/// A main-actor flag, so the test can ask whether the dispatcher has answered yet.
@MainActor
private final class Answered {
    var value = false
}

@MainActor
@available(macOS 15.0, *)
@Test
func aSettingsSaveOverTheRealFacadeWaitsForTheRealManager() async {
    let harness = ControllerHarness(label: "dispatcher-settles")
    defer { harness.tearDown() }
    // ⚠️ The Mac's default is the *other* device, so enforcement has a write to make — which is what
    // gives the application a verification sleep to park on. With the default already at the top of the
    // list there is nothing to enforce and the application finishes before it can be held.
    let directory = FakeAudioDeviceDirectory(devices: [.builtInMic(), .airPods()],
                                             defaultInput: "00-00-5E-00-53-01:input")
    let clock = GatedClock()
    let manager = MicrophoneManager(wiring: MicrophoneWiring(makeDirectory: { directory },
                                                             makeClock: { clock },
                                                             makeWakeCenter: { NotificationCenter() }))
    manager.start()
    manager.refreshInventory()
    let api = ControlAPI(controller: harness.controller, microphone: manager)
    defer { api.finish() }
    let dispatcher = ControlDispatcher(service: api, confinement: .trusted)

    var wanted = api.settings
    wanted.microphonePriority = ["BuiltInMicrophoneDevice"]
    wanted.managesSystemDefaultInput = true
    // ⚠️ Away from the default, so "already there" cannot be mistaken for "applied". `.followPriority`
    // is what a fresh preference holds, and asserting *towards* it would hold before the save ran.
    wanted.captureMicrophoneChoice = .systemDefault
    api.settings = wanted
    // The precondition the whole test consumes: writing `settings` reaches the recorder alone, so the
    // manager has not seen any of this yet. Without it the assertions below would hold vacuously.
    #expect(manager.capturePreference.snapshot.choice == .followPriority,
            "the manager already had the new policy; there was nothing to wait for")

    // The write does not take, so verification retries and the application parks on the clock.
    directory.setWritesTakeEffect(false)
    clock.hold()
    let answered = Answered()
    let reply = Task { @MainActor in
        let response = await dispatcher.handle(.settingsSave)
        answered.value = true
        return response
    }

    let parked = await awaitCondition { clock.isHoldingSleeper }
    #expect(parked, "the save never reached the manager, so nothing was being waited for")
    // ⚠️ The assertion that fails when the façade's forwarding is a no-op: the application is parked, so
    // the acknowledgement must still be withheld.
    #expect(answered.value == false, "`ok` was returned while the application was still parked")
    #expect(manager.capturePreference.snapshot.choice == .followPriority)

    clock.release()
    #expect(await reply.value.result == .ok)
    // And by the time the caller has its `ok`, the policy a recording would resolve against is the new
    // one — which is the entire claim the acknowledgement is making.
    #expect(manager.capturePreference.snapshot.choice == .systemDefault)
    #expect(manager.capturePreference.priority.order == ["BuiltInMicrophoneDevice"])
}
