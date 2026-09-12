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

    /// ⚠️ **An application already in flight republished its capture choice over a newer one.** The
    /// choice is the last thing a whole-settings application publishes, so it is the field most exposed
    /// to an intent landing while the application is suspended — and once the adapter correctly stopped
    /// re-applying its own acknowledgements, nothing restored the user's choice afterwards. A recording
    /// would then resolve under a policy the user had not chosen and *had* saved.
    @Test("an application in flight does not republish a stale capture choice")
    @available(macOS 15.0, *)
    func anInFlightApplicationDoesNotOverwriteANewerCaptureChoice() async {
        let (directory, clock, manager, api, model) =
            gatedHarness(devices: [.builtInMic(), .airPods()], defaultInput: "00-00-5E-00-53-01:input")
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        model.refreshMicrophone()

        directory.setWritesTakeEffect(false)
        clock.hold()
        var on = api.settings
        on.microphonePriority = ["BuiltInMicrophoneDevice"]
        on.managesSystemDefaultInput = true
        on.captureMicrophoneChoice = .followPriority
        api.settings = on
        api.saveSettings()
        let held = await awaitCondition { clock.isHoldingSleeper }
        #expect(held, "no application parked — nothing was in flight to overwrite anything")

        model.setCaptureChoice(.systemDefault)
        #expect(manager.capturePreference.snapshot.choice == .systemDefault,
                "the choice never took effect, so the overwrite could not be observed")
        #expect(api.settings.captureMicrophoneChoice == .systemDefault, "the choice was never saved")

        clock.release()
        await manager.reconciler.waitForQuiescence()
        let reverted = await awaitCondition(timeoutMilliseconds: 300) {
            MainActor.assumeIsolated { manager.capturePreference.snapshot.choice } == .followPriority
        }
        #expect(reverted == false,
                "the released application republished its stale capture choice over the user's")
        #expect(api.settings.captureMicrophoneChoice == .systemDefault)
    }

    /// ⚠️ **And the list-only branch applied a list a newer edit had already superseded.** Giving
    /// *management* a submission-time authority was right and incomplete: an application whose enable
    /// flag is stale still wrote its `microphonePriority`, which is only this application's intent until
    /// a newer list intent arrives. The persisted settings kept the edit while the reconciler — the
    /// thing that actually selects a microphone — was reset behind it.
    @Test("a queued application does not restore a list a newer edit replaced")
    @available(macOS 15.0, *)
    func aQueuedApplicationDoesNotRestoreASupersededList() async {
        let (directory, clock, manager, api, model) =
            gatedHarness(devices: [.builtInMic(), .usbMic()], defaultInput: "00-00-5E-00-53-01:input")
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        _ = await manager.enableManagement()
        var on = api.settings
        on.microphonePriority = ["BuiltInMicrophoneDevice"]
        on.managesSystemDefaultInput = true
        api.settings = on
        model.refreshMicrophone()

        // ⚠️ The enable above already converged, so the next pass would settle instantly and park
        // nothing. Something else has to take the input first for the application to have work.
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.setWritesTakeEffect(false)
        clock.hold()
        api.saveSettings()
        let held = await awaitCondition { clock.isHoldingSleeper }
        #expect(held, "no application parked — nothing was queued behind one")
        api.saveSettings()   // queued, and carrying the pre-edit list

        model.togglePreferred("USBAudioDevice_UID")
        // ⚠️ Two reads, and neither may borrow the other's isolation: the reconciler is an actor and
        // the settings are main-actor state, so `assumeIsolated` inside this non-isolated closure traps.
        let edited = await awaitAsyncCondition {
            guard await manager.reconciler.priority.order.contains("USBAudioDevice_UID") else {
                return false
            }
            return await MainActor.run { api.settings.microphonePriority.contains("USBAudioDevice_UID") }
        }
        #expect(edited, "the edit never completed, so nothing could supersede anything")

        model.setManagingSystemInput(false)
        let off = await awaitAsyncCondition { await manager.reconciler.isEnabled == false }
        #expect(off, "the Off never took effect")

        clock.release()
        await manager.reconciler.waitForQuiescence()
        let lost = await awaitAsyncCondition(timeoutMilliseconds: 300) {
            await manager.reconciler.priority.order.contains("USBAudioDevice_UID") == false
        }
        #expect(lost == false, "the released application restored the list the user's edit had replaced")
        #expect(api.settings.microphonePriority.contains("USBAudioDevice_UID"))
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
        // ⚠️ A longer bound than the default: this waits for a **real** recording to come up and for the
        // menu's stream to carry the pin, and the default two seconds is tight when the rest of the
        // suite is running beside it. The bound costs nothing when the condition holds.
        let pinned = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { model.microphone.recordingFrom?.uid } == "BuiltInMicrophoneDevice"
        }
        #expect(pinned, "the open menu never learned which microphone the recording came up on")

        await api.stopAndWait()
        let cleared = await awaitCondition(timeoutMilliseconds: 6000) {
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

/// The one line the menu shows without opening anything.
///
/// ⚠️ **It exists because the whole chooser had to be collapsed** — six devices, a picker and the
/// management controls pushed the menu off the bottom of the screen — and a summary is only worth
/// collapsing behind if it is true. Rendering stays manual; *what it says* does not have to.
@Suite("Menu adapter: the microphone summary")
@MainActor
struct MicrophoneSummaryTests {
    @available(macOS 15.0, *)
    private func status(devices: [AudioInputDevice] = [.builtInMic(), .airPods()],
                        priority: [String] = [],
                        override: String? = nil,
                        recordingFrom: AudioInputDevice? = nil,
                        choice: CaptureMicrophoneChoice = .followPriority,
                        systemDefault: ObservedDefaultInput = .device(uid: "BuiltInMicrophoneDevice"),
                        uninspectable: [String] = [],
                        enumerationFailure: String? = nil)
        -> ControlAPI.MicrophoneStatus {
        ControlAPI.MicrophoneStatus(devices: devices, priority: priority, override: override,
                                    preferred: nil, systemDefault: systemDefault,
                                    recordingFrom: recordingFrom, managingSystemInput: false,
                                    captureChoice: choice, enforcement: .disabled,
                                    enumerationFailure: enumerationFailure,
                                    uninspectable: uninspectable)
    }

    /// ⚠️ **"Recording from" is never said about a preference.** A title is true the moment it is typed
    /// and a microphone is not true until capture succeeds on it, so only what actually came up may be
    /// phrased in the present tense.
    @Test("a preference is phrased as intent, and only a live capture as fact")
    @available(macOS 15.0, *)
    func aPreferenceIsNotAFact() {
        #expect(status(priority: ["BuiltInMicrophoneDevice"]).captureSummary
            == "Will use MacBook Pro Microphone")
        #expect(status(priority: ["BuiltInMicrophoneDevice"], recordingFrom: .builtInMic())
            .captureSummary == "Recording from MacBook Pro Microphone")
    }

    @Test("a Use now says it is temporary")
    @available(macOS 15.0, *)
    func aUseNowSaysSo() {
        #expect(status(priority: ["BuiltInMicrophoneDevice"], override: "00-00-5E-00-53-01:input")
            .captureSummary == "Will use AirPods Pro — chosen for now")
    }

    /// ⚠️ The state a fresh install is in, and the one the collapsed menu most needs to name: nothing
    /// is chosen, so nothing will be recorded from until the user says.
    @Test("an empty list says nothing is chosen, not that nothing is available")
    @available(macOS 15.0, *)
    func anEmptyListSaysNothingIsChosen() {
        #expect(status().captureSummary == "No microphone chosen yet")
    }

    /// ...and a list whose devices have all gone is a different sentence again. Collapsing these two
    /// would tell a user with an unplugged microphone that they never picked one.
    @Test("a list with nothing available is not an empty list")
    @available(macOS 15.0, *)
    func anAbsentDeviceIsNotAnEmptyList() {
        #expect(status(devices: [.builtInMic()], priority: ["USBAudioDevice_UID"]).captureSummary
            == "None of your microphones is available")
    }

    @Test("asking for the Mac's input names the device it resolves to")
    @available(macOS 15.0, *)
    func theSystemDefaultChoiceNamesTheDevice() {
        #expect(status(choice: .systemDefault).captureSummary == "Will use MacBook Pro Microphone")
    }

    /// ⚠️ **This test blessed the very conflation its comment claimed to prevent**, and a review caught
    /// it: it asserted that a machine whose default input had never been read summarises as "No
    /// microphone available" — a settled claim about the hardware, drawn from a read that made none.
    /// The projection was calling the bare selection policy with a `String?`, so `.unread` and "there
    /// is no default" arrived as the same thing. The interpretation is shared with the live resolver
    /// now, and the assertion says what it always should have.
    @Test("a default input that was never read is not a machine with no microphone")
    @available(macOS 15.0, *)
    func anUnreadDefaultIsNotAnEmptyMachine() {
        #expect(status(devices: [.builtInMic()], choice: .systemDefault, systemDefault: .unread)
            .captureSummary == "The audio devices could not be read")
    }

    /// ⚠️ An enumeration that failed says nothing about the machine at all.
    @Test("a failed enumeration is not a machine with no microphone")
    @available(macOS 15.0, *)
    func aFailedEnumerationIsNotAnEmptyMachine() {
        #expect(status(devices: [], priority: ["BuiltInMicrophoneDevice"],
                       enumerationFailure: "scripted").captureSummary
            == "The audio devices could not be read")
    }

    /// ⚠️ And a snapshot that could not describe some driver may not claim the user's microphone is
    /// gone — the device that would not answer may be exactly the one they chose.
    @Test("an incomplete snapshot does not claim a preferred microphone is absent")
    @available(macOS 15.0, *)
    func anIncompleteSnapshotDoesNotClaimAbsence() {
        #expect(status(devices: [.builtInMic()], priority: ["USBAudioDevice_UID"],
                       uninspectable: ["a device that would not answer"]).captureSummary
            == "Some audio devices could not be read")
    }

    /// ⚠️ **The sentence that teaches the list must be true in all four combinations.** It was wrong in
    /// two of them: it promised the list governs recordings while the user had asked to follow the Mac's
    /// input, and it promised that resuming automatic selection returns to the list when in that mode it
    /// returns to the Mac's input.
    @Test("the list explanation is true in each of the four combinations")
    @available(macOS 15.0, *)
    func theListExplanationIsTrueInEachCombination() {
        let emptyList = status().listExplanation
        #expect(emptyList.contains("Tick a microphone"))

        let withList = status(priority: ["BuiltInMicrophoneDevice"]).listExplanation
        #expect(withList.contains("highest one available"))
        #expect(withList.contains("arrows"))

        let systemDefault = status(choice: .systemDefault).listExplanation
        #expect(systemDefault.contains("the Mac's input at the time they start"))
        #expect(systemDefault.contains("Recordings use the highest") == false,
                "system-default mode was told its recordings follow the list")

        let overriddenInListMode = status(priority: ["BuiltInMicrophoneDevice"],
                                          override: "00-00-5E-00-53-01:input").listExplanation
        #expect(overriddenInListMode.contains("go back to the list"))

        let overriddenInDefaultMode = status(override: "00-00-5E-00-53-01:input",
                                             choice: .systemDefault).listExplanation
        #expect(overriddenInDefaultMode.contains("go back to your recording setting"))
        #expect(overriddenInDefaultMode.contains("go back to the list") == false,
                "system-default mode was told that resuming returns it to the list")
    }

    /// ⚠️ A device that is listed but **not usable** reaches the same policy case as one that is not
    /// there at all, so the wording has to cover both: telling a user to plug in something already
    /// plugged in sends them looking in the wrong place.
    @Test("a listed but unusable device is not described as disconnected")
    @available(macOS 15.0, *)
    func anUnusableDeviceIsNotCalledDisconnected() {
        let dead = AudioInputDevice(uid: "USBAudioDevice_UID", name: "USB Microphone",
                                    transport: .usb, inputChannels: 1,
                                    canBeSystemDefault: .yes, isAlive: .no, isRunningSomewhere: false)
        #expect(status(devices: [.builtInMic(), dead], priority: ["USBAudioDevice_UID"]).captureSummary
            == "None of your microphones is available")
    }
}

