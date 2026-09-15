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

    // MARK: - The saving window

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aSecondStopInsideTheSavingWindowDoesNotRunASecondAssembly() async throws {
        let harness = ControllerHarness(label: "controller-double-stop-while-saving")
        defer { harness.tearDown() }

        harness.controller.start()
        #expect(await waitUntilOnMain { harness.controller.phase == .recording })

        harness.controller.stop()
        // The window the other stop scenarios cannot reach: `phase` leaves `.recording` only inside
        // `performStop`, so synchronously after `stop()` returns it still reads `.recording` and the
        // first clause of the guard would wave a second click straight through. Only `isStopping`
        // stands between this and a second assembly of the same folder — two `ffmpeg` processes
        // writing the same wav and list files, up to losing the recording.
        #expect(harness.controller.phase == .recording)
        harness.controller.stop()
        await harness.controller.stopAndWait()

        #expect(harness.source.stopCount == 1,
                "a second stop inside the saving window reached the capture source again: \(harness.source.stopCount) stops")
        #expect(meetingFolders(in: harness.root).count == 1)
        #expect(harness.controller.phase == .idle,
                "the recording did not survive a second stop inside the saving window")

        // The audio itself, not merely the bookkeeping: a second `ffmpeg` over the same folder is how
        // a recording that was already safe gets destroyed.
        let directory = try #require(harness.meetingDirectory)
        #expect(try readSessionManifest(in: directory).status == .done)
        let assembled = await bothTracksAssembled(in: directory)
        #expect(assembled, "a second stop inside the saving window lost the recording")
    }

    // MARK: - Launch and menu

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func recoveryRunsOncePerLaunchAndASecondOnLaunchLeavesANewInterruptedFolderAlone() async throws {
        let harness = ControllerHarness(label: "controller-recovery-once")
        defer { harness.tearDown() }

        let interrupted = try placeInterruptedMeeting(in: harness.root, named: "2026-07-15-1200-standup")
        // Timed, because the absence asserted below is only worth something if the wait behind it is
        // longer than a pass actually takes here — see `waitOutARecoveryPass`.
        let firstPassBegan = Date()
        harness.controller.onLaunch()

        #expect(await waitUntilOnMain(timeout: 20) { !harness.controller.recoveredBanner.isEmpty },
                "the launch never recovered the interrupted recording")
        let firstPass = Date().timeIntervalSince(firstPassBegan)
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
        await waitOutARecoveryPass(observedPass: firstPass)

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
        // The pass this scenario's absence is measured against, timed on a sibling harness over the
        // same fixture. It has to come from somewhere: a constant cannot bound a pass whose real cost
        // is `ffmpeg` over a folder, and under load a 500 ms floor is shorter than the very thing
        // whose absence is being asserted — the absence then reports "recovery had not got going yet"
        // as "recovery did not run", and an `onAppear` that ran recovery would sail through.
        //
        // A sibling rather than this harness's own `onLaunch`, so that `onAppear` stays the first
        // operation the controller under test performs. That ordering is the scenario: `runRecovery`
        // carries no guard of its own — `didRunRecovery` sits in `onLaunch` — so an `onAppear` that
        // reached for recovery directly would be caught here, and only while no launch has yet taken
        // the guard.
        let control = ControllerHarness(label: "controller-on-appear-control")
        defer { control.tearDown() }
        let controlFolder = try placeInterruptedMeeting(in: control.root, named: "2026-07-15-1400-retro")
        let passBegan = Date()
        control.controller.onLaunch()
        #expect(await waitUntilOnMain(timeout: 20) { !control.controller.recoveredBanner.isEmpty },
                "the control never recovered — the absence below would prove nothing")
        let observedPass = Date().timeIntervalSince(passBegan)
        #expect(try readSessionManifest(in: controlFolder).status == .recovered)

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
        await waitOutARecoveryPass(observedPass: observedPass)
        #expect(try readSessionManifest(in: interrupted).status == .recording,
                "onAppear ran recovery — recovery belongs to onLaunch")
        #expect(harness.controller.recoveredBanner.isEmpty, "onAppear announced a recovery it must not have run")
    }

    // MARK: - The owner admission

    /// A binding to `bundleID`, minted the only way one can be: from an episode and evidence showing it.
    private static func binding(_ bundleID: String, observedAt: Date) -> OwnerBinding? {
        OwnerBinding.bind(episode: MicrophoneActivityEpisode(id: 1, bundleID: bundleID, displayName: nil),
                          holding: [.bundle(bundleID): .held],
                          epoch: 1, observedAt: observedAt)
    }

    @Test("a parked session.start carries the admitted binding through, and never resolves it again")
    @MainActor
    @available(macOS 15.0, *)
    func aParkedSessionStartPreservesTheAdmittedBinding() async throws {
        let harness = ControllerHarness(label: "controller-owner-parked-start")
        let park = StartupProbePark(harness)
        defer { park.release(); harness.tearDown() }
        let first = try #require(Self.binding("com.aaa.calls", observedAt: Date(timeIntervalSince1970: 1)))
        let later = try #require(Self.binding("com.zzz.dictation", observedAt: Date(timeIntervalSince1970: 2)))

        // The world the resolver reads, which the test moves while the start is parked.
        var world = first
        var resolutions = 0
        harness.controller.start(resolvingOwner: { resolutions += 1; return .bound(world) })
        // ⚠️ Resolved in the latching turn, synchronously — not when the task gets round to it.
        #expect(resolutions == 1)
        #expect(harness.controller.ownerAdmission == .bound(first))

        #expect(await waitUntilOnMain { park.isParked }, "session.start was never parked, so nothing was held")
        #expect(harness.controller.isStarting)
        world = later
        #expect(harness.controller.ownerAdmission == .bound(first),
                "the admission moved while session.start was suspended")

        park.release()
        #expect(await waitUntilOnMain { harness.controller.phase == .recording })
        #expect(resolutions == 1, "the owner was resolved again after the start had been admitted")
        #expect(harness.controller.ownerAdmission == .bound(first),
                "the recording carries an owner other than the one it was admitted with")

        await harness.controller.stopAndWait()
        #expect(harness.controller.ownerAdmission == nil, "a stopped recording kept its owner")
    }

    @Test("a rejected second start cannot alter the first start's pending binding")
    @MainActor
    @available(macOS 15.0, *)
    func aRejectedSecondStartLeavesThePendingBindingAlone() async throws {
        let harness = ControllerHarness(label: "controller-owner-second-start")
        let park = StartupProbePark(harness)
        defer { park.release(); harness.tearDown() }
        let first = try #require(Self.binding("com.aaa.calls", observedAt: Date(timeIntervalSince1970: 1)))
        let second = try #require(Self.binding("com.zzz.dictation", observedAt: Date(timeIntervalSince1970: 2)))

        harness.controller.start(resolvingOwner: { .bound(first) })
        #expect(await waitUntilOnMain { park.isParked }, "session.start was never parked, so nothing was held")

        var secondResolved = false
        harness.controller.start(resolvingOwner: { secondResolved = true; return .bound(second) })
        // ⚠️ Both halves: the rejected start neither ran its resolver nor wrote what it would have said.
        #expect(!secondResolved, "a rejected start resolved an owner")
        #expect(harness.controller.ownerAdmission == .bound(first))
        harness.controller.start()
        #expect(harness.controller.ownerAdmission == .bound(first),
                "a rejected unbound start cleared the pending binding")

        park.release()
        #expect(await waitUntilOnMain { harness.controller.phase == .recording })
        #expect(harness.controller.ownerAdmission == .bound(first))
        #expect(harness.source.startCount == 1)
        await harness.controller.stopAndWait()
    }

    @Test("a failed start discards the binding it was admitted with")
    @MainActor
    @available(macOS 15.0, *)
    func aFailedStartDiscardsItsBinding() async throws {
        let harness = ControllerHarness(label: "controller-owner-failed-start",
                                        permissions: FakePermissions(screenGranted: false))
        defer { harness.tearDown() }
        let first = try #require(Self.binding("com.aaa.calls", observedAt: Date(timeIntervalSince1970: 1)))

        harness.controller.start(resolvingOwner: { .bound(first) })
        #expect(harness.controller.ownerAdmission == .bound(first))
        await harness.controller.stopAndWait()
        #expect(harness.controller.phase == .error)
        #expect(harness.controller.ownerAdmission == nil, "a failed start left its binding behind")
    }

    @Test("menu and socket starts pass the same admission seam and deliberately produce no binding")
    @MainActor
    @available(macOS 15.0, *)
    func menuAndSocketStartsAreAdmittedUnbound() async throws {
        let (_, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                          defaultInput: "BuiltInMicrophoneDevice")
        manager.start()

        // The menu: `ControlViewModel.start()` is what the button calls.
        let menu = ControllerHarness(label: "controller-owner-menu")
        defer { menu.tearDown() }
        let menuAPI = ControlAPI(controller: menu.controller, microphone: manager)
        ControlViewModel(api: menuAPI).start()
        // Visible in the same turn the start was latched, through the projection a client reads.
        #expect(menuAPI.state.operation == .starting)
        #expect(menuAPI.state.ownerAdmission == .unbound(.notStartedFromPrompt))
        #expect(await waitUntilOnMain { menu.controller.phase == .recording })
        #expect(menuAPI.state.ownerAdmission == .unbound(.notStartedFromPrompt))
        await menu.controller.stopAndWait()
        #expect(menuAPI.state.ownerAdmission == nil)

        // The socket: a `.socket` dispatcher over a real façade. The command has no owner field to send.
        let socket = ControllerHarness(label: "controller-owner-socket")
        defer { socket.tearDown() }
        let socketAPI = ControlAPI(controller: socket.controller, microphone: manager)
        let dispatcher = ControlDispatcher(service: socketAPI, confinement: .socket)
        _ = await dispatcher.handle(.start(title: "Weekly sync"))
        #expect(socketAPI.state.operation != .idle, "the socket start was not admitted at all")
        #expect(await waitUntilOnMain { socket.controller.phase == .recording })
        #expect(socketAPI.state.ownerAdmission == .unbound(.notStartedFromPrompt))
        await socket.controller.stopAndWait()
    }
}

/// Holds `session.start` inside its startup probe until released.
///
/// ⚠️ **It blocks a pool thread, on purpose and only there.** `RecordingSession.start` is `nonisolated`,
/// so the probe's sleep runs on the cooperative pool while the main actor stays free for the test to
/// observe the controller mid-start. The batch is emitted *before* parking, so the probe still sees audio
/// when it resumes.
@available(macOS 15.0, *)
final class StartupProbePark: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var parked = false
    private var used = false
    private var released = false

    @MainActor
    init(_ harness: ControllerHarness) {
        let source = harness.source
        harness.clock.onSleep { [self] _ in
            source.emitBatch()
            let shouldPark: Bool = {
                lock.lock(); defer { lock.unlock() }
                guard !used, !released else { return false }
                used = true
                parked = true
                return true
            }()
            if shouldPark { gate.wait() }
        }
    }

    var isParked: Bool { lock.lock(); defer { lock.unlock() }; return parked }

    /// Let the parked probe go. Idempotent, so a failing test's `defer` cannot hang the suite.
    func release() {
        lock.lock()
        let wasParked = parked && !released
        released = true
        parked = false
        lock.unlock()
        if wasParked { gate.signal() }
    }
}
