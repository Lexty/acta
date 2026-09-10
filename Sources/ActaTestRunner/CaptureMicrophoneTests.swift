import ActaKit
@testable import ActaRuntime
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