/// What the always-visible line says feature (B) is doing.
///
/// ⚠️ **The line used to say "holding the Mac's input on your list" for every state except paused.**
/// `managingSystemInput` is true for suspended, refused, degraded, uncertain and still-waiting alike, so
/// a feature that had *stopped* doing what it promised reported success — and the only explanation was
/// inside a section the same change had just collapsed.
@Suite("Menu adapter: what management says it is doing")
struct ManagementSummaryTests {
    @available(macOS 15.0, *)
    private func status(_ enforcement: MicrophoneEnforcementStatus,
                        devices: [AudioInputDevice] = [.builtInMic()]) -> ControlAPI.MicrophoneStatus {
        ControlAPI.MicrophoneStatus(devices: devices, managingSystemInput: enforcement != .disabled,
                                    enforcement: enforcement)
    }

    @Test("only a verified enforcement claims to hold a device, and it names it")
    @available(macOS 15.0, *)
    func onlyEnforcingClaimsToHold() {
        #expect(status(.enforcing(uid: "BuiltInMicrophoneDevice")).managementSummary
            == "Holding the Mac's input on MacBook Pro Microphone")
        #expect(status(.enforcing(uid: "BuiltInMicrophoneDevice")).managementNeedsAttention == false)
    }

    @Test("management that is off says nothing at all")
    @available(macOS 15.0, *)
    func disabledSaysNothing() {
        #expect(status(.disabled).managementSummary == nil)
        #expect(status(.disabled).managementNeedsAttention == false)
    }

    /// ⚠️ The states that used to report success. Each says what is actually true, and each asks to be
    /// acted on — which is what keeps the Pause and Off actions on screen while the chooser is closed.
    /// ⚠️ **The two suspension causes are different facts and must not share a sentence.** Repeated
    /// *reversals* mean something was observed putting the input back; repeated *convergence failures*
    /// mean Acta's writes never visibly took at all, and nobody was seen doing anything. Telling the
    /// user "something kept changing it back" for the second is inventing a culprit — and the earlier
    /// version of these tests could not catch it, because it only asserted the text was non-empty and
    /// did not claim to be holding.
    @Test("a suspension says which kind it was, and invents no culprit")
    @available(macOS 15.0, *)
    func aSuspensionNamesItsOwnCause() {
        #expect(status(.suspended(.repeatedReversals(3))).managementSummary
            == "Stopped changing the Mac's input — something kept changing it back")
        let convergence = status(.suspended(.repeatedConvergenceFailures(3))).managementSummary
        #expect(convergence == "Stopped changing the Mac's input after repeated unsuccessful attempts")
        #expect(convergence?.contains("changing it back") != true,
                "a convergence failure was described as something changing the input back")
    }

    @Test("a stopped or refused enforcement says so and asks to be acted on")
    @available(macOS 15.0, *)
    func stoppedEnforcementSaysSo() {
        let cases: [MicrophoneEnforcementStatus] = [
            .suspended(.repeatedReversals(3)), .suspended(.repeatedConvergenceFailures(3)),
            .writesRefused(uids: ["BuiltInMicrophoneDevice"]),
            .degraded(reason: "scripted"), .uncertain(uid: "BuiltInMicrophoneDevice"),
            .waitingForPreferredDevice, .noEligibleDevice,
        ]
        for enforcement in cases {
            let summary = status(enforcement).managementSummary
            #expect(summary != nil, "\(enforcement) said nothing")
            #expect(summary?.contains("Holding the Mac's input on") != true,
                    "\(enforcement) claimed to be holding a device: \(summary ?? "")")
            #expect(status(enforcement).managementNeedsAttention,
                    "\(enforcement) did not ask to be acted on")
        }
    }

    /// ⚠️ Pause is the one non-enforcing state that is **not** a problem: the user asked for it. It says
    /// what it is without demanding attention.
    @Test("pause is reported without being treated as a fault")
    @available(macOS 15.0, *)
    func pauseIsNotAFault() {
        #expect(status(.paused).managementSummary == "Not changing the Mac's input — paused")
        #expect(status(.paused).managementNeedsAttention == false)
    }
}

