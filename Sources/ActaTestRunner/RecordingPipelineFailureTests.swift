import AVFoundation
import ActaKit
import ActaRuntime
import Foundation
import Testing

// The capture-backed pipeline's failure paths: a permission the user refused, a source that comes up
// and never delivers, a stream that dies mid-recording, and the watchdog giving up on one that never
// comes back. The success path is in `RecordingPipelineTests.swift`; the fixtures both use are in
// `PipelineTestSupport.swift`.
//
// `.serialized` for the same reason the success suite is: these drive real `AVAssetWriter`s and a
// real `ffmpeg` while asserting wall-clock bounds that prove the injected clock is wired. Run in
// parallel they would measure the machine's load instead.
@Suite(.serialized)
struct RecordingPipelineFailureTests {
    @Test
    @available(macOS 15.0, *)
    func screenRecordingDeniedRejectsTheStartAndLeavesNoWakeLockHeld() async {
        let directory = makeTemporaryDirectory("pipeline-denied")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FakeCaptureSource()
        // Denied, and the dialog does not change the user's mind — the same shape as a permission
        // the user has already refused.
        let permissions = FakePermissions(screenGranted: false, grantsOnRequest: false)
        let clock = TestClock()
        let activity = CountingWakeLock()

        let session = RecordingSession(directory: directory, settings: makeSettings(),
                                       wakeLock: activity.makeWakeLock(),
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: permissions,
                                                                      clock: clock))

