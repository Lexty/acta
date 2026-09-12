import ActaKit
@testable import ActaRuntime
import AVFoundation
import Foundation
import Testing

/// Acta's **own** capture pin: which microphone a recording records from.
///
/// ⚠️ **A different question from feature (B), and the tests must not blur them.** The reconciler holds
/// the *Mac's* default input; this holds *Acta's* recording device. They share the user's one ordered
/// list and differ in eligibility — `canBeSystemDefault` filters the system default and not capture —
/// and in lifetime: a recording pins at start and keeps that device, while the system default is held
/// continuously.
///
/// ⚠️ **What none of this proves**: that ScreenCaptureKit honours `microphoneCaptureDeviceID` at all,
/// or that a stream configured with a uid records from *that* microphone. `FakeCaptureSource` accepts
/// any string. Only a TCC-authorised build recording from a deliberately non-default microphone, and
/// the audio being listened to, proves the pin took effect — which is in the plan's manual section for
/// exactly this reason.
@Suite("Capture microphone", .serialized)
struct CaptureMicrophoneTests {
    // MARK: - The resolution, from literals

    @Test("the priority list decides, and capture eligibility is not default eligibility")
    func capturePicksTheTopPreferredDevice() {
        // The Teams loopback measured `0` for input-scope canBeDefaultDevice: the OS will not make it
        // the system default. That says nothing about whether it can be recorded from.
        let resolution = MicrophonePolicy.resolveCapture(
            from: [.builtInMic(), .teamsLoopback()],
            priority: MicrophonePriority(order: ["MSLoopbackDriverDevice_UID", "BuiltInMicrophoneDevice"]),
            choice: .followPriority,
            systemDefault: nil
        )
        #expect(resolution == .pinned(.teamsLoopback(), alternatives: [.builtInMic()]))
    }

    @Test("a Use now outranks the list for capture too")
    func theOverrideWinsForCapture() {
        let resolution = MicrophonePolicy.resolveCapture(
            from: [.builtInMic(), .airPods()],
            priority: MicrophonePriority(order: ["BuiltInMicrophoneDevice"],
                                         override: "00-00-5E-00-53-01:input"),
            choice: .followPriority,
            systemDefault: nil
        )
        #expect(resolution == .pinned(.airPods(), alternatives: [.builtInMic()]))
    }

    /// ⚠️ **Nothing configured is its own answer, and it is not "use the system default".** That
    /// distinction is the whole feature: `SCStream.h` makes an unspecified device mean the system
    /// default, which is the silent inheritance being ended.
    @Test("nothing configured is not the same as a list whose devices are absent")
    func theTwoEmptyAnswersAreDistinct() {
        let nothingChosen = MicrophonePolicy.resolveCapture(from: [.builtInMic()],
                                                            priority: .empty,
                                                            choice: .followPriority,
                                                            systemDefault: nil)
        #expect(nothingChosen == .unavailable(.noneConfigured))

        let chosenButAbsent = MicrophonePolicy.resolveCapture(
            from: [.builtInMic()],
            priority: MicrophonePriority(order: ["USBAudioDevice_UID"]),
            choice: .followPriority,
            systemDefault: nil
        )
        #expect(chosenButAbsent == .unavailable(.noPreferredDeviceAvailable))
    }

    /// ⚠️ **"Use system default" is resolve-then-pin.** It reads the default once and pins that concrete
    /// device; it does not mean "keep following whatever the OS decides", which is what passing nothing
    /// would have meant.
    @Test("use-system-default resolves to a concrete device")
    func systemDefaultResolvesToAConcreteDevice() {
        let resolution = MicrophonePolicy.resolveCapture(
            from: [.builtInMic(), .airPods()],
            priority: MicrophonePriority(order: ["BuiltInMicrophoneDevice"]),
            choice: .systemDefault,
            systemDefault: "00-00-5E-00-53-01:input"
        )
        // Pinned to the headset the OS currently prefers — with the user's list as the fallback order,
        // because "start from the system default" says nothing about where to go if it dies.
        #expect(resolution == .pinned(.airPods(), alternatives: [.builtInMic()]))
    }

    @Test("a machine with nothing capture-eligible says so")
    func noEligibleDeviceIsItsOwnAnswer() {
        let dead = AudioInputDevice(uid: "Dead", name: "Dead", transport: .usb, inputChannels: 0,
                                    canBeSystemDefault: .yes, isAlive: .yes, isRunningSomewhere: false)
        let resolution = MicrophonePolicy.resolveCapture(from: [dead],
                                                         priority: MicrophonePriority(order: ["Dead"]),
                                                         choice: .followPriority,
                                                         systemDefault: nil)
        #expect(resolution == .unavailable(.noEligibleDevice))
    }

    // MARK: - The recorder pins it, and re-pins on every restart

