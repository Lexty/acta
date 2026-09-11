import ActaControlProtocol
import ActaKit
@testable import ActaRuntime
import Foundation
import Testing

/// The microphone settings, their wire form, and the version bump that carries them.
@Suite("Microphone settings and protocol v2")
struct MicrophoneSettingsTests {
    // MARK: - The version, pinned exactly

    /// ⚠️ **Both halves, and by equality rather than membership.** `supported.contains(current)` would
    /// pass with a `supported` list that quietly kept v1 alive, which is the compatibility machinery
    /// decision 5 deliberately does not have.
    @Test("the protocol speaks v2 and only v2")
    func theProtocolSpeaksV2Only() {
        #expect(ProtocolVersion.current == 2)
        #expect(ProtocolVersion.supported == [2])
    }

    /// ⚠️ `RecordingID`'s `"v1:"` is an **independent frozen encoding version**, not the protocol
    /// version. Renaming it with the bump would invalidate every stored id for nothing.
    @Test("the recording id prefix is untouched by the protocol version")
    func theRecordingIDPrefixIsIndependent() {
        #expect(RecordingID.prefix == "v1:")
        #expect(RecordingID.make(directoryName: "2026-09-10-standup").hasPrefix("v1:"))
    }

    // MARK: - Required on the wire

