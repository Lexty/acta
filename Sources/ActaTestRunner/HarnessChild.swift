import ActaKit
import ActaRuntime
import Foundation

/// The harness modes this binary runs when `main.swift` sees a harness flag: record into an archive
/// and hold still to be killed, or recover an archive as a fresh process.
///
/// Both drive the shipped `RecordingController` — the child does not fabricate segments, it records
/// them through `start()`, and the recoverer does not assemble anything itself, it calls
/// `onLaunch()`. A harness that hand-built the state it then recovers would prove only that its own
/// fixtures round-trip.
@available(macOS 15.0, *)
@MainActor
enum HarnessChild {
    /// Run a mode and exit. Never returns: a harness process must not fall through into the test
    /// runner and spawn children of its own.
    static func run(_ mode: Harness.Mode) async -> Never {
        switch mode {
        case .record(let root): await record(root: root)
        case .recover(let root): await recover(root: root)
        }
    }

    // MARK: - Record mode

    /// Record a real meeting into `<root>/archive`, publish readiness, then wait to be stopped or
    /// killed.
    private static func record(root: URL) async -> Never {
        let archive = Harness.archiveRoot(in: root)
        try? FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

        let source = FakeCaptureSource()
        source.encodePositions()
        let clock = TestClock()
        // Only for the startup probe. `SelfCheck` measures the counters across a window it sleeps
        // through, so with a clock that returns instantly the audio has to arrive from the sleep
        // itself or the start is (correctly) rejected as mute. It is unwired the moment the start is
        // confirmed — see `clock.freeze()` below.
        clock.onSleep { _ in source.emitBatch() }

        let controller = makeController(archiveRoot: archive, source: source, clock: clock)
        controller.onLaunch()
        controller.start()
        guard await waitUntilOnMain(timeout: Harness.readinessTimeoutSeconds, { !controller.isStarting }),
              controller.phase == .recording else {
            finish(.startFailed, "start() did not reach .recording: \(controller.errorMessage)")
        }

        // Time stops here, and with it every source of audio the child does not itself ask for. From
        // this line on the watchdog cannot stall (it compares a frozen `now` against the last
        // progress), cannot restart the stream, and cannot emit — so the only thing putting frames
        // into the archive is the loop below, and the count it ends on is the whole truth.
        clock.freeze()

        guard let meeting = soleMeeting(in: archive) else {
            finish(.startFailed, "the archive does not hold exactly one meeting folder")
        }
        guard await driveUntilCrashWorthy(source: source, meeting: meeting) else {
            finish(.notReady, "the archive never reached a crash-worthy state: \(meeting.lastPathComponent)")
        }

        // Freeze, drain, count, publish — in that order, and the order is the whole point. Freezing
        // first is what makes the count an upper bound rather than a number that was true a moment
        // ago; draining is what makes every counted frame one the writer has already been handed.
        source.freezeEmission()
        source.drain()
        let frames = source.emittedFrames
        publish(Harness.Readiness(pid: ProcessInfo.processInfo.processIdentifier,
                                  meeting: meeting.lastPathComponent,
                                  systemFrames: frames[.system] ?? 0,
                                  micFrames: frames[.mic] ?? 0),
                in: root)

        await awaitStopOrKill(root: root, controller: controller)
    }

