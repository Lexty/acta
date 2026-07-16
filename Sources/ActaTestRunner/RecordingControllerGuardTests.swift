import ActaKit
import ActaRuntime
import Foundation
import Testing

// The other half of the `RecordingController` characterization contract: the **dangerous concurrency
// windows**, characterized exactly as the code handles them today, plus the launch-time operations.
//
// These are the guards a lifecycle refactor could break in silence. Each of them exists because the
// state the UI reads and the state the pipeline is in are not the same thing for a second or two at
// either end of a recording: `phase` reaches `.recording` only after the ~2 s self-check, and leaves
// it only after the assembly. Everything below lives in those two gaps.
//
// The frozen success/failure scenarios, and the documented gaps, are in
// `RecordingControllerLifecycleTests.swift`; the fixtures are in `ControllerTestSupport.swift`.
@Suite(.serialized)
struct RecordingControllerGuardTests {
    // MARK: - The startup window

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aStopDuringTheStartupWindowIsIgnoredAndTheRecordingCarriesOn() async throws {
        let harness = ControllerHarness(label: "controller-stop-while-starting")
        defer { harness.tearDown() }

        harness.controller.start()
        // Still `.idle`: `stop()` guards on `phase == .recording` and finds nothing to stop, even
        // though the capture is on its way up. Distinct from the quit path below, which is the one
        // that must not leave that capture running.
        #expect(harness.controller.phase == .idle)
        harness.controller.stop()

        #expect(await waitUntilOnMain { harness.controller.phase == .recording },
                "a stop during the startup window cancelled a start it does not own")
        #expect(harness.source.stopCount == 0, "a stop during the startup window tore down a capture that was starting")
        #expect(harness.source.isStreaming)