    /// A temp directory the recorder can write segments into, removed afterwards.
    private func withTemporaryDirectoryAsync(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-mic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    @available(macOS 15.0, *)
    private func recorder(_ resolution: CaptureMicrophoneResolution,
                          in directory: URL) -> (FakeCaptureSource, FakeCaptureMicrophoneResolver, AudioRecorder) {
        let source = FakeCaptureSource()
        let resolver = FakeCaptureMicrophoneResolver(resolution)
        let recorder = AudioRecorder(directory: directory, segmentSeconds: 60,
                                     source: source, permissions: FakePermissions(),
                                     microphone: resolver)
        return (source, resolver, recorder)
    }

    @Test("a start pins the resolved device and never passes nothing")
    @available(macOS 15.0, *)
    func aStartPinsTheResolvedDevice() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (source, _, recorder) = self.recorder(.pinned(.usbMic(), alternatives: []), in: directory)
            try await recorder.start()

            #expect(source.startedMicrophoneIDs == ["USBAudioDevice_UID"])
            #expect(recorder.pinnedMicrophone == .usbMic())
            await recorder.stop()
        }
    }

    /// ⚠️ **Enumerating is not starting.** A device the OS lists happily can still refuse to open, and
    /// the recording must reach the next configured alternative rather than failing.
    @Test("the first candidate failing to start falls through to the next")
    @available(macOS 15.0, *)
    func aCandidateThatWillNotStartFallsThrough() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (source, _, recorder) = self.recorder(
                .pinned(.usbMic(), alternatives: [.builtInMic()]), in: directory
            )
            source.failStart(forDeviceIDs: ["USBAudioDevice_UID"])
            try await recorder.start()

            #expect(source.startedMicrophoneIDs == ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
            #expect(recorder.pinnedMicrophone == .builtInMic())
            await recorder.stop()
        }
    }

    /// ⚠️ Bounded by the ranked list: every candidate is tried at most once, so a machine where nothing
    /// starts terminates instead of retrying forever.
    @Test("no candidate starting fails the start within a bound")
    @available(macOS 15.0, *)
    func noCandidateStartingTerminates() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (source, _, recorder) = self.recorder(
                .pinned(.usbMic(), alternatives: [.builtInMic(), .airPods()]), in: directory
            )
            source.failStart(forDeviceIDs: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice",
                                            "00-00-5E-00-53-01:input"])

            await #expect(throws: StartupFailure.streamNotStarted) { try await recorder.start() }
            #expect(source.startedMicrophoneIDs.count == 3)
            #expect(recorder.pinnedMicrophone == nil)
        }
    }

    /// ⚠️ Nothing configured is **not** worth a restart attempt: re-resolving reaches the same answer,
    /// so spending the watchdog's budget on it would delay a message the user could act on now.
    @Test("no microphone to record from is its own failure, and not a restartable one")
    @available(macOS 15.0, *)
    func nothingConfiguredIsItsOwnFailure() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (source, _, recorder) = self.recorder(.unavailable(.noneConfigured), in: directory)

            await #expect(throws: StartupFailure.microphoneUnavailable) { try await recorder.start() }
            #expect(source.startedMicrophoneIDs.isEmpty)
        }
        #expect(SelfDiagnosis.action(for: .microphoneUnavailable, restartAttemptsLeft: 3)
            == .reportError(.microphoneUnavailable))
    }

    /// ⚠️ **Every restart re-resolves.** A recorder that resolved once and reused the answer is one no
    /// priority edit and no *Use now* could ever reach — and it is what makes "a watchdog restart can
    /// apply a mid-recording preference change" true rather than aspirational.
    @Test("a restart re-resolves rather than reusing the device it started with")
    @available(macOS 15.0, *)
    func aRestartReResolves() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (source, resolver, recorder) = self.recorder(
                .pinned(.builtInMic(), alternatives: []), in: directory
            )
            try await recorder.start()
            #expect(resolver.resolveCount == 1)

            // The user edits the list, or issues a Use now, mid-recording.
            resolver.set(.pinned(.usbMic(), alternatives: []))
            try await recorder.restart()

            #expect(resolver.resolveCount == 2)
            #expect(source.startedMicrophoneIDs == ["BuiltInMicrophoneDevice", "USBAudioDevice_UID"])
            #expect(recorder.pinnedMicrophone == .usbMic())
            await recorder.stop()
        }
    }

    /// ⚠️ **The pin is set from what came up, never from what was asked for.** Showing a requested
    /// device as active before capture succeeded is how a menu ends up lying about which microphone is
    /// recording.
    @Test("a failed switch leaves the pin on the device that is actually recording")
    @available(macOS 15.0, *)
    func aFailedSwitchDoesNotShowTheRequestedDevice() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (source, resolver, recorder) = self.recorder(
                .pinned(.builtInMic(), alternatives: []), in: directory
            )
            try await recorder.start()

            // A Use now on a device that will not open, with the previous one still on the list.
            source.failStart(forDeviceIDs: ["00-00-5E-00-53-01:input"])
            resolver.set(.pinned(.airPods(), alternatives: [.builtInMic()]))
            try await recorder.restart()

            #expect(recorder.pinnedMicrophone == .builtInMic())
            #expect(source.startedMicrophoneIDs.last == "BuiltInMicrophoneDevice")
            await recorder.stop()
        }
    }

    // MARK: - A switch between devices of different source formats

    /// ⚠️ **The acceptance item I wrongly recorded as needing a fixture that did not exist.**
    /// `FakeCaptureSource.setFormat` and `FixtureAudioFormat(sampleRate:channels:)` were both already
    /// there; I did not look before writing the reason down. A peer review built it in minutes, found a
    /// failure, and then traced that failure to its own sandbox rather than to Acta — so the code was
    /// right and my reason for not testing it was not.
    ///
    /// The construction is the review's, narrowed to the transition that actually happens on this
    /// machine: the AirPods measured **24 000 Hz**, so 48 k → 24 k is the real headset switch.
    ///
    /// ⚠️ **This test was quarantined on a wrong diagnosis, and is back in the mandatory gate.** I
    /// measured that it took the suite from 4 s to 63 s, saw the cost was flat in the amount of audio,
    /// and concluded a stall in the conversion path for non-48-kHz sources — which was a correlation,
    /// not a measurement. The real cause is `SegmentWriter.finish` exhausting its 30-second
    /// `pendingWrites` wait when many writers run concurrently; ordinary 48 kHz tests time out
    /// alongside it. Serializing this suite fixes it, and these tests then cost 0.012 s. See
    /// `docs/backlog/segment-finalisation-waits-under-parallel-tests.md`.
    @Test("a switch between source formats leaves every segment valid and assembles",
          arguments: [(48_000.0, AVAudioChannelCount(1)), (48_000.0, AVAudioChannelCount(2)),
                      (24_000.0, AVAudioChannelCount(1)), (24_000.0, AVAudioChannelCount(2))])
    @available(macOS 15.0, *)
    func aFormatSwitchKeepsEverySegmentValid(_ format: (rate: Double, channels: AVAudioChannelCount)) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (source, resolver, recorder) = self.recorder(
                .pinned(.builtInMic(), alternatives: []), in: directory
            )
            // One buffer per side: the property under test needs a buffer on each side of the switch.
            // `FakeCaptureSource.framesPerBuffer` is one second at 48 kHz; the same frame count at
            // 24 kHz is **two** seconds of audio, not half.
            source.setEmitOnStart(false)
            try await recorder.start()
            source.enqueueBatch(count: 1)
            source.drain()

            source.setFormat(FixtureAudioFormat(sampleRate: format.rate, channels: format.channels))
            resolver.set(.pinned(.airPods(), alternatives: []))
            try await recorder.restart()
            source.enqueueBatch(count: 1)
            source.drain()
            await recorder.stop()

            // ⚠️ **Assembled for real, and the oracle is the assembled audio.** The previous version of
            // this test compared file sizes and counted *received* buffers while claiming "every
            // delivered buffer was accepted" — received says nothing about written, and header-only
            // files satisfy a size comparison. What actually has to hold is that the segments on both
            // sides of the switch are readable by the assembler and that their audio survives into the
            // final file.
            let assembled = try SegmentAssembler().assemble(in: directory, deleteSegments: false)

            #expect(assembled.segmentCount == 2, "a segment on each side of the switch must assemble")

            // ⚠️ **Each track measured separately, and this is the blind spot the first version had.**
            // `Result.segmentCount` and `Result.durationSeconds` are both **maxima across the tracks**,
            // so a microphone that stopped being written after the switch is completely hidden by a
            // healthy system track — a control that dropped only the mic buffers passed all four cases.
            // `micWAV` existing proves only that its pre-switch second survived.
            //
            // The pre-switch second plus the post-switch buffer, which is `framesPerBuffer` frames at
            // the **new** rate — two seconds at 24 kHz, one at 48 kHz.
            let postSwitch = Double(FakeCaptureSource.framesPerBuffer) / format.rate
            let expected = 1.0 + postSwitch
            for (track, url) in [("mic", assembled.micWAV), ("system", assembled.systemWAV)] {
                let file = try #require(url, "the \(track) track did not assemble")
                let duration = try #require(durationOfWAV(at: file), "\(track) has no readable duration")
                #expect(abs(duration - expected) < 0.05,
                        "\(track): assembled \(duration)s, expected \(expected)s — audio lost across the switch")
            }
        }
    }

    // MARK: - Use now outranks the standing policy

    /// ⚠️ **A *Use now* must beat `.systemDefault`, not lose to it.** The choice is a standing policy —
    /// "start from what the OS prefers" — while the override is the user pointing at a microphone right
    /// now. With the policy consulted first, clicking a device while `.systemDefault` was set silently
    /// did nothing, which made the one explicit action in this feature the one that could not be
    /// relied on.
    @Test("Use now outranks the use-system-default policy")
    func useNowBeatsTheSystemDefaultPolicy() {
        let resolution = MicrophonePolicy.resolveCapture(
            from: [.builtInMic(), .airPods(), .usbMic()],
            priority: MicrophonePriority(order: ["BuiltInMicrophoneDevice"],
                                         override: "USBAudioDevice_UID"),
            choice: .systemDefault,
            systemDefault: "00-00-5E-00-53-01:input"
        )
        guard case .pinned(let device, _) = resolution else {
            Issue.record("expected the override to be pinned"); return
        }
        #expect(device == .usbMic())
    }

    /// ⚠️ **The pin means "this is recording", and between a teardown and a successful start nothing
    /// is.** `performStart` can throw before ever reaching its own clear — a revoked screen permission
    /// does exactly that — which left a torn-down capture still naming a microphone for the menu to
    /// show as active.
    @Test("a restart that fails before starting leaves no microphone claiming to record")
    @available(macOS 15.0, *)
    func aFailedRestartClearsThePin() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let source = FakeCaptureSource()
            let permissions = FakePermissions()
            let recorder = AudioRecorder(directory: directory, segmentSeconds: 60,
                                         source: source, permissions: permissions,
                                         microphone: FakeCaptureMicrophoneResolver(
                                             .pinned(.builtInMic(), alternatives: [])))
            try await recorder.start()
            #expect(recorder.pinnedMicrophone == .builtInMic())

            // Revoked between the start and the restart: `performStart` throws before it reaches the
            // device loop at all.
            permissions.revokeScreenRecording()
            await #expect(throws: (any Error).self) { try await recorder.restart() }

            #expect(source.isStreaming == false)
            #expect(recorder.pinnedMicrophone == nil, "a stopped capture still named a microphone")
        }
    }

    /// ⚠️ **A watchdog recovery that lands on a different device must say so.** The plan's requirement
    /// is that "next recording" is not strictly true — a restart re-resolves, so a priority edit can
    /// take effect mid-recording — and that this is **reported** rather than silent, or the user cannot
    /// tell why the audio changed source.
    @Test("a restart that adopts a different device announces it")
    @available(macOS 15.0, *)
    func anAdoptedDeviceIsAnnounced() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (_, resolver, recorder) = self.recorder(.pinned(.builtInMic(), alternatives: []),
                                                        in: directory)
            let adopted = ReportedDevices()
            recorder.onDeviceAdopted = { previous, now in adopted.record(previous, now) }
            try await recorder.start()

            // The user edits the list mid-recording; the watchdog's restart re-resolves onto it.
            resolver.set(.pinned(.usbMic(), alternatives: []))
            try await recorder.restart()

            #expect(adopted.pairs.count == 1)
            #expect(adopted.pairs.first?.1 == .usbMic())
            await recorder.stop()
        }
    }

    /// ⚠️ **An explicit switch is not a hardware failure.** Every device-changing restart used to be
    /// announced as "<previous> stopped working" — so choosing a USB microphone over a perfectly
    /// healthy built-in one said the built-in had failed, and then the caller that asked for the switch
    /// reported it a second time.
    @Test("an explicit switch is not announced as a failure")
    @available(macOS 15.0, *)
    func anExplicitSwitchIsNotAnnouncedAsFailure() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (_, resolver, recorder) = self.recorder(.pinned(.builtInMic(), alternatives: []),
                                                        in: directory)
            let adopted = ReportedDevices()
            recorder.onDeviceAdopted = { previous, now in adopted.record(previous, now) }
            try await recorder.start()

            resolver.set(.pinned(.usbMic(), alternatives: []))
            try await recorder.restart(reason: .userSwitch)

            #expect(recorder.pinnedMicrophone == .usbMic())
            #expect(adopted.pairs.isEmpty, "a deliberate switch was announced as a failure")
            await recorder.stop()
        }
    }

    // MARK: - One serialized capture lifecycle

    /// ⚠️ **Task 5 is what forced the serialization, and this is the test that says why.** Until now
    /// there were two lifecycle callers — the watchdog's `restart()` and the session's `stop()` — kept
    /// apart because `RecordingSession.stop()` cancels the watchdog and awaits it first. A microphone
    /// switch is a third caller, arriving from the menu with no such arrangement. `restart()`'s own doc
    /// says its order "is the whole point and must not be rearranged"; that is only meaningful if two
    /// of them cannot interleave.
    @Test("concurrent restarts do not interleave")
    @available(macOS 15.0, *)
    func restartsAreSerialized() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (source, _, recorder) = self.recorder(.pinned(.builtInMic(), alternatives: []), in: directory)
            try await recorder.start()

            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 8 {
                    group.addTask { try? await recorder.restart() }
                }
            }

            // Every restart is one stop and one start, in that order, and never two starts in a row.
            #expect(source.maximumConcurrentLifecycleOperations == 1)
            await recorder.stop()
        }
    }

    /// A switch racing a Stop: the recording ends cleanly and no capture is left running behind it.
    @Test("a switch racing a stop leaves nothing streaming")
    @available(macOS 15.0, *)
    func aSwitchRacingAStopLeavesNothingStreaming() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (source, _, recorder) = self.recorder(.pinned(.builtInMic(), alternatives: []), in: directory)
            try await recorder.start()

            async let restarting: Void = { try? await recorder.restart() }()
            async let stopping: Void = recorder.stop()
            _ = await (restarting, stopping)

            #expect(source.maximumConcurrentLifecycleOperations == 1)
            #expect(source.isStreaming == false)
        }
    }
}