/// ⚠️ **The mapping, not the interpretation.** The shared interpretation was right and both callers
/// still fed it different facts: the manager wrote a failed *default-input read* into the same field as
/// a failed *enumeration*, so a machine whose device list read perfectly but whose default input would
/// not answer was reported as one whose devices could not be read — and a recording following the
/// user's list, which needs that read not at all, was shown as unavailable. Renaming the field at the
/// projection boundary did not separate its inputs; this drives the real directory, manager and façade
/// rather than a literal observation that would bypass the very step that was wrong.
@Suite("Menu adapter: the summary over the real inventory")
@MainActor
struct MicrophoneSummaryMappingTests {
    @Test("a failed default-input read does not make a list-mode recording unavailable")
    @available(macOS 15.0, *)
    func aFailedDefaultReadDoesNotBlockListMode() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                   defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        manager.setCaptureChoice(.followPriority)
        directory.setDefaultInput(.failed(reason: "the default read failed"))
        manager.refreshInventory()

        let api = ControlAPI(controller: ControllerHarness(label: "summary-mapping").controller,
                             microphone: manager)
        defer { api.finish() }
        let status = api.microphoneStatus

        // The shipped resolver is the reference: list mode needs no default-input read.
        guard case .pinned = manager.captureResolver.resolve() else {
            Issue.record("the live resolver refused a list-mode recording it can serve"); return
        }
        #expect(status.captureSummary == "Will use MacBook Pro Microphone",
                "the menu disagreed with the resolver: \(status.captureSummary)")
        // The failure is still *reported* — combining them for display was never the problem.
        #expect(status.inventoryFailure == "the default read failed")
        #expect(status.enumerationFailure == nil)
    }

    /// The converse, which is why the failure may not simply be ignored: asking to follow the Mac's
    /// input while that read is failing must still be blocked.
    @Test("a failed default-input read still blocks following the Mac's input")
    @available(macOS 15.0, *)
    func aFailedDefaultReadStillBlocksSystemDefaultMode() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                                   defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        manager.setCaptureChoice(.systemDefault)
        directory.setDefaultInput(.failed(reason: "the default read failed"))
        manager.refreshInventory()

        let api = ControlAPI(controller: ControllerHarness(label: "summary-mapping-converse").controller,
                             microphone: manager)
        defer { api.finish() }
        #expect(api.microphoneStatus.captureSummary == "The audio devices could not be read")
    }
}

