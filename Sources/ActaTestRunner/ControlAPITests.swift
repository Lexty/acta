import ActaKit
import ActaRuntime
import Foundation
import Testing

// The `ControlAPI` façade, driven over the **real pipeline** — a `RecordingController` built by
// `ControllerHarness` with the same seams the characterization scenarios inject (a scripted
// `FakeCaptureSource`, `PermissionChecking`, a `SelfCheckClock`), so a full recording runs with no TCC
// prompt, no display, no audio device and no wall-clock waiting. Never `ControlAPI.shared`: it wraps
// `RecordingController.shared`, which reaches for the real `~/Acta`, real TCC and real time.
//
// **What is deliberately *not* here.** The archive-open notice and the assembly-failure classification
// cannot be induced through today's public surface — `NSWorkspace.open` and
// `SegmentAssembler.locateFFmpeg()` both need a seam this plan parks, and
// `RecordingControllerLifecycleTests` already lists them as documented gaps. They are covered
// exhaustively by `ControlStateTests` over synthetic snapshots, which is the whole reason the mapping
// is a pure function. Faking them here would prove only that a fake was built.
//
// `.serialized` for the reason the other capture-backed suites are: these drive real `AVAssetWriter`s
// and a real `ffmpeg` while polling for background work. No assertion may rest on wall-clock duration —
// the timeouts are deadlock guards and the waits are asserted through the injected clock's count.

/// The `Operation` without its payload — what the ordered assertions below compare on.
///
/// Elapsed seconds cannot be in the sequence: they come from real one-second ticks, and a fixture-sized
/// recording is milliseconds long, so `.recording(0)` versus `.recording(1)` is a scheduling race, not
/// a lifecycle transition.
@available(macOS 15.0, *)
private enum OperationKind: String, Equatable {
    case idle, starting, recording, saving

    init(_ operation: ControlState.Operation) {
        switch operation {
        case .idle: self = .idle
        case .starting: self = .starting
        case .recording: self = .recording
        case .saving: self = .saving
        }
    }
}

/// Everything a `states()` stream yielded, in order.
///
/// A task draining the stream rather than a callback: `states()` is an `AsyncStream`, and consuming it
/// the way a real client would is the only way the ordering guarantee under test is the one being
/// asserted.
@MainActor
@available(macOS 15.0, *)
private final class StateLog {
    private(set) var states: [ControlState] = []
    private var task: Task<Void, Never>?

    init(_ api: ControlAPI) {
        let stream = api.states()
        task = Task { @MainActor [weak self] in
            for await state in stream { self?.states.append(state) }
        }
    }

    /// The operation sequence, with consecutive duplicates collapsed — a `.recording` that ticks its
    /// elapsed counter is one operation, not two.
    var operations: [OperationKind] {
        states.map { OperationKind($0.operation) }.reduce(into: []) { kinds, kind in
            if kinds.last != kind { kinds.append(kind) }
        }
    }

    func stop() { task?.cancel() }
}

/// Let the draining task and the façade's deferred sample run before reading the log.
///
/// The last state of all is published one main-actor turn after the change that produced it (the
/// façade's own sampling limit, documented on `states()`), and the log's `for await` is a task of its
/// own. Yielding rather than sleeping: this waits on the main actor's queue, not on time.
@MainActor
private func settle() async {
    for _ in 0..<10 { await Task.yield() }
}