    /// ⚠️ **This is what "required" is supposed to mean, and nothing else asserted it.** A settings
    /// payload that forgets the microphone must be rejected, not read as "no preference" — which would
    /// be indistinguishable from a user who deliberately cleared their list.
    @Test("a v2 settings payload missing a required microphone field is rejected", arguments: [
        "microphone_priority", "manages_system_default_input", "capture_microphone_choice",
    ])
    func aSettingsPayloadMissingARequiredMicrophoneFieldIsRejected(_ omitted: String) throws {
        let complete = try ControlProtocolCodec.encode(
            WireSettings(archivePath: "~/Acta", segmentSeconds: 30, deleteSegmentsAfterAssembly: true,
                         microphonePriority: ["BuiltInMicrophoneDevice"],
                         managesSystemDefaultInput: true,
                         captureMicrophoneChoice: .systemDefault)
        )
        // The complete payload decodes — so the omission below is the only thing under test.
        #expect(throws: Never.self) { try ControlProtocolCodec.decode(WireSettings.self, from: complete) }

        var object = try #require(
            try JSONSerialization.jsonObject(with: complete) as? [String: Any]
        )
        object.removeValue(forKey: omitted)
        let truncated = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: (any Error).self) {
            try ControlProtocolCodec.decode(WireSettings.self, from: truncated)
        }
    }

    @Test("an unknown capture choice is refused rather than falling back to the system default")
    func anUnknownCaptureChoiceIsRefused() {
        let json = Data(#"""
        {"archive_path":"","segment_seconds":30,"delete_segments_after_assembly":true,
         "microphone_priority":[],"manages_system_default_input":false,
         "capture_microphone_choice":"whatever_the_os_says"}
        """#.utf8)
        #expect(throws: (any Error).self) { try ControlProtocolCodec.decode(WireSettings.self, from: json) }
    }

    @Test("the settings round-trip through the wire unchanged")
    func settingsRoundTrip() throws {
        let settings = RecordingSettings(archivePath: "~/Acta", segmentSeconds: 45,
                                         deleteSegmentsAfterAssembly: false,
                                         microphonePriority: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"],
                                         managesSystemDefaultInput: true,
                                         captureMicrophoneChoice: .systemDefault)
        let data = try ControlProtocolCodec.encode(WireSettings(settings))
        let decoded = RecordingSettings(try ControlProtocolCodec.decode(WireSettings.self, from: data))
        #expect(decoded == settings)
    }

    // MARK: - Optional on disk, and that is a different question

    /// ⚠️ **Persisted migration is separate from the wire version.** A config written before these
    /// fields existed must still open — with them defaulted to exactly the state a fresh install is in.
    /// Making the on-disk fields required would lock a user out of their own settings on upgrade.
    @Test("a config written before these fields existed still decodes")
    func anOldConfigStillDecodes() throws {
        let old = Data(#"{"archivePath":"~/Old","segmentSeconds":25,"deleteSegmentsAfterAssembly":false}"#.utf8)
        let settings = try JSONDecoder().decode(RecordingSettings.self, from: old)

        #expect(settings.archivePath == "~/Old")
        #expect(settings.microphonePriority.isEmpty)
        #expect(settings.managesSystemDefaultInput == false)
        // ⚠️ `.systemDefault`, the same value a fresh install starts from — see the next two tests. A
        // config that predates the field belongs to a user who never chose, and starting them where the
        // old default put them is starting them at a refusal.
        #expect(settings.captureMicrophoneChoice == .systemDefault)
    }

    // MARK: - Out of the box, the first recording must start

    /// ⚠️ **The defect this pins: a fresh install could not record at all.** Nothing chosen and an empty
    /// list is the state every new user is in, and under `.followPriority` that resolves `.noneConfigured`
    /// — *Start Recording* refused with "No microphone selected", on a MacBook whose built-in microphone
    /// was sitting right there. The default is the one setting nobody opts into, so it has to work.
    @Test("a fresh install pins a microphone without the user choosing anything")
    func aFreshInstallResolvesAMicrophone() {
        let settings = RecordingSettings.default
        let builtIn = AudioInputDevice.builtInMic()

        let resolution = MicrophonePolicy.resolveCapture(
            CaptureObservation(devices: [builtIn], systemDefault: .device(uid: builtIn.uid)),
            priority: MicrophonePriority(order: settings.microphonePriority, override: nil),
            choice: settings.captureMicrophoneChoice
        )

        #expect(resolution == .pinned(builtIn, alternatives: []))
    }

    /// ⚠️ **Resolve-then-pin is what makes that default legitimate**, and it is worth an assertion of its
    /// own: the default is *read* at start and the recording is pinned to that concrete UID. This is the
    /// difference between Acta's default and the silent inheritance `SCStream` gives an unset device —
    /// a headset arriving later does not move a recording that has already resolved.
    @Test("the out-of-the-box default pins a uid rather than following the OS")
    func theDefaultPinsRatherThanFollows() {
        let builtIn = AudioInputDevice.builtInMic()
        let headset = AudioInputDevice.airPods()

        // The machine at the moment the recording starts.
        let atStart = MicrophonePolicy.resolveCapture(
            CaptureObservation(devices: [builtIn, headset], systemDefault: .device(uid: builtIn.uid)),
            priority: .empty,
            choice: RecordingSettings.default.captureMicrophoneChoice
        )

        #expect(atStart == .pinned(builtIn, alternatives: []))
        // ⚠️ Asserted through the uid, not the name: the pin is what a rename must not be able to move.
        if case .pinned(let device, _) = atStart { #expect(device.uid == builtIn.uid) }
    }

    // MARK: - The anti-clobber primitive covers the new fields

    /// ⚠️ Each setter merges into the **authoritative** settings, so a sibling edit not yet reflected in
    /// a lagging UI snapshot survives. A field added to the struct and forgotten in `merging` silently
    /// loses that protection.
    @Test("merging one microphone field leaves its siblings alone")
    func mergingIsFieldWise() {
        let base = RecordingSettings(archivePath: "~/A", segmentSeconds: 30,
                                     deleteSegmentsAfterAssembly: true,
                                     microphonePriority: ["A"],
                                     managesSystemDefaultInput: true,
                                     captureMicrophoneChoice: .systemDefault)

        #expect(base.merging(.microphonePriority(["B", "C"])).microphonePriority == ["B", "C"])
        #expect(base.merging(.microphonePriority(["B"])).managesSystemDefaultInput)
        #expect(base.merging(.microphonePriority(["B"])).captureMicrophoneChoice == .systemDefault)

        #expect(base.merging(.managesSystemDefaultInput(false)).managesSystemDefaultInput == false)
        #expect(base.merging(.managesSystemDefaultInput(false)).microphonePriority == ["A"])

        #expect(base.merging(.captureMicrophoneChoice(.followPriority)).captureMicrophoneChoice
            == .followPriority)
        #expect(base.merging(.captureMicrophoneChoice(.followPriority)).microphonePriority == ["A"])
    }

    // MARK: - The settings actually reach the owner

    /// ⚠️ **Without this the fields are stored and inert.** They are only worth persisting if they reach
    /// the reconciler and the capture pin.
    @Test("applying settings sets the list, the capture choice and feature (B) together")
    @MainActor
    func applyingSettingsReachesBothConsumers() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(
            devices: [.builtInMic(), .airPods()],
            defaultInput: "00-00-5E-00-53-01:input"
        )
        manager.start()

        await manager.apply(RecordingSettings(microphonePriority: ["BuiltInMicrophoneDevice"],
                                              managesSystemDefaultInput: true,
                                              captureMicrophoneChoice: .systemDefault))

        #expect(manager.capturePreference.priority.order == ["BuiltInMicrophoneDevice"])
        #expect(manager.capturePreference.choice == .systemDefault)
        #expect(await manager.reconciler.isEnabled)
        #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
    }

    /// ⚠️ **A settings save is not a Resume.** Enabling used to clear Pause and the conflict budget
    /// unconditionally, so saving an unrelated archive path silently put Acta back to writing the
    /// system default — and wiped the suspension latch the reconciler contract requires to survive.
    @Test("applying settings while paused does not resume enforcement")
    @MainActor
    func applyingSettingsDoesNotResume() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(
            devices: [.builtInMic(), .airPods()], defaultInput: "BuiltInMicrophoneDevice"
        )
        manager.start()
        await manager.apply(RecordingSettings(microphonePriority: ["BuiltInMicrophoneDevice"],
                                              managesSystemDefaultInput: true))
        await manager.pauseEnforcement()
        let writesAtPause = directory.attemptedWrites

        // The default moves, and the user saves something unrelated.
        directory.setDefaultInput(.device(uid: "00-00-5E-00-53-01:input"))
        await manager.apply(RecordingSettings(archivePath: "~/Elsewhere",
                                              microphonePriority: ["BuiltInMicrophoneDevice"],
                                              managesSystemDefaultInput: true))

        #expect(await manager.reconciler.isPaused, "a settings save resumed enforcement")
        #expect(directory.attemptedWrites == writesAtPause, "a settings save wrote the system default")
    }

    /// ⚠️ **Admission is checked before any side effect.** A queued application landing after shutdown
    /// used to reach the OS and only then disable — and disabling afterwards does not make that write
    /// acceptable.
    @Test("an application landing after shutdown writes nothing")
    @MainActor
    func anApplicationAfterShutdownWritesNothing() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(
            devices: [.builtInMic(), .airPods()], defaultInput: "00-00-5E-00-53-01:input"
        )
        manager.start()
        await manager.shutdown()

        await manager.apply(RecordingSettings(microphonePriority: ["BuiltInMicrophoneDevice"],
                                              managesSystemDefaultInput: true))

        #expect(directory.attemptedWrites.isEmpty)
        #expect(await manager.reconciler.isEnabled == false)
    }

    /// ⚠️ **A save queued before Quit must not re-enable enforcement after the quit sequence began.**
    /// Bumping a revision invalidates applications that are already *running*; it says nothing about
    /// one still in the queue, which starts later, bumps the revision itself, and sees the manager
    /// still started — quitting deliberately keeps read-only monitoring alive through the assembly.
    /// Two saves requested before Quit were enough to write the system default after `stopEnforcement`
    /// had returned, with no user action after Quit at all.
    @Test("a settings application queued before the quit boundary cannot re-enable enforcement")
    @MainActor
    func aQueuedApplicationCannotReEnableAfterStopEnforcement() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(
            devices: [.builtInMic(), .airPods()], defaultInput: "00-00-5E-00-53-01:input"
        )
        manager.start()
        await manager.apply(RecordingSettings(microphonePriority: ["00-00-5E-00-53-01:input"],
                                              managesSystemDefaultInput: true))

        // The quit sequence starts, and a save requested before it lands afterwards.
        await manager.stopEnforcement()
        let writesAtStop = directory.attemptedWrites
        await manager.apply(RecordingSettings(microphonePriority: ["BuiltInMicrophoneDevice"],
                                              managesSystemDefaultInput: true))

        #expect(directory.attemptedWrites == writesAtStop,
                "a queued save wrote the system default after the quit boundary")
        #expect(await manager.reconciler.isEnabled == false)
        // ⚠️ The list still applies — the recording that is still finishing resolves against it.
        #expect(manager.capturePreference.priority.order == ["BuiltInMicrophoneDevice"])
    }

    /// ⚠️ **Feature (B) off must not disable Acta's own capture selection**: different promises, and the
    /// plan forbids them sharing a switch.
    @Test("feature (B) off still leaves the capture list applied")
    @MainActor
    func captureSelectionSurvivesFeatureBBeingOff() async {
        let (directory, _, _, manager) = makeTestMicrophoneManager(
            devices: [.builtInMic(), .airPods()],
            defaultInput: "00-00-5E-00-53-01:input"
        )
        manager.start()

        await manager.apply(RecordingSettings(microphonePriority: ["BuiltInMicrophoneDevice"],
                                              managesSystemDefaultInput: false))

        #expect(manager.capturePreference.priority.order == ["BuiltInMicrophoneDevice"])
        #expect(await manager.reconciler.isEnabled == false)
        // Nothing was written to the Mac's default input — that is the whole meaning of (B) being off.
        #expect(directory.attemptedWrites.isEmpty)
    }
}
