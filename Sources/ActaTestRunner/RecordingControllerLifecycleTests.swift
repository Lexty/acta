import ActaKit
import ActaRuntime
import Foundation
import Testing

// A **characterization contract** over `RecordingController` — the one pipeline object the SwiftUI
// menu talks to. It records the lifecycle **as it is today**, faithfully, awkward combinations
// included, because the point of a characterization contract is to catch a *future* change, not to
// define a nicer design now. The observable `ControlAPI` boundary is the next plan; this is what
// protects it.
//
// Every scenario drives a public operation the UI calls (`start`, `stop`, `stopAndWait`, `onLaunch`,
// `onAppear`) and asserts on published state the UI renders or on a durable artifact — never a
// private field, never an internal type reached around the boundary. The pipeline underneath is the
// real one: real `AVAssetWriter`s, a real `SegmentAssembler`, a real `ffmpeg`, with only the
// `CaptureSource` / `PermissionChecking` / `SelfCheckClock` seams injected, so a full recording runs
// with no TCC prompt, no display, no audio device and no wall-clock waiting.
//
// The guards a lifecycle refactor could silently break — the concurrency windows — are in
// `RecordingControllerGuardTests.swift`. The fixtures are in `ControllerTestSupport.swift`.
//
// **Documented gaps — behaviours that are real but cannot be induced honestly through today's public
// surface. They are recorded here rather than faked, because a scenario that cannot run honestly
// characterizes nothing:**
//
// - **An assembly failure at the controller level.** `SegmentAssembler.locateFFmpeg()` checks
//   absolute paths (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`) before `PATH`, so a test
//   cannot make `ffmpeg` "missing" without a seam this plan parks. The failure itself is covered at
//   the `SegmentAssembler` layer (`SegmentAssemblerTests`); what stays uncharacterized is the
//   controller's own reaction to it — `phase == .error` with the marker left at `recording` for
//   recovery.
// - **`openArchive()` failing.** Forcing `NSWorkspace.open` to fail needs a seam. Its
//   lifecycle-independence — it sets `errorMessage` without touching `phase`, so a failed "Open
//   Archive" mid-recording cannot no-op `stop()`'s guard or drop `hasWorkInFlight` — is confirmed by
//   reading the source and left unexercised rather than driven by a test that launches Finder.
// - **`suggestedTitle`.** It comes from the live `SourceDetector.detectedSource()`, which has no
//   injected seam and on a machine with no meeting app running is simply empty. Its refresh is not
//   deterministically observable, so no scenario asserts it.
//
// `.serialized` for the reason the pipeline suites are: these drive real `AVAssetWriter`s and a real
// `ffmpeg` while polling for background work to finish, so running them against each other would
// have them contend for the same cores. Note what the trait does **not** buy — it serializes the
// tests *within* this suite only, and swift-testing still runs this suite alongside the other
// capture-backed ones. So no assertion here may rest on wall-clock duration: the timeouts are
// deadlock guards, the waits are asserted through the injected clock's count, and the one place an
// absence needs real time derives its wait from a pass it measured (`waitOutARecoveryPass`).
@Suite(.serialized)
struct RecordingControllerLifecycleTests {
    // MARK: - Success

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aSuccessfulRecordingPassesThroughEveryPublishedStateAndAssemblesBothTracks() async throws {
        let harness = ControllerHarness(label: "controller-success")
        defer { harness.tearDown() }
        let log = ControllerStateLog(harness.controller)

        // The startup window, observed from inside it. The probe's waits run on the cooperative pool
        // while the main actor sits idle awaiting the start, so this is where "the capture is already
        // live" can be seen at all — and it is live because `session.start()` brings the source up
        // *before* the self-diagnosis it is about to confirm the stream with.
        let captureWasLiveDuringTheProbe = ObservedFlag()
        let source = harness.source
        harness.clock.onSleep { _ in
            if source.isStreaming { captureWasLiveDuringTheProbe.raise() }
            source.emitBatch()
        }

        harness.controller.title = "Weekly sync"
        harness.controller.start()

        // ⚠️ The awkward truth, sampled synchronously before the main actor suspends: `start()` sets
        // the starting flag and spawns its task, so at this instant the controller is busy while
        // `phase` still says `.idle`. `phase` alone does not describe the lifecycle — a refactor
        // collapsing the two into one enum loses exactly this window, and the window is what stops a
        // second click from bringing up a second capture.
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.isBusy, "the startup window is not busy — a second click would start a second capture")
        #expect(harness.controller.isStarting)
        #expect(!harness.controller.isRecording, "the UI would show `Recording` before the stream was ever confirmed")

