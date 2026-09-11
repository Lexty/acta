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

    /// A harness whose reconciler can be **held mid-pass**, so a command can be observed in flight
    /// instead of being assumed to have been.
    @available(macOS 15.0, *)
    private func gatedHarness(devices: [AudioInputDevice], defaultInput: String?)
        -> (FakeAudioDeviceDirectory, GatedClock, MicrophoneManager, ControlAPI, ControlViewModel) {
        let directory = FakeAudioDeviceDirectory(devices: devices, defaultInput: defaultInput)
        let clock = GatedClock()
        let manager = MicrophoneManager(wiring: MicrophoneWiring(makeDirectory: { directory },
                                                                 makeClock: { clock },
                                                                 makeWakeCenter: { NotificationCenter() }))
        manager.start()
        manager.refreshInventory()
        let api = ControlAPI(controller: ControllerHarness(label: "menu-gated").controller,
                             microphone: manager)
        let model = ControlViewModel(api: api)
        model.refreshMicrophone()
        return (directory, clock, manager, api, model)
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

    /// ⚠️ **An older Enable must not outlive a newer Off**, and the first version of this test did not
    /// arrange that at all: both commands were queued in one main-actor turn, its "settled" condition
    /// was already true at setup, and **replacing the entire command body with a no-op still passed it**
    /// — a review measured that, three runs out of three. It asserted that a machine which had never
    /// been enabled was not enabled.
    ///
    /// So the overlap is now built and *proved*: the reconciler is held parked on its verification
    /// deadline, the hold itself is the evidence the Enable entered, and the Off is issued against a
    /// genuinely enabled machine.
    @Test("an Enable held in flight cannot re-enable after the Off that followed it")
    @available(macOS 15.0, *)
    func aStaleEnableDoesNotWin() async {
        let (directory, clock, manager, api, model) =
            gatedHarness(devices: [.builtInMic(), .airPods()], defaultInput: "00-00-5E-00-53-01:input")

        // ⚠️ The write must not settle, or verification converges on its first read and never sleeps —
        // there would be nothing to hold, and the overlap would again be imaginary.
        directory.setWritesTakeEffect(false)
        clock.hold()
        model.setManagingSystemInput(true)

        // ⚠️ The evidence the previous version lacked: the Enable is *in* the reconciler and parked.
        let held = await awaitCondition { clock.isHoldingSleeper }
        #expect(held, "the Enable never reached the reconciler — nothing was overlapped")
        #expect(directory.attemptedWrites.isEmpty == false,
                "enforcement never wrote the Mac's input, so it was never really on")

        model.setManagingSystemInput(false)
        clock.release()

        let settled = await awaitCondition {
            MainActor.assumeIsolated { api.settings.managesSystemDefaultInput } == false
        }
        #expect(settled, "the Off was never persisted — it returns on the next launch")
        // ⚠️ Asked of the reconciler, and awaited: the Enable's own settings save is still working its
        // way through the manager's apply chain at this point, so sampling once would be sampling a
        // race rather than the outcome.
        let disabled = await awaitAsyncCondition { await manager.reconciler.isEnabled == false }
        #expect(disabled, "the released Enable re-enabled management after the user's Off")
    }

    /// ⚠️ **Pause withdraws permission to write, and a revocation that waits for the operation it is
    /// meant to interrupt is not one.** Every microphone command shared a single queue, so a Pause
    /// clicked while a *Use now* was parked on its verification deadline did not reach the reconciler
    /// until that pass had finished — and the pass then performed one more write, which is exactly what
    /// the plan says Pause prevents. Found by review; the queue is now per decision kind.
    @Test("Pause reaches the reconciler while a Use now is still parked")
    @available(macOS 15.0, *)
    func pauseInterruptsAnInflightUseNow() async {
        let (directory, clock, manager, _, model) =
            gatedHarness(devices: [.builtInMic(), .airPods()], defaultInput: "BuiltInMicrophoneDevice")
        _ = await manager.enableManagement()
        model.refreshMicrophone()

        directory.setWritesTakeEffect(false)
        clock.hold()
        model.useMicrophoneNow("00-00-5E-00-53-01:input")
        let held = await awaitCondition { clock.isHoldingSleeper }
        #expect(held, "the Use now never reached the reconciler — nothing was interrupted")

        model.pauseMicrophoneManagement()
        let paused = await awaitEnforcement(manager) { $0.status == .paused }
        #expect(paused != nil, "Pause waited behind the very operation it exists to interrupt")

        let writesAtPause = directory.attemptedWrites
        clock.release()
        await manager.reconciler.waitForQuiescence()
        #expect(directory.attemptedWrites == writesAtPause,
                "the released pass wrote the Mac's input after the user had paused")
    }

    /// ⚠️ **A settings save is a read-modify-write of the whole value, so a suspension inside it
    /// discards whatever landed during the hop.** The priority save read `RecordingSettings`, then
    /// awaited the enablement, then wrote the copy back — and a capture choice the user made in between
    /// was overwritten by the stale snapshot. A review measured 15 of 20 runs losing it. Repeated here
    /// for the same reason: the window is real but narrow, and one iteration would be a coin toss
    /// dressed as a test.
    @Test("a priority save cannot overwrite a capture choice made after it")
    @available(macOS 15.0, *)
    func aPrioritySaveDoesNotUndoANewerCaptureChoice() async {
        let controller = ControllerHarness(label: "menu-choice")
        defer { controller.tearDown() }

        for iteration in 0 ..< 20 {
            let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                       defaultInput: "BuiltInMicrophoneDevice")
            manager.start()
            let api = ControlAPI(controller: controller.controller, microphone: manager)
            defer { api.finish() }
            var reset = api.settings
            reset.microphonePriority = []
            reset.captureMicrophoneChoice = .followPriority
            api.settings = reset
            api.saveSettings()

            let model = ControlViewModel(api: api)
            directory.setDevices([.builtInMic(), .usbMic()])
            manager.refreshInventory()
            model.refreshMicrophone()

            model.togglePreferred("USBAudioDevice_UID")
            // Land the choice while the priority command is suspended — the interleaving the defect
            // needed, arranged rather than hoped for.
            _ = await awaitCondition {
                MainActor.assumeIsolated { manager.capturePreference.priority.order }
                    == ["USBAudioDevice_UID"]
            }
            model.setCaptureChoice(.systemDefault)

            let settled = await awaitCondition {
                MainActor.assumeIsolated { api.settings.microphonePriority } == ["USBAudioDevice_UID"]
            }
            #expect(settled, "the priority edit never persisted (iteration \(iteration))")
            #expect(api.settings.captureMicrophoneChoice == .systemDefault,
                    "a priority save overwrote the newer capture choice (iteration \(iteration))")
        }
    }

    /// ⚠️ **The other half of separating the queues: a grant that has not started yet.** Once
    /// revocations stop waiting for grants, an Enable sitting behind a parked Resume is still pending
    /// when the user switches the feature off — and would run afterwards, switching it back on. Ordering
    /// cannot fix that, because the two are deliberately no longer ordered against each other. Hence the
    /// one asymmetric rule: **a revocation cancels grants issued before it; a grant never cancels a
    /// revocation.**
    @Test("an Enable still queued when the user switches the feature off never runs")
    @available(macOS 15.0, *)
    func aQueuedEnableDoesNotSurviveAnOff() async {
        let (directory, clock, manager, api, model) =
            gatedHarness(devices: [.builtInMic(), .usbMic()], defaultInput: "BuiltInMicrophoneDevice")
        _ = await manager.enableManagement()
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        await manager.pauseEnforcement()
        model.refreshMicrophone()

        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.setWritesTakeEffect(false)
        clock.hold()

        // A grant that parks, and a second grant queued behind it that has not begun.
        model.resumeMicrophoneManagement()
        let held = await awaitCondition { clock.isHoldingSleeper }
        #expect(held, "the Resume never reached the reconciler — nothing was queued behind it")
        model.setManagingSystemInput(true)

        model.setManagingSystemInput(false)
        let revoked = await awaitAsyncCondition { await manager.reconciler.isEnabled == false }
        #expect(revoked, "the Off did not withdraw permission")

        clock.release()
        await manager.reconciler.waitForQuiescence()

        // ⚠️ **A bounded wait for the *bad* outcome, not a yield count.** The queued Enable would run a
        // whole pass, so "yield sixty times and look" measured my patience rather than the fence — with
        // the fence deleted that version still passed. This waits a full second for enforcement to come
        // back on and requires that it does not.
        let reenabled = await awaitAsyncCondition(timeoutMilliseconds: 1000) {
            await manager.reconciler.isEnabled
        }
        #expect(reenabled == false,
                "an Enable queued before the Off ran after it and switched management back on")
        #expect(api.settings.managesSystemDefaultInput == false,
                "the queued Enable persisted the feature as on after the user had switched it off")
    }

    /// ⚠️ **A settings save is a granting path too, and the queue fence does not reach it.** Any
    /// command that merges its own field into `RecordingSettings` carries whatever
    /// `managesSystemDefaultInput` currently says, and saving re-applies the **whole** value — so a
    /// capture choice picked in the same turn as an Off replayed a stale `true` and re-enabled the
    /// reconciler while the Off was still completing. Measured by review at 20 runs in 20. The
    /// withdrawal is now written into the settings synchronously, before anything is enqueued.
    @Test("an unrelated settings save in the same turn cannot undo an Off")
    @available(macOS 15.0, *)
    func anotherSettingsSaveDoesNotCancelOff() async {
        let controller = ControllerHarness(label: "menu-off-save")
        defer { controller.tearDown() }

        for iteration in 0 ..< 20 {
            let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                       defaultInput: "BuiltInMicrophoneDevice")
            manager.start()
            let api = ControlAPI(controller: controller.controller, microphone: manager)
            defer { api.finish() }
            let model = ControlViewModel(api: api)
            directory.setDevices([.builtInMic(), .usbMic()])
            manager.refreshInventory()
            _ = await manager.enableManagement()
            var on = api.settings
            on.managesSystemDefaultInput = true
            on.captureMicrophoneChoice = .followPriority
            api.settings = on
            api.saveSettings()
            model.refreshMicrophone()

            // Something else takes the input, so any corrective write after the Off is observable.
            directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
            let writesAtOff = directory.attemptedWrites

            model.setManagingSystemInput(false)
            model.setCaptureChoice(.systemDefault)

            let settled = await awaitCondition {
                MainActor.assumeIsolated { api.settings.captureMicrophoneChoice } == .systemDefault
            }
            #expect(settled, "the capture choice never landed (iteration \(iteration))")
            let off = await awaitAsyncCondition { await manager.reconciler.isEnabled == false }
            #expect(off, "an unrelated save re-enabled enforcement after the Off (iteration \(iteration))")

            let stayedOff = await awaitAsyncCondition(timeoutMilliseconds: 100) {
                await manager.reconciler.isEnabled
            }
            #expect(stayedOff == false, "enforcement came back on after the Off (iteration \(iteration))")
            #expect(api.settings.managesSystemDefaultInput == false,
                    "the Off was persisted as on (iteration \(iteration))")
            let wrote = "the Mac's input was written after the user switched management off "
                + "(iteration \(iteration))"
            #expect(directory.attemptedWrites == writesAtOff, "\(wrote)")
        }
    }

    /// ⚠️ **Switching the feature off has no business replacing the priority list.** `disableManagement`
    /// passed a cached copy of the order into `configure`, so an edit that reached the reconciler while
    /// that copy was in hand was overwritten — the user's microphone gone from the persisted list, 20
    /// runs in 20. The atomic seed fixed the *enable* side; this is the same competing writer on the
    /// other side, and the answer is that Off supplies no order at all.
    @Test("switching management off does not overwrite a priority edit issued with it")
    @available(macOS 15.0, *)
    func offDoesNotOverwriteAPriorityEdit() async {
        let controller = ControllerHarness(label: "menu-off-edit")
        defer { controller.tearDown() }

        for iteration in 0 ..< 20 {
            let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                       defaultInput: "BuiltInMicrophoneDevice")
            manager.start()
            let api = ControlAPI(controller: controller.controller, microphone: manager)
            defer { api.finish() }
            let model = ControlViewModel(api: api)
            directory.setDevices([.builtInMic(), .usbMic()])
            manager.refreshInventory()
            await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
            _ = await manager.enableManagement()
            var on = api.settings
            on.managesSystemDefaultInput = true
            on.microphonePriority = ["BuiltInMicrophoneDevice"]
            api.settings = on
            api.saveSettings()
            model.refreshMicrophone()

            model.togglePreferred("USBAudioDevice_UID")
            model.setManagingSystemInput(false)

            let settled = await awaitCondition {
                MainActor.assumeIsolated { api.settings.managesSystemDefaultInput } == false
                    && MainActor.assumeIsolated { api.settings.microphonePriority }.count == 2
            }
            let persisted = api.settings.microphonePriority
            #expect(settled, "the two decisions never settled (iteration \(iteration)): \(persisted)")
            let complaint = "switching management off discarded the priority edit "
                + "(iteration \(iteration)): \(persisted)"
            #expect(persisted.contains("USBAudioDevice_UID"), "\(complaint)")
            // ⚠️ And in the reconciler, which is what actually selects a microphone. A settings value
            // that still names the edit while the reconciler has been reset to the old list would be a
            // pass over half the state.
            let reverted = await awaitAsyncCondition(timeoutMilliseconds: 100) {
                await manager.reconciler.priority.order.contains("USBAudioDevice_UID") == false
            }
            let lost = "the reconciler's list lost the edit even though the settings kept it "
                + "(iteration \(iteration))"
            #expect(reverted == false, "\(lost)")
        }
    }

    /// ⚠️ **A settings application captured *before* the Off still writes after it.** Writing the
    /// withdrawal into `api.settings` synchronously governs every *later* merge and nothing that was
    /// already captured: `applySettings` holds a whole `RecordingSettings` value, and a snapshot taken
    /// while the feature was on replays `enabled: true` whenever it finally runs. Found by review, which
    /// measured the forbidden write landing after the Off had been proved effective.
    ///
    /// The fix is not another queue: a save from a control now says which **field** it changed, and
    /// nothing else is replayed. An unrelated setting — here the segment length — reaches the microphone
    /// owner as nothing at all.
    @Test("a settings save queued before an Off cannot write the Mac's input after it")
    @available(macOS 15.0, *)
    func anAlreadyQueuedSettingsSaveCannotWriteAfterOff() async {
        let (directory, clock, manager, api, model) =
            gatedHarness(devices: [.builtInMic(), .usbMic()], defaultInput: "BuiltInMicrophoneDevice")
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        model.refreshMicrophone()

        // ⚠️ The feature must be **on and persisted on** before anything parks: the defect is a snapshot
        // captured while `managesSystemDefaultInput` was true, and a settings value that still said false
        // would carry nothing to replay.
        model.setManagingSystemInput(true)
        let on = await awaitCondition {
            MainActor.assumeIsolated { api.settings.managesSystemDefaultInput } == true
        }
        #expect(on, "the feature never got switched on and persisted")

        // Something else takes the input, so the next pass has work, cannot converge, and parks.
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.setWritesTakeEffect(false)
        clock.hold()
        directory.emit(.defaultInputChanged)
        let held = await awaitCondition { clock.isHoldingSleeper }
        #expect(held, "no pass parked — nothing was queued behind one")

        // ⚠️ An **unrelated** save, made while the feature is on, so its captured value says so. Through
        // the menu, which is the path that matters: before this it queued a whole-settings application
        // carrying `managesSystemDefaultInput = true`.
        model.segmentSecondsBinding.wrappedValue = 11

        model.setManagingSystemInput(false)
        let revoked = await awaitAsyncCondition { await manager.reconciler.isEnabled == false }
        #expect(revoked, "the Off did not withdraw permission")
        let writesAtRevocation = directory.attemptedWrites

        clock.release()
        await manager.reconciler.waitForQuiescence()
        let wroteAgain = await awaitCondition(timeoutMilliseconds: 500) {
            directory.attemptedWrites != writesAtRevocation
        }
        #expect(wroteAgain == false,
                "a settings application captured before the Off wrote the Mac's input after it")
        #expect(api.settings.managesSystemDefaultInput == false)
    }

    /// ⚠️ **A Resume queued before a Pause must not run after it.** Pause withdraws permission to write;
    /// a Resume issued earlier and still waiting behind a parked one would clear the pause, reset the
    /// conflict budget and write the Mac's input again. Exempting Pause from the fence entirely — my
    /// first correction — allowed exactly that. Pause and Off withdraw *different* permissions, and both
    /// requirements have to hold at once.
    @Test("a Resume queued before a Pause does not undo it")
    @available(macOS 15.0, *)
    func aQueuedResumeDoesNotUndoALaterPause() async {
        let (directory, clock, manager, _, model) =
            gatedHarness(devices: [.builtInMic(), .usbMic()], defaultInput: "BuiltInMicrophoneDevice")
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        _ = await manager.enableManagement()
        await manager.pauseEnforcement()
        model.refreshMicrophone()

        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.setWritesTakeEffect(false)
        clock.hold()

        model.resumeMicrophoneManagement()
        let held = await awaitCondition { clock.isHoldingSleeper }
        #expect(held, "the first Resume never parked — nothing was queued behind it")
        model.resumeMicrophoneManagement()

        model.pauseMicrophoneManagement()
        let paused = await awaitEnforcement(manager) { $0.status == .paused }
        #expect(paused != nil, "the Pause never took effect")
        let writesAtPause = directory.attemptedWrites

        clock.release()
        await manager.reconciler.waitForQuiescence()
        let resumed = await awaitEnforcement(manager, timeout: .milliseconds(500)) {
            $0.status != .paused
        }
        #expect(resumed == nil, "a Resume queued before the Pause cleared it afterwards")
        #expect(directory.attemptedWrites == writesAtPause,
                "the Mac's input was written after the user paused enforcement")
    }

    /// ⚠️ **An acknowledgement is not a command, and this is the timeline that proves it.** Switching
    /// the feature on enables it and then *saves* that fact; routing the save through the manager ran
    /// the grant a second time, as fresh work outside the permission fence that governed the first — so
    /// the completion of the very Enable a Pause was clicked on top of cleared that Pause, reset the
    /// conflict budget and wrote the Mac's input again. Checking the fence before the command body
    /// cannot cover a grant that has already entered it.
    ///
    /// ⚠️ **Two changes close this timeline and no test separates them** — measured, and recorded here
    /// rather than implied away. The adapter no longer asks the manager to apply what it has already
    /// done (`ControlAPI.persistSettings`), *and* `applyIntent` uses the pause-preserving enable. Revert
    /// either one alone and this test still passes; revert both and it fails with the reported trace,
    /// two writes and a cleared pause. They are kept as two because they answer different questions —
    /// who may command, and what an enable means for a pause — not because each is separately proved.
    @Test("persisting an Enable does not undo a Pause clicked on top of it")
    @available(macOS 15.0, *)
    func persistingAnEnableDoesNotUndoAPause() async {
        let (directory, clock, manager, _, model) =
            gatedHarness(devices: [.builtInMic(), .usbMic()], defaultInput: "00-00-5E-00-53-01:input")
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        model.refreshMicrophone()

        directory.setWritesTakeEffect(false)
        clock.hold()
        model.setManagingSystemInput(true)
        let held = await awaitCondition { clock.isHoldingSleeper }
        #expect(held, "the Enable never parked — its completion could not overlap anything")

        model.pauseMicrophoneManagement()
        let paused = await awaitEnforcement(manager) { $0.status == .paused }
        #expect(paused != nil, "the Pause never took effect")
        #expect(await manager.reconciler.isEnabled, "the feature was not on, so pausing proved nothing")
        let writesAtPause = directory.attemptedWrites

        // Writes settle again, so a second attempt would both land and be visible.
        directory.setWritesTakeEffect(true)
        clock.release()
        await manager.reconciler.waitForQuiescence()

        let cleared = await awaitEnforcement(manager, timeout: .milliseconds(500)) { $0.status != .paused }
        #expect(cleared == nil, "the Enable's own completion cleared the Pause that followed it")
        #expect(directory.attemptedWrites == writesAtPause,
                "the Mac's input was written after the user paused enforcement")
    }

    /// ⚠️ **Pause is not Off, and the revocation fence must not treat it as one.** A revocation cancels
    /// grants issued before it — an Enable still queued when the user switches the feature off must not
    /// run afterwards. But Pause *presupposes* enforcement: cancelling the Enable behind it leaves a
    /// machine that is disabled rather than paused, and the Resume that follows resumes nothing.
    @Test("pausing does not cancel the Enable it was clicked on top of")
    @available(macOS 15.0, *)
    func pausingDoesNotCancelAQueuedEnable() async {
        let (_, manager, api, model) = harness()
        model.setManagingSystemInput(true)
        model.pauseMicrophoneManagement()

        let paused = await awaitEnforcement(manager) { $0.status == .paused }
        #expect(paused != nil, "the pause never took effect")
        let enabled = await awaitAsyncCondition { await manager.reconciler.isEnabled }
        #expect(enabled, "pausing cancelled the Enable behind it, leaving the feature off, not paused")
        #expect(api.settings.managesSystemDefaultInput,
                "the feature was persisted as off after a pause, not as on and paused")
    }

    /// ⚠️ **Independent queues cannot make two writers of the same state safe**, and this is the
    /// sequence that proves it. Enabling management seeded its list from a *cached* copy of the priority
    /// and wrote the result back, so an explicit edit that reached the reconciler during that gap was
    /// replaced by the seed: the user's chosen microphone was absent from the persisted list in 20 runs
    /// out of 20. The queues were already independent — that is exactly why neither waited for the
    /// other. The decision "is the list empty, and if so seed it" now happens inside the reconciler, in
    /// one turn, against the list it owns.
    ///
    /// ⚠️ Kept alongside the *Use now* case rather than instead of it: the override and the order have
    /// different writers, and one surviving says nothing about the other.
    @Test("enabling management does not overwrite a priority edit issued with it")
    @available(macOS 15.0, *)
    func enablingDoesNotOverwriteAPriorityEdit() async {
        let controller = ControllerHarness(label: "menu-seed")
        defer { controller.tearDown() }

        for iteration in 0 ..< 20 {
            let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                       defaultInput: "BuiltInMicrophoneDevice")
            manager.start()
            let api = ControlAPI(controller: controller.controller, microphone: manager)
            defer { api.finish() }
            var reset = api.settings
            reset.microphonePriority = []
            reset.managesSystemDefaultInput = false
            api.settings = reset
            api.saveSettings()

            let model = ControlViewModel(api: api)
            directory.setDevices([.builtInMic(), .usbMic()])
            manager.refreshInventory()
            model.refreshMicrophone()

            // One main-actor turn: the user ranks a microphone and switches the feature on.
            model.togglePreferred("USBAudioDevice_UID")
            model.setManagingSystemInput(true)

            let settled = await awaitCondition {
                MainActor.assumeIsolated { api.settings.managesSystemDefaultInput } == true
                    && MainActor.assumeIsolated { api.settings.microphonePriority }.isEmpty == false
            }
            #expect(settled, "neither decision settled (iteration \(iteration))")
            let persisted = api.settings.microphonePriority
            let complaint = "enabling management discarded the user's priority edit "
                + "(iteration \(iteration)): \(persisted)"
            #expect(persisted.contains("USBAudioDevice_UID"), "\(complaint)")
            // The settings saves are applied through the manager's own chain, so the reconciler settles
            // a turn or two after the value does. Awaited rather than sampled.
            let enabled = await awaitAsyncCondition { await manager.reconciler.isEnabled }
            #expect(enabled, "management never came on (iteration \(iteration))")
        }
    }

    /// ⚠️ **A revocation must not wait for a grant of its own kind either**, and putting Enable, Resume,
    /// Off and Pause on one "management" queue left exactly that hole. Resume awaits a full
    /// reconciliation, so an Off clicked while a Resume was parked did not reach the reconciler at all —
    /// and the released Resume then wrote a fallback device before the Off ran. Found by review after
    /// the per-decision queues had already fixed the *Use now* case; the shape is the same and the
    /// earlier fix did not cover it.
    @Test("an Off reaches the reconciler while a Resume of its own kind is still parked")
    @available(macOS 15.0, *)
    func offInterruptsAnInflightResume() async {
        let (directory, clock, manager, _, model) =
            gatedHarness(devices: [.builtInMic(), .usbMic()], defaultInput: "BuiltInMicrophoneDevice")
        _ = await manager.enableManagement()
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice", "USBAudioDevice_UID"])
        await manager.pauseEnforcement()
        model.refreshMicrophone()

        // Something else takes the Mac's input while enforcement is paused, so a Resume has real work.
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.setWritesTakeEffect(false)
        clock.hold()

        model.resumeMicrophoneManagement()
        let held = await awaitCondition { clock.isHoldingSleeper }
        #expect(held, "the Resume never reached the reconciler — nothing was interrupted")

        model.setManagingSystemInput(false)
        let revoked = await awaitAsyncCondition { await manager.reconciler.isEnabled == false }
        #expect(revoked, "the Off waited behind a Resume instead of withdrawing permission to write")

        let writesAtRevocation = directory.attemptedWrites
        clock.release()
        await manager.reconciler.waitForQuiescence()
        #expect(directory.attemptedWrites == writesAtRevocation,
                "the released Resume wrote the Mac's input after management had been switched off")
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

    /// ⚠️ **Two unrelated decisions must not cancel each other, and sharing one counter made them.**
    /// A single supersession counter across every exclusive command meant that picking a microphone in
    /// the same turn as switching management off **discarded the Off entirely**: it never ran, so Acta
    /// went on holding the Mac's default input after the user told it to stop. Worse than the
    /// reentrancy bug supersession was added to prevent, and reached by a shorter path.
    @Test("choosing a microphone does not withdraw an Off issued just before it")
    @available(macOS 15.0, *)
    func aUseNowDoesNotCancelAManagementOff() async {
        let (directory, manager, api, model) = harness()
        directory.setDevices([.builtInMic(), .usbMic()])
        manager.refreshInventory()
        _ = await manager.enableManagement()
        model.refreshMicrophone()
        #expect(await manager.reconciler.isEnabled, "the test never got management switched on")

        model.setManagingSystemInput(false)
        model.useMicrophoneNow("USBAudioDevice_UID")

        let settled = await awaitCondition {
            MainActor.assumeIsolated { manager.capturePreference.priority.override } == "USBAudioDevice_UID"
        }
        #expect(settled, "the Use now never landed")
        #expect(await manager.reconciler.isEnabled == false,
                "the user's Off was discarded by an unrelated microphone choice")
        #expect(api.settings.managesSystemDefaultInput == false,
                "the Off was never persisted, so it returns on the next launch")
    }

    /// The mirror image of the same defect: a management toggle must not throw away the microphone the
    /// user just picked.
    @Test("switching management does not withdraw a Use now issued just before it")
    @available(macOS 15.0, *)
    func aManagementToggleDoesNotCancelAUseNow() async {
        let (directory, manager, api, model) = harness()
        directory.setDevices([.builtInMic(), .usbMic()])
        manager.refreshInventory()
        model.refreshMicrophone()

        model.useMicrophoneNow("USBAudioDevice_UID")
        model.setManagingSystemInput(true)

        let settled = await awaitCondition {
            MainActor.assumeIsolated { api.settings.managesSystemDefaultInput } == true
        }
        #expect(settled, "management never came on")
        #expect(await manager.reconciler.isEnabled)
        #expect(manager.capturePreference.priority.override == "USBAudioDevice_UID",
                "the microphone the user picked was discarded by an unrelated management toggle")
    }

    /// ⚠️ **No HAL event accompanies a recording starting.** `recordingFrom` is read from the
    /// controller, so the microphone stream — which listens to the device inventory and to enforcement —
    /// cannot see it change. An open menu that subscribed and then watched only that stream showed the
    /// pin it happened to hold forever: naming a microphone after the recording had stopped.
    @Test("an open menu follows the recording pin, which no device event announces")
    @available(macOS 15.0, *)
    func anOpenMenuFollowsTheRecordingPin() async {
        let controller = ControllerHarness(label: "menu-pin")
        defer { controller.tearDown() }
        let (_, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                           defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        let api = ControlAPI(controller: controller.controller, microphone: manager)
        defer { api.finish() }
        let model = ControlViewModel(api: api)
        let subscription = Task { await model.subscribe() }
        defer { subscription.cancel() }

        api.start(title: "Pinned")
        let pinned = await awaitCondition {
            MainActor.assumeIsolated { model.microphone.recordingFrom?.uid } == "BuiltInMicrophoneDevice"
        }
        #expect(pinned, "the open menu never learned which microphone the recording came up on")

        await api.stopAndWait()
        let cleared = await awaitCondition {
            MainActor.assumeIsolated { model.microphone.recordingFrom } == nil
        }
        #expect(cleared, "the menu went on naming a microphone after the recording had stopped")
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
