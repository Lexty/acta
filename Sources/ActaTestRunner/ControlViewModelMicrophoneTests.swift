import ActaKit
@testable import ActaRuntime
import Foundation
import Testing

/// The menu **adapter** — its commands, its subscriptions and the intents it must not lose.
///
/// ⚠️ **I said this could not be tested, and that was wrong.** I recorded "ControlViewModel lives in
/// the `Acta` executable target, which SwiftPM cannot import, so nothing can reach it" as a fact about
/// the world. A review then compiled a byte-identical copy into the test target and found four defects
/// in it. The import restriction is real; the conclusion was not — the adapter is not a view, and
/// moving it into `ActaRuntime` makes it reachable without copying anything that could drift.
/// **Rendering** stays manual. Missing subscriptions, stale continuations and lost edits do not.
@Suite("Menu adapter: microphones")
@MainActor
struct ControlViewModelMicrophoneTests {
    @available(macOS 15.0, *)
    private func harness() -> (FakeAudioDeviceDirectory, MicrophoneManager, ControlAPI, ControlViewModel) {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                   defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        let controller = ControllerHarness(label: "menu-adapter").controller
        let api = ControlAPI(controller: controller, microphone: manager)
        return (directory, manager, api, ControlViewModel(api: api))
    }

    /// ⚠️ **Two clicks in one turn both read the same cached order**, and each built a whole new list
    /// from it — so adding two microphones persisted only one. The edit is an *intent* applied to the
    /// authoritative order at the moment it runs.
    @Test("two quick priority edits both survive")
    @available(macOS 15.0, *)
    func twoQuickEditsBothSurvive() async {
        let (directory, manager, _, model) = harness()
        directory.setDevices([.builtInMic(), .usbMic(), .airPods()])
        manager.refreshInventory()
        model.refreshMicrophone()

        model.togglePreferred("USBAudioDevice_UID")
        model.togglePreferred("00-00-5E-00-53-01:input")

        let landed = await awaitCondition {
            MainActor.assumeIsolated { manager.capturePreference.priority.order.count } == 2
        }
        #expect(landed, "one of the two edits was lost")
        #expect(manager.capturePreference.priority.order
            == ["USBAudioDevice_UID", "00-00-5E-00-53-01:input"])
    }

    /// ⚠️ **An older Enable must not outlive a newer Off.** Each command awaited its work and then wrote
    /// a *captured* flag into settings, so a slow Enable released after an Off persisted ON — and wrote
    /// the Mac's default input again. The same reentrancy family Task 6 fixed, one layer above it.
    @Test("an Enable completing after an Off does not re-enable management")
    @available(macOS 15.0, *)
    func aStaleEnableDoesNotWin() async {
        let (directory, manager, api, model) = harness()
        directory.setDevices([.builtInMic(), .airPods()])
        manager.refreshInventory()
        model.refreshMicrophone()

        model.setManagingSystemInput(true)
        model.setManagingSystemInput(false)

        let settled = await awaitCondition {
            MainActor.assumeIsolated { api.settings.managesSystemDefaultInput } == false
                && MainActor.assumeIsolated { model.microphone.managingSystemInput } == false
        }
        #expect(settled, "the Off never settled")

        // And nothing re-enables afterwards.
        for _ in 0 ..< 40 { await Task.yield() }
        #expect(await manager.reconciler.isEnabled == false)
        #expect(api.settings.managesSystemDefaultInput == false)
        _ = directory
    }

    /// ⚠️ **An open idle menu observed nothing.** `states()` is driven by the recording controller, and
    /// microphone state is deliberately not part of `ControlState` — so a device arriving, the Mac's
    /// input moving, enforcement suspending itself or a *Use now* expiring all went unseen until the
    /// user issued a command or reopened the menu. Refreshing after a command is not observation.
    @Test("an idle open menu sees a microphone arrive")
    @available(macOS 15.0, *)
    func anIdleMenuSeesADeviceArrive() async {
        let (directory, _, _, model) = harness()
        let subscription = Task { await model.subscribe() }
        defer { subscription.cancel() }
        _ = await awaitCondition { MainActor.assumeIsolated { model.microphone.devices.count } == 1 }

        // Nothing else happens: no command, no recording, no timer.
        directory.setDevices([.builtInMic(), .usbMic()])
        directory.emit(.deviceListChanged)

        let seen = await awaitCondition {
            MainActor.assumeIsolated { model.microphone.devices.count } == 2
        }
        #expect(seen, "the open menu never learned that a microphone was plugged in")
    }

    /// ⚠️ **An incomplete read is not an empty machine.** The projection dropped `uninspectable`, so a
    /// snapshot that admitted it could not describe a driver arrived as a successfully enumerated empty
    /// list — and the menu said "No microphones found", a settled claim about the hardware drawn from a
    /// read that said the opposite.
    @Test("an incomplete inventory does not project as an empty machine")
    @available(macOS 15.0, *)
    func anIncompleteInventoryIsNotEmptyHardware() async {
        let (directory, manager, api, model) = harness()
        directory.setDevices([], uninspectable: ["unreadable audio device"])
        manager.refreshInventory()
        model.refreshMicrophone()

        #expect(api.microphoneStatus.devices.isEmpty)
        #expect(api.microphoneStatus.uninspectable == ["unreadable audio device"])
        #expect(api.microphoneStatus.isComplete == false,
                "an incomplete read projected as a complete one")
        #expect(model.microphone.isComplete == false)
    }

    /// The converse: a machine that really was described and really has nothing.
    @Test("a complete empty enumeration is complete")
    @available(macOS 15.0, *)
    func aCompleteEmptyEnumerationIsComplete() async {
        let (directory, manager, api, model) = harness()
        directory.setDevices([])
        manager.refreshInventory()
        model.refreshMicrophone()

        #expect(api.microphoneStatus.isComplete)
        #expect(model.microphone.devices.isEmpty)
    }

    /// ⚠️ The optimistic value is the **request**, and it never drives "recording from" — a title is
    /// true the moment it is typed and a microphone is not true until capture succeeds on it.
    @Test("a Use now is held optimistically and cleared once it is in force")
    @available(macOS 15.0, *)
    func aUseNowIsHeldThenReconciled() async {
        let (directory, manager, _, model) = harness()
        directory.setDevices([.builtInMic(), .airPods()])
        manager.refreshInventory()
        model.refreshMicrophone()

        model.useMicrophoneNow("00-00-5E-00-53-01:input")
        #expect(model.pendingSelection == "00-00-5E-00-53-01:input")
        // Nothing is recording, so it must not claim to be.
        #expect(model.microphone.recordingFrom == nil)

        let settled = await awaitCondition {
            MainActor.assumeIsolated { model.pendingSelection } == nil
        }
        #expect(settled, "the request was never reconciled against what is in force")
        #expect(manager.capturePreference.priority.override == "00-00-5E-00-53-01:input")
    }
}
