import ActaKit
@testable import ActaRuntime
import Foundation
import Testing

/// Seeding the priority list, and the startup flows the plan requires to be defined rather than left
/// to whatever happens.
@Suite("Microphone seeding")
struct MicrophoneSeedingTests {
    // MARK: - What "suitable physical microphone" means

    /// ⚠️ Defined in **fields**, because the plan says so: available, not something the OS refuses as a
    /// default, and physical. A virtual device or an aggregate can be recorded from and can be chosen
    /// by hand; proposing one as the default the Mac should return to is not a guess Acta gets to make.
    @Test("suitability is availability, default-eligibility and being physical")
    func suitabilityIsDefinedInFields() {
        #expect(MicrophoneSeeding.isSuitable(.builtInMic()))
        #expect(MicrophoneSeeding.isSuitable(.usbMic()))
        // Measured `1` for input-scope canBeDefaultDevice — and still not a proposal Acta should make.
        #expect(MicrophoneSeeding.isSuitable(.blackHole()) == false)
        #expect(MicrophoneSeeding.isSuitable(.aggregate()) == false)
        // The Teams loopback the OS itself refuses as a default.
        #expect(MicrophoneSeeding.isSuitable(.teamsLoopback()) == false)
        // Present but not alive.
        #expect(MicrophoneSeeding.isSuitable(.builtInMic(alive: .no)) == false)
    }

    // MARK: - The proposal

    @Test("the current input leads, with the built-in behind it")
    func theCurrentInputLeads() {
        let proposal = MicrophoneSeeding.proposal(from: [.usbMic(), .builtInMic()],
                                                  systemDefault: "USBAudioDevice_UID")
        #expect(proposal == ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
    }

    /// ⚠️ **The clause the whole feature exists for.** Enabling management while wearing a headset must
    /// not enshrine the headset as the preference — "my Mac keeps switching to my headset" is the
    /// complaint being answered, and seeding it would answer it with itself.
    @Test("a Bluetooth current input is not proposed; the built-in is")
    func aBluetoothCurrentInputIsNotSeeded() {
        let proposal = MicrophoneSeeding.proposal(from: [.airPods(), .builtInMic()],
                                                  systemDefault: "00-00-5E-00-53-01:input")
        #expect(proposal == ["BuiltInMicrophoneDevice"])
    }

    /// ⚠️ **A Mac with no built-in microphone** — a mini, a Studio — is defined rather than left to
    /// chance: the highest-ranked suitable non-Bluetooth device stands in.
    @Test("with no built-in microphone a wired device is proposed instead")
    func noBuiltInFallsBackToAWiredDevice() {
        let proposal = MicrophoneSeeding.proposal(from: [.airPods(), .usbMic()],
                                                  systemDefault: "00-00-5E-00-53-01:input")
        #expect(proposal == ["USBAudioDevice_UID"])
    }

    /// ⚠️ And a machine offering **nothing but Bluetooth** seeds nothing. Acta will not propose the very
    /// thing the user is trying to stop happening; the menu asks them to choose.
    @Test("a Bluetooth-only machine seeds nothing")
    func bluetoothOnlySeedsNothing() {
        let proposal = MicrophoneSeeding.proposal(from: [.airPods()],
                                                  systemDefault: "00-00-5E-00-53-01:input")
        #expect(proposal.isEmpty)
    }

    /// ⚠️ **Seeding never overwrites an existing list**, and a disable/re-enable cycle must not cost a
    /// user their hand-made order. Losing a ranking to a convenience is worse than not offering it.
    @Test("an existing list is never overwritten")
    func anExistingListSurvives() {
        let existing = ["USBAudioDevice_UID"]
        let seeded = MicrophoneSeeding.seeded(existing,
                                              devices: [.airPods(), .builtInMic(), .usbMic()],
                                              systemDefault: "00-00-5E-00-53-01:input")
        #expect(seeded == existing)
    }

    // MARK: - The startup flows, both with feature (B) off