/// The recording's **own** observation of the audio devices.
///
/// ⚠️ **A separate suite because the property is about ownership, not resolution.** The recording holds
/// its own subscription for exactly its own lifetime — settled that way in review rather than as a
/// registry on `MicrophoneManager`, because cancelling a token fences the directory callback and does
/// not cancel the work that callback has already queued, and only the owner can drain that.
///
/// ⚠️ **These are in the mandatory gate, and the reason they briefly were not is worth recording.** I
/// measured them at about a minute each, concluded a finalisation stall, and put them behind an opt-in
/// flag — twice. The actual cause was that this suite's closing brace sat **above** them, so five tests
/// including these were at file scope and never serialized at all; the runner said so plainly, "2 tests
/// in 0 suites", and I did not read it. Moving one brace put the whole suite at 5.3 s. A peer review
/// measured it; I had asserted "already serialized, so serializing cannot help" without checking where
/// the suite actually ended.
@Suite("Recording-owned microphone loss", .serialized)
struct RecordingMicrophoneLossTests {
    /// ⚠️ **The watchdog is not a substitute, and believing it was is why this was missing.**
    /// `TrackWatchdog` reads a track's count not increasing as ordinary source silence, and the system
    /// track keeps advancing when only the microphone goes — so a lost headset produced no stall at
    /// all. Even for whole-stream loss the watchdog answers after its window; the requirement is
    /// immediate.
    @Test("losing the pinned microphone fails over at once, and says so")
    @available(macOS 15.0, *)
    func aLostMicrophoneFailsOverImmediately() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-loss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let devices = FakeAudioDeviceDirectory(devices: [.airPods(), .builtInMic()], defaultInput: nil)
        let source = FakeCaptureSource()
        let clock = TestClock()
        // ⚠️ Without this the startup probe never sees a buffer: the watchdog then spends its whole
        // restart budget and the test measures a stall instead of a device loss.
        //
        // ⚠️ And **bounded**, which matters just as much. `TestClock` sleeps cost 200 µs, so the
        // watchdog ticks thousands of times while this test waits a couple of real seconds — emitting
        // on every one of them buries `stop()`'s assembly under minutes of audio. Enough batches to
        // carry the probe and the restart, and no more.
        clock.onSleep { _ in source.emitBatch() }
        let resolver = FakeCaptureMicrophoneResolver(.pinned(.airPods(), alternatives: [.builtInMic()]))
        // ⚠️ A counted lock, never a real one: every test in this runner shares one pid, and
        // `DisplayWakeLockTests` asks `pmset` what *this pid* holds — a real assertion taken here is
        // indistinguishable from the one it is checking for, and fails that suite instead of this one.
        let activity = CountingWakeLock()
        let session = RecordingSession(directory: directory,
                                       settings: .default,
                                       wakeLock: activity.makeWakeLock(),
                                       microphone: resolver,
                                       deviceReader: devices,
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: FakePermissions(),
                                                                      clock: clock))
        let reported = ReportedMessages()
        session.onMicrophoneChanged = { reported.record($0) }

        try await session.start()
        #expect(devices.subscriberCount == 1, "the recording did not take its own subscription")

        // The headset goes. Only the *microphone* is lost — the system track is unaffected, which is
        // exactly the case the watchdog cannot see.
        resolver.set(.pinned(.builtInMic(), alternatives: []))
        devices.setDevices([.builtInMic()])
        devices.emit(.deviceListChanged)

        let switched = await awaitCondition { reported.messages.isEmpty == false }
        #expect(switched, "the loss was never reported")
        #expect(source.startedMicrophoneIDs.last == "BuiltInMicrophoneDevice")

        // ⚠️ **Frozen before stopping, and this is not a detail.** `TestClock` sleeps cost 200 µs, so
        // the watchdog ticks thousands of times while this test waits a couple of real seconds, and
        // every tick feeds another batch — burying `stop()`'s real assembly under minutes of audio and
        // putting the whole suite at a minute. Freezing is the documented way to say "I have finished
        // feeding it; let the state on disk stop moving".
        clock.freeze()
        _ = await session.stop()
        // ⚠️ The subscription is the recording's, so it goes when the recording does.
        #expect(devices.subscriberCount == 0)
    }

    /// ⚠️ Absence is **proved**, never inferred: a snapshot that could not describe every driver is not
    /// evidence the pinned microphone left, and failing a recording over on it acts on an unknown.
    @Test("an incomplete snapshot does not fail the recording over")
    @available(macOS 15.0, *)
    func anIncompleteSnapshotDoesNotFailOver() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-loss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let devices = FakeAudioDeviceDirectory(devices: [.airPods(), .builtInMic()], defaultInput: nil)
        let source = FakeCaptureSource()
        let clock = TestClock()
        // ⚠️ Without this the startup probe never sees a buffer: the watchdog then spends its whole
        // restart budget and the test measures a stall instead of a device loss.
        //
        // ⚠️ And **bounded**, which matters just as much. `TestClock` sleeps cost 200 µs, so the
        // watchdog ticks thousands of times while this test waits a couple of real seconds — emitting
        // on every one of them buries `stop()`'s assembly under minutes of audio. Enough batches to
        // carry the probe and the restart, and no more.
        clock.onSleep { _ in source.emitBatch() }
        let resolver = FakeCaptureMicrophoneResolver(.pinned(.airPods(), alternatives: [.builtInMic()]))
        // ⚠️ A counted lock, never a real one: every test in this runner shares one pid, and
        // `DisplayWakeLockTests` asks `pmset` what *this pid* holds — a real assertion taken here is
        // indistinguishable from the one it is checking for, and fails that suite instead of this one.
        let activity = CountingWakeLock()
        let session = RecordingSession(directory: directory,
                                       settings: .default,
                                       wakeLock: activity.makeWakeLock(),
                                       microphone: resolver,
                                       deviceReader: devices,
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: FakePermissions(),
                                                                      clock: clock))
        let reported = ReportedMessages()
        session.onMicrophoneChanged = { reported.record($0) }
        try await session.start()
        let startsBefore = source.startedMicrophoneIDs

        devices.setDevices([.builtInMic()], uninspectable: ["00-00-5E-00-53-01:input"])
        devices.emit(.deviceListChanged)
        for _ in 0 ..< 50 { await Task.yield() }

        #expect(reported.messages.isEmpty, "an unproved absence was reported as a loss")
        #expect(source.startedMicrophoneIDs == startsBefore, "the recording was failed over on a guess")
        clock.freeze()
        _ = await session.stop()
    }

    /// ⚠️ **Unusable is not only absent.** A device can stay listed and stop being alive, or lose its
    /// input channels — an observer that only asks "is it in the list" never learns, and the recording
    /// keeps a microphone that produces nothing.
    @Test("a pinned device that stays listed but stops being usable fails over")
    @available(macOS 15.0, *)
    func aListedButUnusableDeviceFailsOver() async throws {
        try await withLossHarness { devices, source, resolver, session, reported, clock in
            resolver.set(.pinned(.builtInMic(), alternatives: []))
            // Still listed, and no longer alive.
            devices.setDevices([.airPods(alive: .no), .builtInMic()])
            devices.emit(.readinessChanged(uid: "00-00-5E-00-53-01:input"))

            let switched = await awaitCondition { reported.messages.isEmpty == false }
            #expect(switched, "a listed-but-unusable device was ignored")
            #expect(source.startedMicrophoneIDs.last == "BuiltInMicrophoneDevice")
            _ = session
        }
    }

    /// ⚠️ **A recording that cannot watch its devices looks exactly like one whose microphone never
    /// goes away.** A swallowed registration failure is the single fault that announces itself in no
    /// other way.
    @Test("a failed device subscription is reported rather than swallowed")
    @available(macOS 15.0, *)
    func aFailedDeviceSubscriptionIsReported() async throws {
        try await withLossHarness(failObservation: "registration refused") { _, _, _, session, reported, _ in
            #expect(reported.messages.contains { if case .microphoneObservationDegraded = $0 { return true }
                                                 else { return false } },
                    "the recording never said it was not watching")
            _ = session
        }
    }

    /// ⚠️ **What this proves, and what it does not.** It proves a recording stopped with a loss handler
    /// in flight ends cleanly and reports nothing afterwards. It does **not** isolate
    /// `lossWatch.stop()`'s join: three different oracles were tried and the negative control passed all
    /// three, because `AudioRecorder`'s serialized lifecycle already makes `stop()` wait behind the
    /// in-flight restart, and its terminal gate plus the cleared pin already prevent a later
    /// observation from doing anything. The join is kept as the ownership guarantee it is, and is
    /// recorded here as undistinguished by the suite rather than implied to be covered.
    @Test("stopping with a loss handler in flight ends cleanly")
    @available(macOS 15.0, *)
    func stoppingJoinsTheLossHandler() async throws {
        try await withLossHarness { devices, source, resolver, session, reported, clock in
            resolver.set(.pinned(.builtInMic(), alternatives: []))
            // Hold the replacement capture so the loss handler is genuinely in flight when stop runs.
            source.holdNextStart()
            devices.setDevices([.builtInMic()])
            devices.emit(.deviceListChanged)
            _ = await awaitCondition { source.startedMicrophoneIDs.count >= 2 }

            let stopping = Task { await session.stop() }
            await MainActor.run { holdMainActor(milliseconds: 20) }
            source.releaseHeldStart()
            _ = await stopping.value

            // ⚠️ **The oracle is that nothing is *reported* afterwards, not that nothing restarts.**
            // The recorder's terminal gate already refuses a late restart, so a start count cannot tell
            // a joined handler from an unjoined one — my first version of this test asserted exactly
            // that and its negative control passed. What only the join gives is that no notice and no
            // fatal failure reaches a recording that has already finished.
            let messagesAtStop = reported.messages.count
            await MainActor.run { holdMainActor() }
            for _ in 0 ..< 30 { await Task.yield() }
            #expect(reported.messages.count == messagesAtStop,
                    "a message arrived after the recording had stopped")
            #expect(source.isStreaming == false)
        }
    }

    /// ⚠️ **A returning device is not evidence the capture recovered.** Deliver "the headset is gone"
    /// and then "the headset is back" before the handler runs, and keeping only the newest snapshot
    /// throws the proved departure away: no restart is issued and the capture goes on pointing at a
    /// device that left. ⚠️ Deliberately **not** "the stream was torn down": nothing here has
    /// established what ScreenCaptureKit does on an unplug, and a directory notification proves only
    /// that the device went — not that the capture stopped delivering. The rationale stands without the
    /// hardware claim, which I retracted once already.
    @Test("a departure observed before a return is not cancelled by the return")
    @available(macOS 15.0, *)
    func aDepartureIsNotCancelledByAReturn() async throws {
        try await withLossHarness { devices, source, resolver, session, _, clock in
            resolver.set(.pinned(.builtInMic(), alternatives: []))
            let startsBefore = source.startedMicrophoneIDs.count

            // ⚠️ **Both delivered in one actor entry.** Emitting twice through the directory lets the
            // driver run in between, and the test then passes against the very bug it is written for.
            await session.deliverForTesting([
                .devices([.builtInMic()], uninspectable: []),
                .devices([.airPods(), .builtInMic()], uninspectable: []),
            ])

            let restarted = await awaitCondition {
                source.startedMicrophoneIDs.count > startsBefore
            }
            #expect(restarted, "the proved departure was cancelled by the device returning")
            _ = devices
        }
    }

    /// ⚠️ **A pending loss belongs to the capture it was about.** Queue "the AirPods are gone" behind an
    /// explicit switch to a USB microphone and an unscoped flag tears the healthy USB capture down for a
    /// device nobody is using — breaking "a healthy capture is never preempted except by *Use now*",
    /// with the gap and restart-failure risk that rule exists to avoid.
    @Test("a pending loss does not preempt the capture that replaced it",)
    @available(macOS 15.0, *)
    func aPendingLossDoesNotPreemptItsReplacement() async throws {
        try await withLossHarness { devices, source, resolver, session, _, clock in
            // ⚠️ Held first: without this the driver acts on the loss immediately and the test never
            // reaches the state it is about.
            await session.holdLossDriverForTesting()
            await session.deliverForTesting([.devices([.builtInMic()], uninspectable: [])])

            // ⚠️ Stop feeding the writers before any restart. `finishAndAdvance` waits for pending
            // writes to drain, and a clock that emits on every tick keeps producing them — that wait is
            // the 30-second one in the backlog, and it turns this test into a minute.
            clock.freeze()

            // Before that fact is acted on, the user explicitly switches to a USB microphone.
            resolver.set(.pinned(.usbMic(), alternatives: []))
            devices.setDevices([.usbMic(), .builtInMic()])
            _ = await session.switchMicrophone(to: "USBAudioDevice_UID")
            let startsAfterSwitch = source.startedMicrophoneIDs

            // Now let the queued loss run: it must recognise that its capture is gone.
            await session.releaseLossDriverForTesting()
            for _ in 0 ..< 40 { await Task.yield() }

            // ⚠️ Give the post-switch segment some audio. A segment finalised with no samples at all
            // leaves `SegmentWriter.finish()` waiting out its full 30-second cap on stop, which is what
            // turned these two tests into a minute — see the backlog entry on finalisation waits.
            source.enqueueBatch(count: 1)
            source.drain()

            #expect(source.startedMicrophoneIDs == startsAfterSwitch,
                    "a stale loss restarted the capture that replaced it")
        }
    }

    /// ⚠️ **The same-uid variant, which a uid comparison cannot tell apart.** A device that disconnects
    /// and reconnects has the same identity and a different capture, so only a generation distinguishes
    /// "the capture that lost this device" from "the capture that just opened it again".
    @Test("a pending loss does not preempt a capture reopened on the same device",)
    @available(macOS 15.0, *)
    func aPendingLossDoesNotPreemptTheSameDeviceReopened() async throws {
        try await withLossHarness { devices, source, resolver, session, _, clock in
            await session.holdLossDriverForTesting()
            await session.deliverForTesting([.devices([.builtInMic()], uninspectable: [])])

            clock.freeze()
            // The headset comes back and the user deliberately reopens it.
            devices.setDevices([.airPods(), .builtInMic()])
            resolver.set(.pinned(.airPods(), alternatives: []))
            _ = await session.switchMicrophone(to: "00-00-5E-00-53-01:input")
            let startsAfterSwitch = source.startedMicrophoneIDs

            // Now let the queued loss run: it must recognise that its capture is gone.
            await session.releaseLossDriverForTesting()
            for _ in 0 ..< 40 { await Task.yield() }

            // ⚠️ Give the post-switch segment some audio. A segment finalised with no samples at all
            // leaves `SegmentWriter.finish()` waiting out its full 30-second cap on stop, which is what
            // turned these two tests into a minute — see the backlog entry on finalisation waits.
            source.enqueueBatch(count: 1)
            source.drain()

            #expect(source.startedMicrophoneIDs == startsAfterSwitch,
                    "a stale loss restarted a capture reopened on the same device")
        }
    }

    /// ⚠️ **The check has to run where the restart is *admitted*, not where the fact is recorded.** A
    /// user's restart can already own the lifecycle while it is still stopping the old source: the
    /// generation is unchanged when the loss watch looks, so its restart is admitted and queues behind
    /// the user's — and by the time it runs it tears down the healthy capture that replaced the one it
    /// was about. An actor-side check followed by an unconditional queued operation closes nothing.
    ///
    /// Driven against `MicrophoneLossWatch` directly, with a stop-gated source, because the ordering is
    /// the property: through a whole session the scheduler picks the order and the test passes against
    /// the bug. My two previous attempts did exactly that.
    @Test("a loss restart queued behind a user switch is refused at admission")
    @available(macOS 15.0, *)
    func aQueuedLossRestartIsRefusedAtAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-admit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let source = FakeCaptureSource()
            let resolver = FakeCaptureMicrophoneResolver(.pinned(.airPods(), alternatives: []))
            let recorder = AudioRecorder(directory: directory, segmentSeconds: 60,
                                         source: source, permissions: FakePermissions(),
                                         microphone: resolver)
            try await recorder.start()
            let watch = MicrophoneLossWatch(recorder: recorder)
            // ⚠️ **A real sink, not a black hole.** My first version installed `fatal: { _ in }`, so it
            // could not see that the refused restart was being forwarded to the fatal path — which in
            // production parks the phase in error and assembles the healthy recording that replaced it.
            let fatals = ReportedFailures()
            await watch.install(report: { _ in }, fatal: { fatals.record($0) })

            // The user's restart takes the lifecycle and parks inside the teardown of the old capture,
            // so the generation has not advanced yet.
            source.holdNextStop()
            resolver.set(.pinned(.usbMic(), alternatives: []))
            let switching = Task { try await recorder.restart(reason: .userSwitch) }
            // ⚠️ **The signal is the held stop itself.** Waiting on `isStreaming == false` or a stop
            // count cannot succeed on this path — `stop` parks *before* changing either — so the wait
            // burned its whole deadline and the test then proceeded on a state it had never confirmed.
            let parked = await awaitCondition { source.isHoldingStop }
            #expect(parked, "the user's restart never reached the held teardown")

            await watch.observe(.devices([.builtInMic()], uninspectable: []))
            // ⚠️ Asserted, not assumed: the driver must have consumed its fact and be waiting on the
            // lifecycle. Without this the test can pass by never reaching the branch at all.
            var reached = false
            for _ in 0 ..< 2000 where !reached {
                reached = await watch.hasEnteredRestart()
                if !reached { try? await Task.sleep(for: .milliseconds(1)) }
            }
            #expect(reached, "the loss driver never reached its restart — the branch under test was not exercised")

            source.releaseHeldStop()
            try await switching.value

            // ⚠️ **Waited for, not yielded at.** A queued restart is an async lifecycle operation; a
            // fixed number of yields can finish before it does, and the test then passes because it
            // looked too early rather than because nothing happened.
            let preempted = await awaitCondition(timeoutMilliseconds: forbiddenOutcomeWindow) {
                source.startedMicrophoneIDs.count > 2
            }
            #expect(preempted == false,
                    "a queued loss restart tore down the capture that replaced it")
            #expect(fatals.failures.isEmpty,
                    "a refused restart was reported as a recording failure, which stops the recording")
            await watch.stop()
            await recorder.stop()
        }
    }

}