        await #expect(throws: StartupFailure.noScreenRecordingPermission) {
            try await session.start()
        }

        // A permission is not healed by restarting the stream, so the capture must never have been
        // brought up at all.
        #expect(source.startCount == 0, "the capture was started despite a missing permission")
        #expect(permissions.screenRequestCount == 1, "the missing permission was never actually requested")
        // The worst kind of leak: a Mac pinned awake by a recording that never started, with nothing
        // in the UI to explain it.
        #expect(activity.beginCount == 1, "start() never took the display assertion")
        #expect(activity.endCount == 1, "a start rejected for a missing permission leaked the display assertion")
    }

    @Test
    @available(macOS 15.0, *)
    func microphoneDeniedRejectsTheStartAndLeavesNoWakeLockHeld() async {
        let directory = makeTemporaryDirectory("pipeline-mic-denied")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FakeCaptureSource()
        // Screen recording granted, the microphone refused: half a meeting is not a recording, so
        // this start must be rejected exactly as a missing screen permission is. The mic branch has
        // an extra step the screen branch does not — a `.notDetermined` status is prompted for — so
        // `.denied` is the shape that must *not* prompt.
        let permissions = FakePermissions(screenGranted: true, micStatus: .denied)
        let clock = TestClock()
        let activity = CountingWakeLock()

        let session = RecordingSession(directory: directory, settings: makeSettings(),
                                       wakeLock: activity.makeWakeLock(),
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: permissions,
                                                                      clock: clock))

        await #expect(throws: StartupFailure.noMicrophonePermission) {
            try await session.start()
        }

        #expect(source.startCount == 0, "the capture was started despite a missing microphone permission")
        #expect(permissions.micRequestCount == 0,
                "a permission the user already refused was prompted for again — a dialog on every start")
        #expect(activity.beginCount == 1, "start() never took the display assertion")
        #expect(activity.endCount == 1, "a start rejected for a missing permission leaked the display assertion")
    }

    @Test
    @available(macOS 15.0, *)
    func anUndeterminedMicrophoneIsPromptedForAndTheGrantedStartProceeds() async throws {
        let directory = makeTemporaryDirectory("pipeline-mic-prompt")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FakeCaptureSource()
        // The first launch: nobody has answered the microphone dialog yet, and the user agrees to
        // it. The recording must then proceed — the prompt is a step on the way, not a refusal.
        let permissions = FakePermissions(screenGranted: true, micStatus: .notDetermined,
                                          grantsOnRequest: true)
        let clock = TestClock()
        clock.onSleep { _ in source.emitBatch() }

        let session = RecordingSession(directory: directory, settings: makeSettings(),
                                       wakeLock: CountingWakeLock().makeWakeLock(),
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: permissions,
                                                                      clock: clock))
        try await session.start()
        _ = await session.stop()

        #expect(permissions.micRequestCount == 1,
                "an undetermined microphone permission was never actually prompted for")
        #expect(source.startCount == 1, "the start did not proceed after the user granted the microphone")
    }

    @Test
    @available(macOS 15.0, *)
    func aSourceThatNeverDeliversIsRestartedAndThenGivenUpOn() async {
        let directory = makeTemporaryDirectory("pipeline-nodata")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FakeCaptureSource()
        // The stream comes up and stays up; it simply never produces a buffer. Nothing to hear, and
        // no error to go on — exactly the "mute recording" the self-diagnosis exists to refuse.
        source.setEmitOnStart(false)
        let permissions = FakePermissions()
        let clock = TestClock()
        let activity = CountingWakeLock()

        let session = RecordingSession(directory: directory, settings: makeSettings(),
                                       wakeLock: activity.makeWakeLock(),
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: permissions,
                                                                      clock: clock))

        let began = Date()
        await #expect(throws: StartupFailure.noData) {
            try await session.start()
        }
        let seconds = Date().timeIntervalSince(began)

        // The budget, spent exactly: one start to open the recording, then `maxRestartAttempts`
        // stop/start pairs, because there is no `restart()` on the source — restart is
        // `AudioRecorder` composing stop → finalize both writers → start. The final stop is the
        // session giving up and tearing the capture down.
        #expect(source.startCount == 1 + SelfCheckTuning.maxRestartAttempts,
                "the healing spent \(source.startCount - 1) restarts, not \(SelfCheckTuning.maxRestartAttempts)")
        #expect(source.stopCount == SelfCheckTuning.maxRestartAttempts + 1,
                "every restart must stop the source first, and the give-up must stop it once more")
        #expect(permissions.screenRequestCount == 0, "a granted permission was requested during healing")
        #expect(permissions.micRequestCount == 0, "a granted permission was requested during healing")
        #expect(activity.endCount == 1, "a start that never became a recording leaked the display assertion")
        // Four startup probes of 2 s each in real time would be eight seconds.
        #expect(seconds < clockWiredWallClockBound,
                "giving up took \(seconds) s of real time — the injected clock is not wired")
    }

    @Test
    @available(macOS 15.0, *)
    func aStreamThatDiesMidRecordingIsRestartedByTheWatchdog() async throws {
        let directory = makeTemporaryDirectory("pipeline-watchdog")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FakeCaptureSource()
        let permissions = FakePermissions()
        let clock = TestClock()
        clock.onSleep { _ in source.emitBatch() }

        let session = RecordingSession(directory: directory, settings: makeSettings(),
                                       wakeLock: CountingWakeLock().makeWakeLock(),
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: permissions,
                                                                      clock: clock))
        try await session.start()
        #expect(source.startCount == 1)

        // The stream dies without saying so: buffers simply stop. Only a restart brings it back,
        // which is what the watchdog is for — and the segments already on disk must survive it.
        let began = Date()
        source.goSilentUntilRestart()
        let restarted = await waitUntil { source.startCount >= 2 }
        let seconds = Date().timeIntervalSince(began)

        #expect(restarted, "the watchdog never restarted a stream that stopped delivering")
        #expect(source.startCount == 2, "the watchdog restarted more than once after the stream recovered")
        #expect(source.stopCount == 1, "the restart did not stop the dead stream first")
        // The stall threshold is six virtual seconds and the tick is one; in real time the whole
        // detection is milliseconds. Anything near this bound means the watchdog is waiting on the
        // wall clock.
        #expect(seconds < clockWiredWallClockBound,
                "the watchdog took \(seconds) s of real time to notice the stall — the clock is not wired")

        let result = await session.stop()
        let assembled = try #require(result, "the recording did not survive the watchdog's restart")
        #expect(try #require(assembled.durationSeconds) > 0)
        for name in [SegmentLayout.systemTrackFileName, SegmentLayout.micTrackFileName] {
            let valid = await isRealAudioFile(directory.appendingPathComponent(name))
            #expect(valid, "\(name): the track assembled after a restart is not playable audio")
        }
    }

    @Test
    @available(macOS 15.0, *)
    func aStreamThatNeverComesBackExhaustsTheBudgetAndReportsTheStall() async throws {
        let directory = makeTemporaryDirectory("pipeline-fatal-stall")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FakeCaptureSource()
        let permissions = FakePermissions()
        let clock = TestClock()
        clock.onSleep { _ in source.emitBatch() }

        let session = RecordingSession(directory: directory, settings: makeSettings(),
                                       wakeLock: CountingWakeLock().makeWakeLock(),
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: permissions,
                                                                      clock: clock))

        let stalls = ReportedStalls()
        // The path the 2026-07-15 production failure took, and until now the one path the suite
        // drove nowhere near: the watchdog gives up. Everything past a *successful* restart —
        // the budget running out, the failure the user is finally told — was uncovered, and the UI
        // showing "recording" over a dead stream is the one thing the whole self-diagnosis exists to
        // rule out.
        try await session.start(onStall: { stalls.record($0) })
        #expect(source.startCount == 1)

        // Both tracks die and stay dead: a restart brings the stream back up and it still produces
        // nothing, so every attempt in the budget is spent and none of them helps.
        source.silence(.system)
        source.silence(.mic)

        let began = Date()
        let gaveUp = await waitUntil { stalls.count > 0 }
        let seconds = Date().timeIntervalSince(began)

        #expect(gaveUp, "the watchdog never gave up on a stream that stopped delivering for good")
        // `.noData` and not `.diskWriteFailed`: nothing is arriving to be written. The distinction is
        // the whole point of tracking received separately from written — it is what the user is told.
        #expect(stalls.reported == [.noData],
                "the watchdog reported \(stalls.reported) — the user is told the wrong cause")
        // One start to open the recording, then the full restart budget, each spent on a stream that
        // comes up and delivers nothing.
        #expect(source.startCount == 1 + SelfCheckTuning.maxRestartAttempts,
                "the watchdog spent \(source.startCount - 1) restarts, not \(SelfCheckTuning.maxRestartAttempts)")
        #expect(seconds < clockWiredWallClockBound,
                "giving up took \(seconds) s of real time — the injected clock is not wired")

        // The audio recorded before the stall is not collateral: it must still assemble.
        let result = await session.stop()
        let assembled = try #require(result, "the audio recorded before the stall was lost")
        #expect(try #require(assembled.durationSeconds) > 0)
    }

    @Test
    @available(macOS 15.0, *)
    func aSilentMicrophoneIsNotTreatedAsAFailureAndTheRecordingCarriesOn() async throws {
        let directory = makeTemporaryDirectory("pipeline-silent-mic")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FakeCaptureSource()
        let permissions = FakePermissions()
        let clock = TestClock()
        clock.onSleep { _ in source.emitBatch() }

        let session = RecordingSession(directory: directory, settings: makeSettings(),
                                       wakeLock: CountingWakeLock().makeWakeLock(),
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: permissions,
                                                                      clock: clock))

        let stalls = ReportedStalls()
        // The microphone produces nothing from the very first buffer — a muted device, or simply a
        // silent room. The two are indistinguishable from here, which is exactly why this must not
        // abort anything: `TrackWatchdog` only calls a track stalled when it *receives* buffers and
        // writes none, and a source that sends nothing is idle, not broken. Aborting an hour of
        // system audio because nobody spoke into the mic is the failure this asserts against.
        source.silence(.mic)
        try await session.start(onStall: { stalls.record($0) })

        // Give the watchdog several ticks to overreact, if it is going to. The result is asserted and
        // not discarded: if the ticks never happen, the watchdog never got the chance to misbehave and
        // the expectations below would pass having proven nothing.
        let ticked = await waitUntil(timeout: 0.5) { clock.sleepCount > 6 }
        #expect(ticked, "the watchdog never ticked — the silence below was never actually watched")
        #expect(stalls.reported.isEmpty, "a silent microphone was reported as a failure: \(stalls.reported)")
        #expect(source.startCount == 1, "a silent microphone triggered a pointless stream restart")

        let result = await session.stop()
        let assembled = try #require(result, "a silent microphone cost the whole recording")
        #expect(try #require(assembled.durationSeconds) > 0)
        // The live track recorded; the silent one is empty rather than absent, and neither is an
        // error the user is shown.
        let systemSegments = segmentFiles(in: directory, track: SegmentLayout.systemDirName)
        #expect(!systemSegments.isEmpty, "the live system track recorded nothing while the mic was silent")
    }

    @Test
    @available(macOS 15.0, *)
    func aPermissionRevokedDuringTheStartupProbeIsDiagnosedRatherThanRestartedAround() async {
        let directory = makeTemporaryDirectory("pipeline-revoked-screen")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FakeCaptureSource()
        let permissions = FakePermissions(screenGranted: true, grantsOnRequest: false)
        let clock = TestClock()
        // The user opens System Settings and takes screen recording away while the probe is running.
        // This is the *only* way into `SelfCheck`'s permission diagnosis: `AudioRecorder` rejects a
        // start whose permissions are already missing, so everything below it is only reachable by a
        // permission that disappears after the start was allowed through.
        clock.onSleep { _ in permissions.revokeScreenRecording() }

        let session = RecordingSession(directory: directory, settings: makeSettings(),
                                       wakeLock: CountingWakeLock().makeWakeLock(),
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: permissions,
                                                                      clock: clock))

        // Not `.noData`: a revoked permission is why the buffers stopped, and telling the user to
        // "check your audio device" would send them looking in the wrong place entirely.
        await #expect(throws: StartupFailure.noScreenRecordingPermission) {
            try await session.start()
        }
        #expect(permissions.screenRequestCount == 1,
                "the revoked permission was never requested, or the dialog was shown more than once")
        // A permission is not healed by restarting the stream — the restart budget must stay untouched.
        #expect(source.startCount == 1, "a revoked permission was answered with a pointless restart")
    }

    @Test
    @available(macOS 15.0, *)
    func eachPermissionDialogIsTrackedSeparatelyWhenBothGoMissingAtOnce() async throws {
        let directory = makeTemporaryDirectory("pipeline-both-revoked")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FakeCaptureSource()
        // Both permissions vanish inside the probe window — screen revoked, the microphone reset to
        // "never asked" — and the user grants both when asked.
        let permissions = FakePermissions(screenGranted: true, grantsOnRequest: true)
        let clock = TestClock()
        let firstSleep = OnceFlag()
        clock.onSleep { _ in
            if firstSleep.takeIfFirst() {
                permissions.revokeScreenRecording()
                permissions.resetMicrophone()
                // Deliberately no batch on this tick. `SelfDiagnosis` clears a snapshot whose data is
                // flowing *before* it looks at the permissions — a live recording is fine whatever TCC
                // now says — so a probe window with buffers in it never reaches the dialogs at all.
                return
            }
            source.emitBatch()
        }

        let session = RecordingSession(directory: directory, settings: makeSettings(),
                                       wakeLock: CountingWakeLock().makeWakeLock(),
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: permissions,
                                                                      clock: clock))

        try await session.start()
        _ = await session.stop()

        // The point of this test, and the reason the flags are per-permission rather than one shared
        // `Bool`: with a single flag, requesting screen recording marks *both* as asked, the
        // microphone dialog is never shown, and the user is told to grant a permission nobody ever put
        // a dialog in front of them for.
        #expect(permissions.screenRequestCount == 1,
                "the screen dialog was shown \(permissions.screenRequestCount) times, expected exactly one")
        #expect(permissions.micRequestCount == 1,
                "the microphone dialog was never shown — a screen request suppressed it")
    }
}

/// A one-shot latch for the `onSleep` handlers below: the clock's callback is `@Sendable` and fires on
/// whatever task is sleeping, so "do this on the first tick only" needs real synchronization.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func takeIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