        let started = await waitUntilOnMain { harness.controller.phase == .recording }
        #expect(started, "the start never reached `.recording`")
        #expect(captureWasLiveDuringTheProbe.isRaised,
                "the capture was never live during the probe — the startup window under test did not happen")

        let directory = try #require(harness.meetingDirectory, "the start created no meeting folder, or more than one")
        // Read **during** the run, not only at the end: a marker written once on stop is
        // indistinguishable from one that tracked the recording if the test only ever sees the final
        // value — and the whole crash-safety story is that this says `recording` while audio is
        // being written, so a `kill -9` here is recoverable.
        #expect(try readSessionManifest(in: directory).status == .recording)
        #expect(harness.controller.isRecording)
        #expect(harness.controller.isBusy)
        #expect(harness.controller.hasWorkInFlight, "quitting now would not wait for a live recording")
        #expect(harness.source.isStreaming, "`phase` says recording while the capture is not live")

        await harness.controller.stopAndWait()

        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isBusy)
        #expect(!harness.controller.hasWorkInFlight)
        #expect(harness.controller.errorMessage.isEmpty)
        // The ordered sequence, not a sample: `.saving` lasts as long as `ffmpeg` takes on a fixture
        // — milliseconds — and reading `phase` after the await would never see it. It is the state
        // that tells the user their audio is still being written, and a contract that cannot see it
        // would not notice a refactor dropping it.
        #expect(log.phases == [.idle, .recording, .saving, .idle],
                "the published phase sequence was \(log.phases)")
        #expect(log.snapshots.contains { $0.isSaving && !$0.isRecording },
                "the UI never rendered `Saving…`: \(log.snapshots)")
        #expect(try readSessionManifest(in: directory).status == .done)
        // The title field is cleared by a successful save, so the next recording starts blank rather
        // than silently inheriting this meeting's name.
        #expect(harness.controller.title.isEmpty,
                "a saved recording left its title in the field — the next recording would inherit it")
        // `info.md`, not only `session.json`: the marker is what recovery reads, but this is what the
        // menu renders and what survives as the meeting's own record. A save that patches one and not
        // the other leaves the archive describing a recording that never finished.
        let info = try String(contentsOf: directory.appendingPathComponent(MeetingArchive.infoFileName),
                              encoding: .utf8)
        #expect(info.contains("status: done"), "the saved recording's info.md does not say `done`: \(info)")
        #expect(info.contains("Weekly sync"), "the saved recording's info.md lost the title it was given")
        let assembled = await bothTracksAssembled(in: directory)
        #expect(assembled, "the recording did not leave two playable tracks behind")
        // The waits were virtual, asserted through the clock's own count. Wall-clock timing cannot
        // decide this: a real probe takes ~2 s, and a machine under load can spend that on the
        // `AVAssetWriter` setup alone.
        #expect(harness.clock.sleepCount >= 1,
                "the recording ran with 0 injected-clock waits — the probe slept on real time")
    }

    // MARK: - Failed start

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aStartDeniedByAMissingPermissionErrorsCleansUpAndGivesTheDisplayBack() async {
        // No `session.json` dimension here on purpose: a denied start has no session directory to
        // inspect — that is the point of the cleanup below.
        let harness = ControllerHarness(label: "controller-denied",
                                        permissions: FakePermissions(screenGranted: false))
        defer { harness.tearDown() }
        let log = ControllerStateLog(harness.controller)

        harness.controller.title = "Phantom meeting"
        harness.controller.start()
        await harness.controller.stopAndWait()

        #expect(harness.controller.phase == .error)
        // The rendered string, because that is all this boundary exposes today. A typed failure
        // crossing it is the next plan's job, and demanding one here would characterize a design
        // rather than the code.
        #expect(harness.controller.errorMessage == StartupFailure.noScreenRecordingPermission.userMessage)
        #expect(!harness.controller.isBusy, "a start that never recorded left the controller busy forever")
        #expect(!harness.controller.hasWorkInFlight)
        #expect(log.phases == [.idle, .error], "the published phase sequence was \(log.phases)")

        // The worst kind of leak: a Mac pinned awake by a recording that never started, with nothing
        // in the UI to explain it.
        #expect(harness.wakeLock.beginCount == 1, "the start never took the display assertion")
        #expect(harness.wakeLock.endCount == 1, "a start rejected for a missing permission leaked the display assertion")
        // Meeting folders specifically: the archive root also holds the generated `CLAUDE.md`, which
        // `MeetingStore` writes whenever it makes sure the root exists.
        let leftovers = meetingFolders(in: harness.root)
        #expect(leftovers.isEmpty,
                "a start that never recorded left \(leftovers) behind — recovery would retry that folder forever")
    }

    // MARK: - Fatal stall

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aFatalStallShowsAnErrorAndStillFinishesAssemblingTheAudioRecordedBeforeIt() async throws {
        let harness = ControllerHarness(label: "controller-stall")
        defer { harness.tearDown() }
        let log = ControllerStateLog(harness.controller)

        harness.controller.start()
        #expect(await waitUntilOnMain { harness.controller.phase == .recording }, "the start never reached `.recording`")
        let directory = try #require(harness.meetingDirectory)

        // Both tracks die and stay dead: every restart in the watchdog's budget brings the stream
        // back up and it still delivers nothing, so the buffer stream is gone for good. This is the
        // path the 2026-07-15 production failure took.
        harness.source.silence(.system)
        harness.source.silence(.mic)

        #expect(await waitUntilOnMain { harness.controller.phase == .error },
                "the watchdog gave up and the UI went on showing `Recording` over a dead stream")
        #expect(harness.controller.errorMessage == StartupFailure.noData.userMessage)

        // ⚠️ The awkward truth this scenario exists for: `phase` is parked in `.error` while the stop
        // and its `ffmpeg` assembly are still running. A single lifecycle enum cannot say both, and
        // `isBusy`/`isSaving` are the only public things that say the work is in flight — drop them
        // in a refactor and "Quit" stops waiting for an assembly that is still writing the file.
        #expect(log.snapshots.contains { $0.phase == .error && $0.isBusy && $0.isSaving },
                "the assembly still running after the stall was invisible on the public surface: \(log.snapshots)")

        // The completion, not merely the error: the audio recorded before the stall is not collateral.
        #expect(await waitUntilOnMain(timeout: 20) { !harness.controller.isBusy },
                "the background assembly never finished")
        #expect(harness.controller.phase == .error, "the error was cleared by the assembly finishing")
        let assembled = await bothTracksAssembled(in: directory)
        #expect(assembled, "the audio recorded before the stall was lost")
        #expect(try readSessionManifest(in: directory).status == .done)

        // `.error` is not a latch: the guard reads `isBusy`, which the finished assembly has dropped,
        // so the user is allowed to try again. With both tracks still dead it fails the same way —
        // what is characterized is that the attempt is *accepted*, not that it succeeds.
        let startsBefore = harness.source.startCount
        harness.controller.start()
        await harness.controller.stopAndWait()
        #expect(harness.source.startCount > startsBefore, "a start after a fatal stall was silently swallowed")
        #expect(harness.controller.phase == .error)
    }

    // MARK: - Stop idempotence

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aSecondStopAfterASavedRecordingChangesNothingObservable() async throws {
        let harness = ControllerHarness(label: "controller-stop-twice")
        defer { harness.tearDown() }
        let log = ControllerStateLog(harness.controller)

        harness.controller.start()
        #expect(await waitUntilOnMain { harness.controller.phase == .recording })
        await harness.controller.stopAndWait()

        let directory = try #require(harness.meetingDirectory)
        let phasesAfterTheStop = log.phases
        let artifactsAfterTheStop = try artifactFingerprint(of: directory)
        let stopsAfterTheStop = harness.source.stopCount

        harness.controller.stop()
        await harness.controller.stopAndWait()

        // Not "no manifest write": a rewrite of identical bytes is unobservable, so what is asserted
        // is the observable no-change — no published transition, no touched artifact, no second
        // assembly. A second `ffmpeg` over the same folder is how a finished recording gets lost.
        #expect(log.phases == phasesAfterTheStop,
                "a second stop published \(log.phases.count - phasesAfterTheStop.count) extra state(s): \(log.phases)")
        #expect(try artifactFingerprint(of: directory) == artifactsAfterTheStop,
                "a second stop rewrote the recording's files — a second assembly ran over them")
        #expect(harness.source.stopCount == stopsAfterTheStop, "a second stop reached the capture source again")
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isBusy)
    }

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aStopOnAControllerThatNeverRecordedIsANoOp() async {
        let harness = ControllerHarness(label: "controller-stop-idle")
        defer { harness.tearDown() }
        let log = ControllerStateLog(harness.controller)

        harness.controller.stop()
        await harness.controller.stopAndWait()

        #expect(log.phases == [.idle], "a stop with nothing to stop published \(log.phases)")
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isBusy)
        #expect(harness.controller.errorMessage.isEmpty)
        #expect(harness.source.stopCount == 0, "a stop with nothing to stop reached the capture source")
        #expect(harness.wakeLock.beginCount == 0)
        #expect(meetingFolders(in: harness.root).isEmpty, "a stop with nothing to stop created a meeting folder")
    }
}
