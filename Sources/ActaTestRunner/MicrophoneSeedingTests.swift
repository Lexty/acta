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

    /// ⚠️ **A fresh install with feature (B) never enabled must still be able to record.** The list
    /// defaults empty and capture refuses an unresolved microphone, so without a defined flow this user
    /// falls into a state nobody specified. The answer: they pick a microphone, or ask for the system
    /// default — and neither turns on management of the Mac's input.
    @Test("a fresh install can choose a recording microphone without enabling management")
    @MainActor
    func aFreshInstallCanRecordWithoutManagement() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic(), .airPods()],
                                                                   defaultInput: "00-00-5E-00-53-01:input")
        manager.start()
        await manager.apply(RecordingSettings())
        #expect(manager.capturePreference.priority.order.isEmpty)
        #expect(await manager.reconciler.isEnabled == false)

        // Before choosing, a recording has nothing to pin — and says so rather than silently following
        // the system default.
        let unresolved = manager.captureResolver.resolve()
        #expect(unresolved == .unavailable(.noneConfigured))

        // The user picks one. Feature (B) stays off and nothing is written to the Mac's input.
        await manager.setPriorityOrder(["BuiltInMicrophoneDevice"])
        guard case .pinned(let device, _) = manager.captureResolver.resolve() else {
            Issue.record("choosing a microphone did not resolve one"); return
        }
        #expect(device == .builtInMic())
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
        await manager.apply(RecordingSettings(microphonePriority: ["BuiltInMicrophoneDevice"],
                                              managesSystemDefaultInput: true))
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