/// The three claims a stored preference must not license.
@Suite("Menu adapter: what a stored choice does and does not prove")
struct MicrophoneOverrideClaimTests {
    /// ⚠️ A function rather than a stored property, and the suite carries no type-level `@available`:
    /// swift-testing refuses `@Suite` on an availability-annotated type, so the annotation lives on each
    /// member — which is the pattern the other suites in this file already use.
    private static func deadUSB() -> AudioInputDevice {
        AudioInputDevice(uid: "USBAudioDevice_UID", name: "USB Microphone",
                         transport: .usb, inputChannels: 1,
                         canBeSystemDefault: .yes, isAlive: .no, isRunningSomewhere: false)
    }

    /// ⚠️ **A usable *Use now* needs no facts about the Mac's input.** The selection puts an override
    /// above the standing choice, and the observation wrapper asked about the default input first — so a
    /// user who had pointed at a present, recordable microphone could not start a recording because an
    /// unrelated read had failed.
    @Test("a usable Use now survives a failed default-input read")
    @available(macOS 15.0, *)
    func aUsableOverrideSurvivesAFailedDefaultRead() {
        let resolution = MicrophonePolicy.resolveCapture(
            CaptureObservation(devices: [.builtInMic(), .usbMic()],
                               systemDefault: .device(uid: "BuiltInMicrophoneDevice"),
                               defaultReadFailure: "the default read failed"),
            priority: MicrophonePriority(order: ["BuiltInMicrophoneDevice"],
                                         override: "USBAudioDevice_UID"),
            choice: .systemDefault)
        guard case .pinned(let device, _) = resolution else {
            Issue.record("an explicit, present microphone was refused: \(resolution)"); return
        }
        #expect(device.uid == "USBAudioDevice_UID")
    }