    /// ⚠️ **A fresh install with feature (B) never enabled must be able to record immediately.** This
    /// test used to assert the opposite half of that sentence — that an untouched install resolves
    /// `.noneConfigured` until the user ranks something — and shipping it proved the state nobody wants:
    /// the first *Start Recording* on a new machine failed with "No microphone selected", pointing at a
    /// menu the user had no reason to have opened. The default is now `.systemDefault`, so the flow
    /// starts by working; see `RecordingSettings.captureMicrophoneChoice`.
    ///
    /// ⚠️ **What this test is actually guarding is unchanged, and it is the harder half**: recording out
    /// of the box must cost the user nothing of feature (B). Management stays off and **not one write
    /// reaches the Mac's input** — a default that recorded by quietly taking over the system input would
    /// be a worse bug than the refusal it replaced.
    @Test("a fresh install records out of the box without enabling management")
    @MainActor
    func aFreshInstallCanRecordWithoutManagement() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                   defaultInput: "00-00-5E-00-53-01:input")
        manager.start()
        await manager.apply(RecordingSettings())
        #expect(manager.capturePreference.priority.order.isEmpty)
        #expect(await manager.reconciler.isEnabled == false)

        // Nothing chosen, nothing ranked — and a recording still has a device to pin: the one the Mac
        // prefers, read now and pinned to that uid.
        guard case .pinned(let outOfTheBox, _) = manager.captureResolver.resolve() else {
            Issue.record("a fresh install could not resolve a microphone"); return
        }
        #expect(outOfTheBox == .airPods())
        #expect(await manager.reconciler.isEnabled == false)
        #expect(directory.attemptedWrites.isEmpty)

        // The list is still theirs to take over, and taking it over is two acts rather than one: rank a
        // device, then say recordings follow the list. ⚠️ **Ranking alone deliberately does not move
        // capture** while the choice is the Mac's input — the chooser says so in `listExplanation`
        // ("not this list"), because a list edit silently overriding a policy the user picked is the
        // same silent switch in the other direction.
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        #expect(manager.captureResolver.resolve() == .pinned(.airPods(), alternatives: [.builtInMic()]))

        manager.setCaptureChoice(.followPriority)
        guard case .pinned(let chosen, _) = manager.captureResolver.resolve() else {
            Issue.record("choosing a microphone did not resolve one"); return
        }
        #expect(chosen == .builtInMic())
        #expect(await manager.reconciler.isEnabled == false)
        #expect(directory.attemptedWrites.isEmpty)
    }

    /// The other half of the same flow: "use the system default" is an explicit choice, resolves to a
    /// concrete device, and still does not enable management.
    @Test("use-system-default is a choice, not an absence, and does not enable management")
    @MainActor
    func useSystemDefaultIsAChoice() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                   defaultInput: "00-00-5E-00-53-01:input")
        manager.start()
        manager.setCaptureChoice(.systemDefault)

        guard case .pinned(let device, _) = manager.captureResolver.resolve() else {
            Issue.record("use-system-default did not resolve a device"); return
        }
        #expect(device == .airPods())
        #expect(await manager.reconciler.isEnabled == false)
        #expect(directory.attemptedWrites.isEmpty)
    }

    /// ⚠️ **Migrated settings**: a config written before these fields existed opens with an empty list
    /// and feature (B) off — the same state as a fresh install, which is what makes that one flow cover
    /// both rather than two flows drifting apart.
    @Test("migrated settings land in the fresh-install state")
    func migratedSettingsMatchAFreshInstall() throws {
        let old = Data(#"{"archivePath":"~/Old","segmentSeconds":25}"#.utf8)
        let settings = try JSONDecoder().decode(RecordingSettings.self, from: old)
        #expect(settings.microphonePriority == RecordingSettings().microphonePriority)
        #expect(settings.managesSystemDefaultInput == RecordingSettings().managesSystemDefaultInput)
        #expect(settings.captureMicrophoneChoice == RecordingSettings().captureMicrophoneChoice)
    }

    // MARK: - Enabling management

    @Test("enabling management seeds an empty list and starts holding it")
    @MainActor
    func enablingSeedsAndEnforces() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.airPods(), .builtInMic()],
                                                                   defaultInput: "00-00-5E-00-53-01:input")
        manager.start()

        let seeded = await manager.enableManagement()

        #expect(seeded == ["BuiltInMicrophoneDevice"])
        #expect(await manager.reconciler.isEnabled)
        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
    }

    /// ⚠️ **Pause suspends global enforcement only.** Acta's own capture selection stays fully
    /// operational while paused — they are different promises and the plan forbids them sharing a
    /// switch.
    @Test("pausing management leaves the recording selection working")
    @MainActor
    func pausingLeavesCaptureSelectionAlone() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                   defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        // ⚠️ The choice is stated, not inherited: this test is about the **list** still deciding while
        // enforcement is paused, and the shipped default is `.systemDefault` — under which the list is
        // a fallback order rather than the selection, and the assertion below would be testing the Mac's
        // input instead of what the test is named for.
        await manager.apply(RecordingSettings(microphonePriority: ["BuiltInMicrophoneDevice"],
                                              managesSystemDefaultInput: true,
                                              captureMicrophoneChoice: .followPriority))
        await manager.pauseEnforcement()
        let writesAtPause = directory.attemptedWrites

        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        directory.emit(.defaultInputChanged)
        await manager.reconciler.waitForQuiescence()

        #expect(directory.attemptedWrites == writesAtPause, "a paused reconciler wrote the system input")
        // ...and the recording still resolves against the user's list.
        guard case .pinned(let device, _) = manager.captureResolver.resolve() else {
            Issue.record("capture selection stopped working while paused"); return
        }
        #expect(device == .builtInMic())
    }
}

/// ⚠️ **The rule behind a bounded, self-sizing section, and it shipped broken.** The chooser opened
/// completely empty: a `PreferenceKey` reports its default when the content is not in the hierarchy, a
/// collapsed disclosure renders nothing, so the measurement came back zero — and a zero stored as a
/// height makes the next expansion zero tall, whereupon the content lays out at zero and goes on
/// measuring zero. It is a latch, and a user sees a section that refuses to open.
@Suite("Bounded section layout")
struct BoundedSectionLayoutTests {
    @Test("an unmeasured section falls back to the bound rather than collapsing")
    func zeroMeansUnmeasured() {
        #expect(BoundedSectionLayout.height(measured: 0, bound: 320) == 320)
        #expect(BoundedSectionLayout.height(measured: -1, bound: 320) == 320,
                "a negative measurement is not a height either")
    }

    @Test("a measured section takes its own height, up to the bound")
    func measuredContentSizesItself() {
        #expect(BoundedSectionLayout.height(measured: 120, bound: 320) == 120)
        #expect(BoundedSectionLayout.height(measured: 900, bound: 320) == 320)
        #expect(BoundedSectionLayout.height(measured: 320, bound: 320) == 320)
    }
}