@Suite(.serialized)
struct ControlAPITests {
    // MARK: - The full success path

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aRecordingDrivenThroughTheFacadeWalksTheOperationsAndAssemblesBothTracks() async throws {
        let harness = ControllerHarness(label: "api-success")
        defer { harness.tearDown() }
        let api = ControlAPI(controller: harness.controller, microphone: makeTestMicrophoneManager().2)
        defer { api.finish() }
        let log = StateLog(api)
        defer { log.stop() }

        #expect(api.state.operation == .idle)
        #expect(api.state.canStart)

        api.start(title: "Weekly sync")

        // Synchronously inside the startup window: the capture is coming up while the controller's
        // `phase` still reads `.idle`. The façade's whole point is that this reads `.starting` — a
        // window `phase` alone cannot name, and the one that stops a second click from bringing up a
        // second capture.
        #expect(api.state.operation == .starting)
        #expect(api.state.hasWorkInFlight, "the startup window claimed no work in flight")
        #expect(!api.state.canStart)
        #expect(api.title == "Weekly sync", "`start(title:)` did not set the controller's title")

        let started = await waitUntilOnMain { OperationKind(api.state.operation) == .recording }
        #expect(started, "the start never reached `.recording`")
        #expect(api.state.canStop)
        #expect(api.state.lifecycleFailure == nil)
        #expect(api.state.notice == nil)
        let directory = try #require(harness.meetingDirectory, "the start created no meeting folder, or more than one")
        #expect(try readSessionManifest(in: directory).status == .recording)

        await api.stopAndWait()
        await settle()

        #expect(api.state.operation == .idle)
        #expect(!api.state.hasWorkInFlight)
        #expect(api.state.lifecycleFailure == nil)
        // The ordered sequence, not a sample. `.saving` lasts as long as `ffmpeg` takes on a fixture —
        // milliseconds — so only the stream can see it, and it is the state that tells the user their
        // audio is still being written.
        #expect(log.operations == [.idle, .starting, .recording, .saving, .idle],
                "the streamed operation sequence was \(log.operations)")
        #expect(try readSessionManifest(in: directory).status == .done)
        let assembled = await bothTracksAssembled(in: directory)
        #expect(assembled, "the recording did not leave two playable tracks behind")
        // The waits were virtual. Wall-clock timing cannot decide this: a real probe takes ~2 s, and a
        // loaded machine can spend that on the `AVAssetWriter` setup alone.
        #expect(harness.clock.sleepCount >= 1,
                "the recording ran with 0 injected-clock waits — the probe slept on real time")
    }

    // MARK: - Replay and ordering

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aSubscriberJoiningMidRecordingIsReplayedTheCurrentStateAndThenTheTransitions() async throws {
        let harness = ControllerHarness(label: "api-replay")
        defer { harness.tearDown() }
        let api = ControlAPI(controller: harness.controller, microphone: makeTestMicrophoneManager().2)
        defer { api.finish() }

        api.start(title: "Replay")
        #expect(await waitUntilOnMain { OperationKind(api.state.operation) == .recording },
                "the start never reached `.recording`")

        // Subscribing *after* the recording began: the first element must be the state as it stands,
        // not the `.idle` this stream missed and not a wait for the next change.
        let late = StateLog(api)
        defer { late.stop() }
        await settle()
        let first = try #require(late.states.first, "a new subscriber was handed nothing")
        #expect(OperationKind(first.operation) == .recording,
                "a new subscriber was not replayed the current state: \(first.operation)")
        #expect(first == api.state, "the replayed first element and `state` disagree — two sources of truth")

        await api.stopAndWait()
        await settle()

        #expect(late.operations == [.recording, .saving, .idle],
                "the late subscriber's sequence was \(late.operations)")
    }

    // MARK: - A failed start

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aStartDeniedByAMissingPermissionSettlesIdleCarryingATypedFailure() async {
        let harness = ControllerHarness(label: "api-denied",
                                        permissions: FakePermissions(screenGranted: false))
        defer { harness.tearDown() }
        let api = ControlAPI(controller: harness.controller, microphone: makeTestMicrophoneManager().2)
        defer { api.finish() }
        let log = StateLog(api)
        defer { log.stop() }

        api.start(title: "Phantom meeting")
        await api.stopAndWait()
        await settle()

        // The orthogonality the type exists for: the recorder is **idle** — a start is allowed again —
        // and the failure is carried beside the operation rather than instead of it. The controller's
        // `phase` is parked in `.error` all the while.
        #expect(api.state.operation == .idle)
        #expect(!api.state.hasWorkInFlight, "a start that never recorded left work in flight forever")
        #expect(api.state.canStart, "`.error` latched into the façade — a retry would be refused")
        #expect(api.state.lifecycleFailure?.category == .startup(.noScreenRecordingPermission))
        // Byte-identical to what the menu renders today — the migration must not change a string.
        #expect(api.state.lifecycleFailure?.displayMessage == StartupFailure.noScreenRecordingPermission.userMessage)
        #expect(api.state.notice == nil)
        #expect(log.operations == [.idle, .starting, .idle], "the streamed operation sequence was \(log.operations)")
        // A Mac pinned awake by a recording that never started is the worst kind of leak.
        #expect(harness.wakeLock.beginCount == 1, "the start never took the display assertion")
        #expect(harness.wakeLock.endCount == 1, "a denied start leaked the display assertion")
        #expect(meetingFolders(in: harness.root).isEmpty,
                "a start that never recorded left a phantom folder — recovery would retry it forever")
    }

    // MARK: - The guards, seen through the façade

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aStopDuringTheStartupWindowIsIgnoredAndASecondStartBringsUpNoSecondCapture() async throws {
        let harness = ControllerHarness(label: "api-guards")
        defer { harness.tearDown() }
        let api = ControlAPI(controller: harness.controller, microphone: makeTestMicrophoneManager().2)
        defer { api.finish() }

        api.start(title: "Guarded")
        #expect(api.state.operation == .starting)
        // Both dangerous clicks, inside the window where the capture is live and the operation is not
        // yet `.recording`: a stop that owns nothing, and a second start.
        api.stop()
        api.start(title: "Second")

        #expect(await waitUntilOnMain { OperationKind(api.state.operation) == .recording },
                "a stop during the startup window cancelled a start it does not own")
        #expect(harness.source.startCount == 1, "the second start brought up a second capture")
        #expect(harness.source.stopCount == 0, "a stop during the startup window tore down a capture that was starting")
        #expect(meetingFolders(in: harness.root).count == 1, "the second start created a second meeting folder")

        await api.stopAndWait()
        #expect(api.state.operation == .idle)
    }

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func aSecondStopAfterASavedRecordingChangesNothingObservable() async throws {
        let harness = ControllerHarness(label: "api-stop-twice")
        defer { harness.tearDown() }
        let api = ControlAPI(controller: harness.controller, microphone: makeTestMicrophoneManager().2)
        defer { api.finish() }
        let log = StateLog(api)
        defer { log.stop() }

        api.start()
        #expect(await waitUntilOnMain { OperationKind(api.state.operation) == .recording })
        await api.stopAndWait()
        await settle()

        let directory = try #require(harness.meetingDirectory)
        let statesAfterTheStop = log.states
        let artifactsAfterTheStop = try artifactFingerprint(of: directory)

        api.stop()
        await api.stopAndWait()
        await settle()

        // Not "no write": a rewrite of identical bytes is unobservable, so what is asserted is the
        // observable no-change — no streamed state, no touched artifact, no second `ffmpeg` over the
        // same folder, which is how a finished recording gets lost.
        #expect(log.states == statesAfterTheStop,
                "a second stop streamed \(log.states.count - statesAfterTheStop.count) extra state(s)")
        #expect(try artifactFingerprint(of: directory) == artifactsAfterTheStop,
                "a second stop rewrote the recording's files — a second assembly ran over them")
        #expect(harness.source.stopCount == 1, "a second stop reached the capture source again")
        #expect(api.state.operation == .idle)
    }

    // MARK: - Launch and menu

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func recoverRunsOnceAndRefreshNeverRecovers() async throws {
        let harness = ControllerHarness(label: "api-recover-once")
        defer { harness.tearDown() }
        let api = ControlAPI(controller: harness.controller, microphone: makeTestMicrophoneManager().2)
        defer { api.finish() }

        let interrupted = try placeInterruptedMeeting(in: harness.root, named: "2026-07-15-1200-standup")
        // Timed, because the two absences below are only worth something if the wait behind them is
        // longer than a pass actually takes here — see `waitOutARecoveryPass`.
        let firstPassBegan = Date()
        api.recover()

        #expect(await waitUntilOnMain(timeout: 20) { api.state.recoveryNotice != nil },
                "`recover()` never recovered the interrupted recording")
        let firstPass = Date().timeIntervalSince(firstPassBegan)
        // The recovery notice is its own field, mapped from the controller's separate `recoveredBanner`
        // — so it stands beside the (absent) failure rather than competing with it for one string.
        let notice = try #require(api.state.recoveryNotice)
        #expect(api.state.lifecycleFailure == nil)
        #expect(try readSessionManifest(in: interrupted).status == .recovered)
        let assembled = await bothTracksAssembled(in: interrupted)
        #expect(assembled, "recovery announced a recording it never actually assembled")
        #expect(api.state.recordings.contains { $0.directory.lastPathComponent == "2026-07-15-1200-standup" },
                "the recovered recording never reached the list the menu renders")

        // A folder that appears after the guard has been taken: neither a second `recover()` nor a
        // `refresh()` may touch it. `refresh()` is `onAppear`, and a menu opened during a recording must
        // not hand the live folder — whose marker reads `recording` — to a pass that would assemble it
        // on the fly.
        let second = try placeInterruptedMeeting(in: harness.root, named: "2026-07-15-1300-planning")
        api.recover()
        api.refresh()
        await waitOutARecoveryPass(observedPass: firstPass)

        #expect(try readSessionManifest(in: second).status == .recording,
                "a second `recover()` or a `refresh()` ran recovery again — the once-per-launch guard is gone")
        #expect(api.state.recoveryNotice == notice, "a second `recover()` rewrote the recovery notice")
        // `refresh()` does rescan the list, which is what it is for.
        #expect(api.state.recordings.contains { $0.directory.lastPathComponent == "2026-07-15-1300-planning" },
                "`refresh()` did not rescan the archive")

        api.dismissRecoveryNotice()
        #expect(api.state.recoveryNotice == nil, "the recovery notice could not be dismissed")
    }

    // MARK: - Title and settings

    /// The two editable fields are read *and written* through the façade, and both reach the state the
    /// UI renders. Asserted through `state`, not just the getter: a setter that mutated a field the
    /// mapping never reads would leave the migrated menu editing a value it could not see.
    @Test
    @MainActor
    @available(macOS 15.0, *)
    func theTitleIsEditableThroughTheFacadeAndReachesTheState() async throws {
        let harness = ControllerHarness(label: "api-title")
        defer { harness.tearDown() }
        let api = ControlAPI(controller: harness.controller, microphone: makeTestMicrophoneManager().2)
        defer { api.finish() }

        api.title = "Board review"
        #expect(api.title == "Board review")
        #expect(api.state.title == "Board review")

        // ⚠️ The documented quirk, frozen as a test rather than as prose: a title passed while the
        // controller is busy still lands — the guard makes the *start* a no-op, and the mutation
        // happened before it. Reproduced from the controller, not invented by the façade.
        api.start(title: "First")
        #expect(await waitUntilOnMain { OperationKind(api.state.operation) == .recording },
                "the recording never started")
        api.start(title: "Second")
        #expect(api.title == "Second", "a title passed while busy no longer lands — the quirk changed")
        #expect(OperationKind(api.state.operation) == .recording, "the busy guard let a second start through")

        await api.stopAndWait()
    }

    /// `saveSettings()` is not a bare forward: it **normalises** first. A segment length outside the
    /// allowed range is clamped, and the clamped value is what both the state and the store keep — so a
    /// client that writes nonsense through the façade cannot park it in the UI or on disk.
    @Test
    @MainActor
    @available(macOS 15.0, *)
    func savingSettingsNormalisesThemBeforeTheyReachTheStateOrTheStore() throws {
        let harness = ControllerHarness(label: "api-settings")
        defer { harness.tearDown() }
        let api = ControlAPI(controller: harness.controller, microphone: makeTestMicrophoneManager().2)
        defer { api.finish() }

        var settings = api.settings
        settings.segmentSeconds = RecordingSettings.maxSegmentSeconds + 600
        settings.deleteSegmentsAfterAssembly = false
        api.settings = settings

        // Assigned but not yet saved: the controller holds the raw value, exactly as the menu's binding
        // does while the user is still dragging the slider.
        #expect(api.state.settings.segmentSeconds == RecordingSettings.maxSegmentSeconds + 600)

        api.saveSettings()

        #expect(api.settings.segmentSeconds == RecordingSettings.maxSegmentSeconds,
                "`saveSettings()` forwarded without normalising")
        #expect(api.state.settings.segmentSeconds == RecordingSettings.maxSegmentSeconds)
        #expect(!api.state.settings.deleteSegmentsAfterAssembly, "an unrelated setting was lost in the save")
    }
}