    /// ⚠️ The converse, which is why the read may not simply be skipped: with **no usable** override,
    /// following the Mac's input while that read failed is still refused — a cached uid is not an answer.
    @Test("without a usable override a failed default-input read still refuses")
    @available(macOS 15.0, *)
    func withoutAUsableOverrideTheFailedReadStillRefuses() {
        let observation = CaptureObservation(devices: [.builtInMic()],
                                             systemDefault: .device(uid: "BuiltInMicrophoneDevice"),
                                             defaultReadFailure: "the default read failed")
        #expect(MicrophonePolicy.resolveCapture(observation, priority: .empty, choice: .systemDefault)
            == .unavailable(.systemDefaultUnreadable("the default read failed")))
        // An override naming a device that is gone proves nothing either.
        #expect(MicrophonePolicy.resolveCapture(
            observation,
            priority: MicrophonePriority(order: [], override: "USBAudioDevice_UID"),
            choice: .systemDefault) == .unavailable(.systemDefaultUnreadable("the default read failed")))
    }

    /// ⚠️ And a failed **enumeration** still blocks everything, override or not: the list was never
    /// described, so nothing in it can be believed.
    @Test("a failed enumeration blocks even a usable-looking override")
    @available(macOS 15.0, *)
    func aFailedEnumerationBlocksAnOverride() {
        let resolution = MicrophonePolicy.resolveCapture(
            CaptureObservation(devices: [.usbMic()], enumerationFailure: "scripted"),
            priority: MicrophonePriority(order: [], override: "USBAudioDevice_UID"),
            choice: .followPriority)
        #expect(resolution == .unavailable(.systemDefaultUnreadable("scripted")))
    }

    /// ⚠️ **A stored override is not a used one.** With the chosen device listed but not alive, the
    /// selection correctly falls back to the list — and both the explanation and the row label used to
    /// assert it was being used anyway, so one row could say "using now" and "unavailable" at once.
    @Test("an unusable stored choice is not described as in use")
    @available(macOS 15.0, *)
    func anUnusableStoredChoiceIsNotInUse() {
        let status = ControlAPI.MicrophoneStatus(devices: [.builtInMic(), Self.deadUSB()],
                            priority: ["BuiltInMicrophoneDevice"], override: "USBAudioDevice_UID")
        #expect(status.captureSummary == "Will use MacBook Pro Microphone")
        #expect(status.overrideStanding == .unavailable)
        #expect(status.listExplanation.contains("is not available"))
        #expect(status.listExplanation.contains("will use it") == false,
                "a stored but unusable choice was described as the one the next recording uses")
    }

    @Test("a usable stored choice is described as in use")
    @available(macOS 15.0, *)
    func aUsableStoredChoiceIsInUse() {
        let status = ControlAPI.MicrophoneStatus(devices: [.builtInMic(), .usbMic()],
                            priority: ["BuiltInMicrophoneDevice"], override: "USBAudioDevice_UID")
        #expect(status.overrideStanding == .nextSelection)
        #expect(status.listExplanation.contains("the next time capture starts"))
    }

    /// ⚠️ **A running recording outranks a failed inventory read.** A failed refresh does not stop a
    /// healthy capture, so a device Acta is demonstrably recording from must never be described as not
    /// being used — the summary said "Recording from USB Microphone" while the explanation said that
    /// very device was not in use.
    @Test("a device the recording came up on is never called unused")
    @available(macOS 15.0, *)
    func aRecordingOutranksAFailedInventoryRead() {
        let status = ControlAPI.MicrophoneStatus(devices: [], priority: ["BuiltInMicrophoneDevice"],
                                                 override: "USBAudioDevice_UID",
                                                 recordingFrom: .usbMic(),
                                                 enumerationFailure: "the refresh failed")
        #expect(status.captureSummary == "Recording from USB Microphone")
        #expect(status.overrideStanding == .recording)
        #expect(status.listExplanation.contains("the recording is using it"))
        #expect(status.listExplanation.contains("not available") == false,
                "the device the recording came up on was described as unavailable")
    }

    /// ⚠️ **An unreadable observation establishes nothing**, in either direction. Calling the choice
    /// unavailable because the machine could not be described is a claim the read never made.
    @Test("an unreadable observation says unknown, not unavailable")
    @available(macOS 15.0, *)
    func anUnreadableObservationSaysUnknown() {
        let status = ControlAPI.MicrophoneStatus(devices: [], priority: ["BuiltInMicrophoneDevice"],
                                                 override: "USBAudioDevice_UID",
                                                 enumerationFailure: "the refresh failed")
        #expect(status.overrideStanding == .unknown)
        #expect(status.listExplanation.contains("is unknown"))
        #expect(status.listExplanation.contains("not available") == false,
                "an unreadable machine was used as proof the choice is unavailable")
    }

    /// ⚠️ **The next candidate is not the running recording.** Reachable whenever the chosen device
    /// refused to open and capture fell back: the override stays stored, the directory still lists the
    /// device as eligible, and the row claimed present-tense use while the summary correctly named the
    /// device the recording had actually come up on.
    @Test("the next candidate is phrased as intent while a recording is on something else")
    @available(macOS 15.0, *)
    func theNextCandidateIsNotTheRunningRecording() {
        let status = ControlAPI.MicrophoneStatus(devices: [.builtInMic(), .usbMic()],
                                                 priority: ["BuiltInMicrophoneDevice"],
                                                 override: "USBAudioDevice_UID",
                                                 recordingFrom: .builtInMic())
        #expect(status.captureSummary == "Recording from MacBook Pro Microphone")
        #expect(status.overrideStanding == .nextSelection)
        #expect(status.listExplanation.contains("the next time capture starts"))
        #expect(status.listExplanation.contains("the recording is using it") == false,
                "a next candidate was described as the microphone the recording is on")
    }

    /// ⚠️ Completeness is about the **device list**. A failed default-input read and a lost subscription
    /// are neither of them evidence about a list that was read successfully — and taken as such, an
    /// absent microphone was labelled "not readable" instead of "not connected".
    @Test("an unrelated failure does not make a successful enumeration incomplete")
    @available(macOS 15.0, *)
    func completenessIsAboutTheListAlone() {
        #expect(ControlAPI.MicrophoneStatus(devices: [.builtInMic()], defaultReadFailure: "the default read failed")
            .isComplete, "a failed default-input read made the device list incomplete")
        #expect(ControlAPI.MicrophoneStatus(devices: [.builtInMic()], observationDegraded: "no subscription").isComplete,
                "a lost subscription made an already-read list incomplete")
        #expect(ControlAPI.MicrophoneStatus(devices: [.builtInMic()], enumerationFailure: "scripted").isComplete == false)
        #expect(ControlAPI.MicrophoneStatus(devices: [.builtInMic()], uninspectable: ["x"]).isComplete == false)
        // The warning still combines them — display was never the problem.
        #expect(ControlAPI.MicrophoneStatus(devices: [.builtInMic()], defaultReadFailure: "the default read failed")
            .inventoryFailure == "the default read failed")
    }
}