        await harness.controller.stopAndWait()
        #expect(harness.controller.phase == .idle)
    }

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aStopAndWaitDuringTheStartupWindowTearsDownTheCaptureThatWasAlreadyLive() async throws {
        let harness = ControllerHarness(label: "controller-quit-while-starting")
        defer { harness.tearDown() }

        harness.controller.start()
        // The window under test is the one before `.recording` — the quit path depends on this being
        // the state it finds.
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.isBusy)

        // `stopAndWait()` awaits the start in flight and *then* stops, so the capture that was live
        // while `phase` said `.idle` is actually torn down. A naive "stop only when recording" guard
        // would return instantly here and the process would die on the very segment the start had
        // just opened — which is exactly the `kill -9` this path exists to avoid.
        await harness.controller.stopAndWait()

        #expect(harness.source.stopCount >= 1, "the quit path left a capture running that the start had already brought up")
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isBusy)
        #expect(!harness.controller.hasWorkInFlight, "quitting would not have waited for the work still in flight")

        // The recording the start had already produced is saved, not abandoned.
        let directory = try #require(harness.meetingDirectory)
        #expect(try readSessionManifest(in: directory).status == .done)
        let assembled = await bothTracksAssembled(in: directory)
        #expect(assembled, "a quit during the startup window lost the audio the start had already captured")
    }

    // MARK: - The double click

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aSecondStartWhileStartingOrRecordingDoesNotBringUpASecondCapture() async throws {
        let harness = ControllerHarness(label: "controller-double-start")
        defer { harness.tearDown() }

        harness.controller.start()
        // The second click, inside the startup window: `phase` is still `.idle`, so only the starting
        // flag stands between this and a second session — which would leak the first one's capture
        // and leave two `SCStream`s writing into two folders.
        harness.controller.start()

        #expect(await waitUntilOnMain { harness.controller.phase == .recording })
        #expect(harness.source.startCount == 1, "the second click brought up a second capture")
        #expect(meetingFolders(in: harness.root).count == 1, "the second click created a second meeting folder")

        // And again while recording, where `phase` itself is the guard.
        harness.controller.start()
        await harness.controller.stopAndWait()

        #expect(harness.source.startCount == 1,
                "a start was accepted while one was already running: the source came up \(harness.source.startCount) times")
        #expect(meetingFolders(in: harness.root).count == 1)
        #expect(harness.controller.phase == .idle)
    }

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aStartRightAfterAFailedStartIsAllowedToTryAgain() async {
        let harness = ControllerHarness(label: "controller-start-after-error",
                                        permissions: FakePermissions(screenGranted: false))
        defer { harness.tearDown() }
        let log = ControllerStateLog(harness.controller)

        harness.controller.start()
        await harness.controller.stopAndWait()
        #expect(harness.controller.phase == .error)

        harness.controller.start()
        // ⚠️ The awkward truth: `start()` clears `errorMessage` but **not** `phase`, so during the
        // second startup window the controller is busy while `phase` still reads `.error` — a state
        // no single lifecycle enum can express. `.error` is not a latch: the guard reads `isBusy`,
        // which is false in `.error`, so the attempt goes through.
        #expect(harness.controller.phase == .error)
        #expect(harness.controller.isBusy)
        #expect(harness.controller.errorMessage.isEmpty, "`start()` did not clear the error banner as it began")

        await harness.controller.stopAndWait()

        // The permission is still missing, so it fails the same way. The second `.error` in the
        // published sequence is what proves the attempt actually ran rather than being swallowed.
        #expect(log.phases == [.idle, .error, .error],
                "a start after a failed start was swallowed or latched: \(log.phases)")
        #expect(harness.controller.errorMessage == StartupFailure.noScreenRecordingPermission.userMessage)
        #expect(meetingFolders(in: harness.root).isEmpty, "the retried start left a phantom folder behind")
    }

    // MARK: - Launch and menu

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func recoveryRunsOncePerLaunchAndASecondOnLaunchLeavesANewInterruptedFolderAlone() async throws {
        let harness = ControllerHarness(label: "controller-recovery-once")
        defer { harness.tearDown() }

        let interrupted = try placeInterruptedMeeting(in: harness.root, named: "2026-07-15-1200-standup")
        harness.controller.onLaunch()

        #expect(await waitUntilOnMain(timeout: 20) { !harness.controller.recoveredBanner.isEmpty },
                "the launch never recovered the interrupted recording")
        // `recovered`, not `done`: a folder rescued from a crash is marked apart from one that
        // stopped cleanly, and that distinction is what stops the next launch from assembling it
        // again. `Recovery.needsRecovery` reads only `recording` as interrupted.
        #expect(try readSessionManifest(in: interrupted).status == .recovered)
        let assembled = await bothTracksAssembled(in: interrupted)
        #expect(assembled, "recovery announced a recording it never actually assembled")
        let banner = harness.controller.recoveredBanner
        #expect(harness.controller.recordings.contains { $0.directory.lastPathComponent == "2026-07-15-1200-standup" },
                "the recovered recording never reached the list the menu renders")

        // A folder that appears after the guard has been taken. The claim is scoped to recovery:
        // `Notifier.requestAuthorization()` runs *before* the guard on every `onLaunch`, so "the
        // second launch is a no-op" is deliberately not asserted about notifications.
        let second = try placeInterruptedMeeting(in: harness.root, named: "2026-07-15-1300-planning")
        harness.controller.onLaunch()
        await waitOutARecoveryPass()

        #expect(try readSessionManifest(in: second).status == .recording,
                "a second onLaunch ran recovery again — the once-per-launch guard is gone")
        #expect(harness.controller.recoveredBanner == banner, "a second onLaunch rewrote the banner")
    }

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aStartClearsTheRecoveryBannerAsItBegins() async throws {
        let harness = ControllerHarness(label: "controller-start-clears-banner")
        defer { harness.tearDown() }

        try placeInterruptedMeeting(in: harness.root, named: "2026-07-15-1200-standup")
        harness.controller.onLaunch()
        #expect(await waitUntilOnMain(timeout: 20) { !harness.controller.recoveredBanner.isEmpty },
                "the launch never recovered the interrupted recording")

        harness.controller.start()

        // Synchronously, before the start task has run at all: `start()` clears both banners first
        // thing. So the two are never both meaningfully live across a start — they are not
        // independently latched, and a refactor that keeps the recovery banner up through a new
        // recording would be a behaviour change, not a fix.
        #expect(harness.controller.recoveredBanner.isEmpty, "`start()` left the recovery banner up")
        #expect(harness.controller.errorMessage.isEmpty)

        await harness.controller.stopAndWait()
        #expect(harness.controller.recoveredBanner.isEmpty)
    }

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func onAppearRefreshesTheListAndDoesNotRunRecovery() async throws {
        let harness = ControllerHarness(label: "controller-on-appear")
        defer { harness.tearDown() }

        let interrupted = try placeInterruptedMeeting(in: harness.root, named: "2026-07-15-1400-retro")
        #expect(harness.controller.recordings.isEmpty, "the list was populated before anything asked it to be")

        harness.controller.onAppear()

        #expect(harness.controller.recordings.map { $0.directory.lastPathComponent } == ["2026-07-15-1400-retro"],
                "opening the menu did not rescan the archive")
        // Recovery belongs to `onLaunch` and nowhere else: a menu opened during a recording must not
        // hand the live folder — whose marker reads `recording` — to a recovery pass that would
        // assemble it on the fly. `suggestedTitle` is deliberately not asserted (see the gaps
        // documented in `RecordingControllerLifecycleTests`).
        await waitOutARecoveryPass()
        #expect(try readSessionManifest(in: interrupted).status == .recording,
                "onAppear ran recovery — recovery belongs to onLaunch")
        #expect(harness.controller.recoveredBanner.isEmpty, "onAppear announced a recovery it must not have run")
    }
}