    /// Wait for the parent: either a `SIGKILL`, which never returns here at all, or a stop request,
    /// which is served by the same `stopAndWait()` the Quit menu item calls.
    private static func awaitStopOrKill(root: URL, controller: RecordingController) async -> Never {
        let stop = Harness.stopFile(in: root)
        let deadline = Date().addingTimeInterval(Harness.childLifetimeSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: stop.path) {
                await controller.stopAndWait()
                guard controller.phase == .idle else {
                    finish(.startFailed, "the stop did not save the recording: \(controller.errorMessage)")
                }
                finish(.ok, "stopped cleanly")
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        finish(.abandoned, "no stop request and no signal within \(Harness.childLifetimeSeconds)s")
    }

    // MARK: - Readiness

    /// Emit audio until the archive holds what a crash needs to be worth staging, or give up.
    ///
    /// Emission is explicit — a loop the child drives — rather than a side effect of the clock,
    /// because the clock's ticks belong to the watchdog and the child cannot say how many of them
    /// there will be. A count that is not the child's to predict is not an upper bound.
    private static func driveUntilCrashWorthy(source: FakeCaptureSource, meeting: URL) async -> Bool {
        let deadline = Date().addingTimeInterval(Harness.readinessTimeoutSeconds)
        while Date() < deadline {
            if isCrashWorthy(meeting: meeting) { return true }
            source.emitBatch()
            // The closed segment becomes valid in `AVAssetWriter`'s own completion handler, not when
            // the rotation starts — so the state is waited for, not assumed to follow the batch.
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return isCrashWorthy(meeting: meeting)
    }

    /// Whether killing the process now would leave a recording worth recovering, **as the production
    /// recovery scan sees it**.
    ///
    /// Not a filename poll, and not the controller's state. `RecordingController` exposes no
    /// per-track progress, and `session.json`'s `segmentCount` is `max(system, mic)`, so it cannot
    /// tell one segment per track from two on one track and none on the other. The predicate that
    /// matters is the one recovery will itself apply, so it is applied here — through the same
    /// public `Recovery`/`SegmentLayout` planning, read-only.
    ///
    /// Read-only is not a detail: `SegmentRepair.apply` truncates and rewrites the open segment, and
    /// running it against a file this process is still writing would corrupt the very thing the
    /// crash is meant to leave behind. Readiness is an observation, never a repair.
    nonisolated static func isCrashWorthy(meeting: URL) -> Bool {
        guard let manifest = try? readSessionManifest(in: meeting),
              manifest.status == .recording else { return false }
        return Track.allCases.allSatisfy { hasClosedAndOpenSegments(in: meeting, track: $0) }
    }

    /// Whether this track has both halves of the crash: a finalised segment recovery will take as it
    /// stands, and an open one behind it holding audio only a repair can reach.
    nonisolated private static func hasClosedAndOpenSegments(in meeting: URL, track: Track) -> Bool {
        let plan = recoveryPlan(in: trackDirectory(in: meeting, track: track))
        // The open segment is the last one: `AVAssetWriter` sets the `data` size in `finishWriting`,
        // so a segment still being written cannot be `.include` — and its being `.repair` at all
        // means `WAV.headerRepair` found a whole frame of body in it, which is what "demonstrably
        // usable audio" has to mean here.
        guard let open = plan.last, case .repair = open.action else { return false }
        return plan.dropLast().contains { $0.action == .include }
    }

    /// The production plan for one track's directory, built from a read of that directory.
    nonisolated private static func recoveryPlan(in trackDir: URL) -> [Recovery.PlannedSegment] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: trackDir.path)) ?? []
        var sizes: [String: Int] = [:]
        var headers: [String: Data] = [:]
        for name in names {
            let url = trackDir.appendingPathComponent(name)
            sizes[name] = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
            headers[name] = headerPrefix(of: url)
        }
        return Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: headers)
    }

    nonisolated private static func headerPrefix(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: Recovery.headerProbeBytes)) ?? Data()
    }

    /// One track's segment directory inside a meeting folder.
    nonisolated static func trackDirectory(in meeting: URL, track: Track) -> URL {
        let name = track == .system ? SegmentLayout.systemDirName : SegmentLayout.micDirName
        return meeting.appendingPathComponent(name, isDirectory: true)
    }

    /// Publish readiness by an atomic rename, so its appearance at the final name is the signal and
    /// a partial read is impossible.
    private static func publish(_ readiness: Harness.Readiness, in root: URL) {
        let staging = Harness.readinessStagingFile(in: root)
        do {
            try JSONEncoder().encode(readiness).write(to: staging, options: .atomic)
            try FileManager.default.moveItem(at: staging, to: Harness.readinessFile(in: root))
        } catch {
            finish(.notReady, "could not publish readiness: \(error.localizedDescription)")
        }
    }

    // MARK: - Recover mode

    /// Recover `<root>/archive` as a fresh process and report the outcome as an exit code.
    private static func recover(root: URL) async -> Never {
        let archive = Harness.archiveRoot(in: root)
        // A source that will never be asked for anything: recover mode never calls `start()`, and
        // wiring the live factory would put real ScreenCaptureKit behind an unreachable branch.
        let controller = makeController(archiveRoot: archive, source: FakeCaptureSource(),
                                        clock: TestClock())
        // `onLaunch()` also asks for notification authorization. It is not a prompt here and cannot
        // block: `Notifier` no-ops unless `Bundle.main.bundleIdentifier` exists, and this is a bare
        // executable, not an `.app`.
        controller.onLaunch()

        switch await withTimeout(seconds: Harness.recoveryTimeoutSeconds,
                                 operation: { await controller.awaitRecovery() }) {
        case .timedOut:
            finish(.recoveryTimedOut, "recovery did not finish within \(Harness.recoveryTimeoutSeconds)s")
        case .value(nil):
            finish(.recoveryDidNotRun, "onLaunch() started no recovery pass")
        case .value(.some(let outcome)):
            switch outcome {
            // Both are success, and `nothingToRecover` has to be: a cleanly stopped archive holds no
            // interrupted marker, so a pass over it correctly does nothing — which is exactly what
            // the non-crash plumbing test asserts.
            case .nothingToRecover, .recovered:
                finish(.ok, "recovery: \(outcome)")
            case .incomplete:
                finish(.recoveryIncomplete, "recovery left audio outside a track: \(outcome)")
            }
        }
    }

    // MARK: - Shared

    /// Undo whatever this process left outside its working directory. Set once the controller is
    /// built; a `defer` cannot do this job, because every exit here goes through `exit()`, which
    /// unwinds nothing.
    private static var cleanup: (@MainActor () -> Void)?

    /// A `RecordingController` in a harness process: the same seams the in-process scenarios inject,
    /// and an isolated defaults suite, so the developer's own app is never pointed at a temp
    /// archive.
    ///
    /// Not `ControllerHarness`: that one makes a temp root of its own and wires the clock to the
    /// source for the whole run, and those are the two decisions a harness child has to make
    /// differently — the root comes from the parent, and emission stops at readiness.
    private static func makeController(archiveRoot: URL, source: FakeCaptureSource,
                                       clock: TestClock) -> RecordingController {
        let suiteName = "acta-harness-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        cleanup = { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.save(RecordingSettings(archivePath: archiveRoot.path,
                                             segmentSeconds: testSegmentSeconds,
                                             deleteSegmentsAfterAssembly: false))
        let permissions = FakePermissions()
        return RecordingController(settingsStore: settingsStore) { directory, settings in
            RecordingSession(directory: directory, settings: settings,
                             dependencies: makeDependencies(source: source,
                                                            permissions: permissions,
                                                            clock: clock))
        }
    }

    /// Say what happened, on stderr, clean up, and go. The message is what turns a bare exit code in
    /// a failing test into something diagnosable.
    ///
    /// The crash path reaches none of this, by construction — a `SIGKILL`ed child leaves its
    /// defaults suite behind under a name nothing ever reads again. That is the price of the signal
    /// being real.
    private static func finish(_ code: Harness.Exit, _ reason: String) -> Never {
        FileHandle.standardError.write(Data("harness: \(reason)\n".utf8))
        cleanup?()
        exit(code.rawValue)
    }

    /// The meeting folder in the archive, if there is exactly one.
    private static func soleMeeting(in archive: URL) -> URL? {
        let folders = meetingFolders(in: archive)
        guard folders.count == 1 else { return nil }
        return archive.appendingPathComponent(folders[0], isDirectory: true)
    }

    /// The result of a bounded wait — an explicit "did not finish" rather than a `nil` that would
    /// nest inside the optional the operation itself returns.
    private enum Timed<T: Sendable>: Sendable {
        case value(T)
        case timedOut
    }

    /// Run `operation`, giving up after `seconds`.
    private static func withTimeout<T: Sendable>(
        seconds: Double, operation: @escaping @Sendable () async -> T
    ) async -> Timed<T> {
        await withTaskGroup(of: Timed<T>.self) { group in
            group.addTask { .value(await operation()) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}