/// The invariants that tie the menu's three claims to the data underneath them.
///
/// ⚠️ **Every finding in this area has been the same shape** — a string or a flag claiming more than
/// the snapshot supports: a stored override reported as used, an aggregated warning taken as evidence
/// about the device list, a suspension given a cause it did not have, an incomplete read reported as an
/// absence. Each was fixed as a case. This checks the *property* across a combinatorial matrix, so the
/// next way of claiming too much fails here rather than in a user's menu.
@Suite("Menu adapter: claims never exceed the data")
struct MicrophoneClaimInvariantTests {
    @available(macOS 15.0, *)
    private static func statuses() -> [(String, ControlAPI.MicrophoneStatus)] {
        let dead = AudioInputDevice(uid: "USBAudioDevice_UID", name: "USB Microphone",
                                    transport: .usb, inputChannels: 1, canBeSystemDefault: .yes,
                                    isAlive: .no, isRunningSomewhere: false)
        let deviceSets: [(String, [AudioInputDevice])] = [
            ("empty", []), ("builtIn", [.builtInMic()]),
            ("builtIn+usb", [.builtInMic(), .usbMic()]), ("builtIn+deadUsb", [.builtInMic(), dead]),
        ]
        let priorities: [(String, [String])] = [
            ("no list", []), ("builtIn", ["BuiltInMicrophoneDevice"]), ("usb", ["USBAudioDevice_UID"]),
        ]
        let overrides: [(String, String?)] = [
            ("no override", nil), ("override usb", "USBAudioDevice_UID"),
            ("override absent", "SomethingGone"),
        ]
        let choices: [CaptureMicrophoneChoice] = [.followPriority, .systemDefault]
        let defaults: [(String, ObservedDefaultInput)] = [
            ("unread", .unread), ("none", .noDefault),
            ("builtIn", .device(uid: "BuiltInMicrophoneDevice")),
        ]
        let failures: [(String, String?, String?, [String])] = [
            ("clean", nil, nil, []), ("enumeration failed", "e", nil, []),
            ("default read failed", nil, "d", []), ("incomplete", nil, nil, ["x"]),
        ]
        // ⚠️ **The dimension this matrix was missing, and its absence made two of the invariants
        // wrong.** Every status was built with no recording, so the `.recording` branch was never
        // exercised — deleting the production check that produces it left all three of these tests
        // green — and both oracles below quietly assumed that naming a device requires a *next*
        // selection and that a failed enumeration replaces the summary. Neither holds while a capture
        // is running, which is precisely the behaviour the commit under test protects.
        let recordings: [(String, AudioInputDevice?)] = [
            ("idle", nil), ("recording on the override", .usbMic()),
            ("recording on another", .builtInMic()),
        ]

        var out: [(String, ControlAPI.MicrophoneStatus)] = []
        for (dLabel, devices) in deviceSets {
            for (pLabel, priority) in priorities {
                for (oLabel, override) in overrides {
                    for choice in choices {
                        for (sLabel, systemDefault) in defaults {
                            for (fLabel, enumFailure, defaultFailure, uninspectable) in failures {
                                for (rLabel, recordingFrom) in recordings {
                                    let label = "\(dLabel) / \(pLabel) / \(oLabel) / \(choice) / "
                                        + "\(sLabel) / \(fLabel) / \(rLabel)"
                                    out.append((label, ControlAPI.MicrophoneStatus(
                                        devices: devices, priority: priority, override: override,
                                        systemDefault: systemDefault,
                                        recordingFrom: recordingFrom, captureChoice: choice,
                                        enumerationFailure: enumFailure,
                                        defaultReadFailure: defaultFailure,
                                        uninspectable: uninspectable)))
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// ⚠️ **A claim of use must come from the selection, never from the storage.** This is the invariant
    /// behind the row that once said "using now" and "unavailable" at the same time.
    @Test("nothing claims a microphone is in use unless the selection picked it")
    @available(macOS 15.0, *)
    func useIsOnlyClaimedFromTheSelection() {
        for (label, status) in Self.statuses() {
            // ⚠️ **Both directions, and the first version had only one.** Asserting "if it says
            // `.recording` then the recording is on it" fires on nothing when the bug is that it never
            // *says* `.recording`: deleting the production check left this suite green even after the
            // recording dimension was added. An invariant stated one way round is half an invariant.
            if let override = status.override, status.recordingFrom?.uid == override {
                #expect(status.overrideStanding == .recording,
                        "\(label): the recording is on the chosen microphone and it was not said so")
                #expect(status.listExplanation.contains("the recording is using it"),
                        "\(label): the recording is on the chosen microphone and the text denies it")
            }
            switch status.overrideStanding {
            case .recording:
                #expect(status.recordingFrom?.uid == status.override,
                        "\(label): claimed the recording is on the override when it is not")
            case .nextSelection:
                guard case .pinned(let device, _) = status.captureSelection else {
                    Issue.record("\(label): named a next selection with nothing selected"); continue
                }
                #expect(device.uid == status.override,
                        "\(label): named the override as next while \(device.uid) was selected")
            case .unavailable:
                // ⚠️ A negative claim needs a complete observation behind it.
                #expect(status.isComplete,
                        "\(label): called the override unavailable from an incomplete observation")
            case .none, .unknown:
                break
            }
            if status.listExplanation.contains("recording is using it") {
                #expect(status.overrideStanding == .recording,
                        "\(label): said the recording uses the override when it does not")
            }
        }
    }

    /// ⚠️ **A summary may name a device only when one was actually selected**, and must never name one
    /// while reporting that the machine could not be read.
    @Test("a named device in the summary means a device was selected")
    @available(macOS 15.0, *)
    func namingADeviceMeansOneWasSelected() {
        for (label, status) in Self.statuses() {
            // ⚠️ **A running recording is named from the pin, not from a selection**, and the first
            // version of this oracle demanded a pinned next selection before any device could be
            // named — a requirement that contradicts the behaviour it was meant to protect.
            if let recording = status.recordingFrom {
                #expect(status.captureSummary == "Recording from \(recording.name)",
                        "\(label): a running recording was not named from its own pin")
                continue
            }
            let names = status.devices.map(\.name)
            let mentions = names.first { status.captureSummary.contains($0) }
            if let mentions {
                guard case .pinned = status.captureSelection else {
                    Issue.record("\(label): named \(mentions) with nothing selected"); continue
                }
            }
            if status.captureSummary.contains("could not be read") {
                #expect(mentions == nil, "\(label): named a device while reporting an unreadable machine")
            }
        }
    }

    /// ⚠️ **Completeness is about the device list and nothing else**, and an unreadable machine is never
    /// summarised as an empty one.
    @Test("only the enumeration decides whether the list was described")
    @available(macOS 15.0, *)
    func onlyTheEnumerationDecidesCompleteness() {
        for (label, status) in Self.statuses() {
            #expect(status.isComplete == (status.enumerationFailure == nil && status.uninspectable.isEmpty),
                    "\(label): completeness was decided by something other than the enumeration")
            // ⚠️ Scoped to an idle machine: a failed enumeration does not stop a healthy capture, so it
            // must not replace a summary that is reporting one. Demanding it unconditionally was the
            // second oracle this matrix got wrong by never building a recording.
            if status.enumerationFailure != nil, status.recordingFrom == nil {
                #expect(status.captureSummary.contains("could not be read"),
                        "\(label): a failed enumeration was summarised as a fact about the hardware")
            }
        }
    }
}