/// A `@Sendable` sink for the messages a session reports.
final class ReportedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ControllerMessage] = []
    func record(_ message: ControllerMessage) { lock.lock(); stored.append(message); lock.unlock() }
    var messages: [ControllerMessage] { lock.lock(); defer { lock.unlock() }; return stored }
}


/// A `@Sendable` sink for the device adoptions a recorder announces.
final class ReportedDevices: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(AudioInputDevice, AudioInputDevice)] = []
    func record(_ previous: AudioInputDevice, _ now: AudioInputDevice) {
        lock.lock(); stored.append((previous, now)); lock.unlock()
    }
    var pairs: [(AudioInputDevice, AudioInputDevice)] { lock.lock(); defer { lock.unlock() }; return stored }
}


/// The shared shape of a loss test: a scripted directory, a fake capture source, a session, and a sink.
@available(macOS 15.0, *)
private func withLossHarness(
    failObservation: String? = nil,
    _ body: (FakeAudioDeviceDirectory, FakeCaptureSource, FakeCaptureMicrophoneResolver,
             RecordingSession, ReportedMessages, TestClock) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("acta-loss-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let devices = FakeAudioDeviceDirectory(devices: [.airPods(), .builtInMic()], defaultInput: nil)
    if let failObservation { devices.failObservation(reason: failObservation) }
    let source = FakeCaptureSource()
    let clock = TestClock()
    clock.onSleep { _ in source.emitBatch() }
    let resolver = FakeCaptureMicrophoneResolver(.pinned(.airPods(), alternatives: [.builtInMic()]))
    let activity = CountingWakeLock()
    let session = RecordingSession(directory: directory,
                                   settings: .default,
                                   wakeLock: activity.makeWakeLock(),
                                   microphone: resolver,
                                   deviceReader: devices,
                                   dependencies: makeDependencies(source: source,
                                                                  permissions: FakePermissions(),
                                                                  clock: clock))
    let reported = ReportedMessages()
    session.onMicrophoneChanged = { reported.record($0) }
    try await session.start()
    try await body(devices, source, resolver, session, reported, clock)
    clock.freeze()
    _ = await session.stop()
}


/// A `@Sendable` sink for the fatal failures a session reports.
final class ReportedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StartupFailure] = []
    func record(_ failure: StartupFailure) { lock.lock(); stored.append(failure); lock.unlock() }
    var failures: [StartupFailure] { lock.lock(); defer { lock.unlock() }; return stored }
}
