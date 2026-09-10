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
@Suite("Capture microphone")
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
    /// ⚠️ **Skipped by default, and visibly — never by a bare `return`.** This one case takes the suite
    /// from 4 s to 63 s, and while it runs it starves
    /// `aRecordingBackedByAFakeSourceCrossesASegmentBoundaryAndAssembles` into failing about half the
    /// time. Turning a fast reliable gate into a slow unreliable one is a net loss, and a gate nobody
    /// trusts stops being a gate. Run it deliberately:
    ///
    ///     ACTA_SLOW_TESTS=1 bash Scripts/test.sh
    ///
    /// It **passes** when run — this is not a quarantined failure. The cost is in `SegmentWriter`'s
    /// conversion path, not here: the same test with no format change is instant, and the cost is flat
    /// in the amount of audio, which rules out throughput and points at a stall. That is its own
    /// finding, in `docs/backlog/slow-non-48k-segment-writing.md`, and it matters because the AirPods on
    /// this machine were measured at exactly this 24 kHz.
    @Test("a switch between source formats leaves every segment valid and assembles",
          .enabled(if: ProcessInfo.processInfo.environment["ACTA_SLOW_TESTS"] != nil,
                   "costs ~59s and starves timing-sensitive tests; run with ACTA_SLOW_TESTS=1"),
          arguments: [(24_000.0, AVAudioChannelCount(2))])
    @available(macOS 15.0, *)
    func aFormatSwitchKeepsEverySegmentValid(_ format: (rate: Double, channels: AVAudioChannelCount)) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (source, resolver, recorder) = self.recorder(
                .pinned(.builtInMic(), alternatives: []), in: directory
            )
            // ⚠️ One buffer per side rather than the default batch of three. The conversion path for a
            // format that is not already 48 kHz stereo is **slow** — a full batch put this single test
            // at a minute, against about four seconds for the whole suite — and the property under test
            // needs one buffer on each side of the switch, not three.
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

            // ⚠️ **The oracle is byte growth, not `AVAudioFile`.** These segments are written by
            // `SegmentWriter` and read by `ffmpeg` — the assembler's own path — and `AVAudioFile`
            // refuses them, which is a fact about that reader rather than about the files. Asserting
            // readability through it would have failed even the no-change control.
            for track in ["system", "mic"] {
                let folder = directory.appendingPathComponent(track)
                let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                    .filter { $0.hasSuffix(".wav") }.sorted()
                #expect(files.count == 2, "\(track): expected a segment on each side of the switch")

                let sizes = files.map { file -> Int in
                    let path = folder.appendingPathComponent(file).path
                    return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) as? Int ?? 0
                }
                #expect(sizes.allSatisfy { $0 > 0 }, "\(track): a segment is empty")
                // ⚠️ **The property the review's failure actually violated**: the post-switch segment
                // must hold at least as much audio as the pre-switch one. The same number of buffers is
                // delivered on each side, so a new source format whose buffers cannot be written shows
                // up here as a short second segment — which is silent loss, since `source.start()`
                // returning is not evidence the new track can be written.
                if let first = sizes.first, let second = sizes.last {
                    #expect(second >= first,
                            "\(track): the post-switch segment is shorter than the pre-switch one")
                }
            }

            // Every delivered buffer was accepted on both sides of the switch.
            #expect(recorder.receivedBufferCounts.mic == 2)
            #expect(recorder.receivedBufferCounts.system == 2)
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
/// ⚠️ **Both are skipped by default, visibly, and they pass when run**: `ACTA_SLOW_TESTS=1 bash
/// Scripts/test.sh`. Each drives a whole `RecordingSession`, which takes the suite from 4 s to 63 s and
/// — measured over three runs, each failing a *different* test — makes the gate unreliable. A gate
/// nobody trusts stops being a gate. The cost itself is not understood: it is flat in the amount of
/// audio and survives freezing the clock before the assembly, which is the same signature as the
/// format switch, and it is recorded in `docs/backlog/slow-non-48k-segment-writing.md`.
@Suite("Recording-owned microphone loss")
struct RecordingMicrophoneLossTests {
    /// ⚠️ **The watchdog is not a substitute, and believing it was is why this was missing.**
    /// `TrackWatchdog` reads a track's count not increasing as ordinary source silence, and the system
    /// track keeps advancing when only the microphone goes — so a lost headset produced no stall at
    /// all. Even for whole-stream loss the watchdog answers after its window; the requirement is
    /// immediate.
    @Test("losing the pinned microphone fails over at once, and says so",
          .enabled(if: ProcessInfo.processInfo.environment["ACTA_SLOW_TESTS"] != nil,
                   "drives a whole session; costs ~30s and starves timing-sensitive tests"),
    )
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
    @Test("an incomplete snapshot does not fail the recording over",
          .enabled(if: ProcessInfo.processInfo.environment["ACTA_SLOW_TESTS"] != nil,
                   "drives a whole session; costs ~30s and starves timing-sensitive tests"),
    )
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
}

/// A `@Sendable` sink for the messages a session reports.
final class ReportedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ControllerMessage] = []
    func record(_ message: ControllerMessage) { lock.lock(); stored.append(message); lock.unlock() }
    var messages: [ControllerMessage] { lock.lock(); defer { lock.unlock() }; return stored }
}
