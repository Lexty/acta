import AVFoundation
import ActaKit
import ActaRuntime
import Foundation
import Testing

// A **successful, capture-backed recording**, in-process: no TCC prompt, no display, no audio
// device. Until the seams below it existed, this was the one thing the suite could not reach —
// `RecordingSession.start()` checked real permissions, created a real `SCStream` and waited on real
// buffers, so everything past a failed start was stuck at "manual test (skipped - not automatable)"
// while the pure logic around it was covered twice over.
//
// The protocols are not the deliverable; these tests are.

/// The wall-clock ceiling for a scenario that spends virtual seconds. The real code sleeps 2 s on
/// the startup probe alone, and the give-up path spends four of them — so a run anywhere near this
/// bound means the clock is not actually wired and the tests are waiting on real time.
private let clockWiredWallClockBound = 1.5

/// Segment length for these tests: the shortest `RecordingSettings` allows. Combined with buffers a
/// second long, a couple of batches cross a boundary — which is the point.
private let testSegmentSeconds = RecordingSettings.minSegmentSeconds

@available(macOS 15.0, *)
private func makeSettings(deleteSegments: Bool = false) -> RecordingSettings {
    RecordingSettings(archivePath: "", segmentSeconds: testSegmentSeconds,
                      deleteSegmentsAfterAssembly: deleteSegments)
}

@available(macOS 15.0, *)
private func makeDependencies(source: FakeCaptureSource,
                              permissions: FakePermissions,
                              clock: TestClock) -> RecordingDependencies {
    RecordingDependencies(makeSource: { source }, makePermissions: { permissions }, makeClock: { clock })
}

/// The session marker as it stands on disk.
private func readManifest(in directory: URL) throws -> SessionManifest {
    let data = try Data(contentsOf: directory.appendingPathComponent(SessionManifest.fileName))
    return try SessionManifest.decode(from: data)
}

/// The meeting folders sitting in an archive root — the subdirectories, and nothing else.
private func meetingFolders(in root: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.filter { name in
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path,
                                                    isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

/// The segment files of one track, in order.
private func segmentFiles(in directory: URL, track: String) -> [URL] {
    let trackDir = directory.appendingPathComponent(track)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: trackDir.path)) ?? []
    return SegmentLayout.orderedSegments(fromFileNames: names)
        .map { trackDir.appendingPathComponent($0.fileName) }
}

// `.serialized`: these tests drive real `AVAssetWriter`s and a real `ffmpeg`, and the suite asserts
// wall-clock bounds to prove the injected clock is wired. Run in parallel with each other they
// contend for the same cores, and the bound would then be measuring the machine's load rather than
// whether the code waited on real time.
@Suite(.serialized)
struct RecordingPipelineTests {
    // MARK: - The success path

    @Test
    @available(macOS 15.0, *)
    func aRecordingBackedByAFakeSourceCrossesASegmentBoundaryAndAssembles() async throws {
        let directory = makeTemporaryDirectory("pipeline-success")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FakeCaptureSource()
        let permissions = FakePermissions()
        let clock = TestClock()
        // Every wait the self-diagnosis takes is a wait during which, in production, audio would be
        // arriving. That is what makes the startup probe confirm the stream, so it is what the fake
        // does here.
        clock.onSleep { _ in source.emitBatch() }

        // A counted lock, not a real one — and not merely to observe it. Every test in this runner
        // shares one pid, and `DisplayWakeLockTests` asks `pmset` what *this pid* is holding. A real
        // assertion taken here is indistinguishable from the one it is checking for, so a recording
        // in this suite would fail that suite instead.
        let activity = CountingWakeLock()
        let session = RecordingSession(directory: directory, settings: makeSettings(),
                                       wakeLock: activity.makeWakeLock(),
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: permissions,
                                                                      clock: clock))

        let began = Date()
        try await session.start()
        let startSeconds = Date().timeIntervalSince(began)
        // Snapshotted the instant the start is confirmed, before the watchdog has had a chance to do
        // anything: "start() exactly once" is a claim about the clean start path.
        let startsAtConfirm = source.startCount
        let stopsAtConfirm = source.stopCount
        let result = await session.stop()

        #expect(startSeconds < clockWiredWallClockBound,
                "a confirmed start took \(startSeconds) s of real time — the injected clock is not wired")
        #expect(startsAtConfirm == 1, "a clean start brought the source up \(startsAtConfirm) times, not once")
        #expect(stopsAtConfirm == 0, "a clean start stopped the source before it ever recorded")
        // The source is asked nothing about permissions; it is asked to capture. The prompting is
        // `AudioRecorder`'s, and with both permissions already granted there is nothing to prompt for
        // — a dialog here would be one in the user's face on every single start.
        #expect(permissions.screenRequestCount == 0, "a granted permission was requested anyway")
        #expect(permissions.micRequestCount == 0, "a granted permission was requested anyway")

        for track in [SegmentLayout.systemDirName, SegmentLayout.micDirName] {
            let segments = segmentFiles(in: directory, track: track)
            // Both tracks accepted buffers: a live system track masking a dead microphone is half
            // the meeting, and it is the exact failure the per-track counters exist for. Two or more
            // segments, and that is what earns the fixture buffers their one-second timestamps — one
            // segment would prove only "a file exists", while rotation and finalisation (which is
            // what crash safety *is*) only happen once the media timeline crosses `segmentSeconds`.
            #expect(segments.count >= 2, "\(track): \(segments.count) segment(s) — no segment boundary was crossed")
            for segment in segments.dropLast() {
                let valid = await isRealAudioFile(segment)
                #expect(valid, "\(segment.lastPathComponent): a finalized segment is not playable audio")
            }
        }

        let assembled = try #require(result, "the assembly produced nothing — ffmpeg missing or the segments unusable")
        #expect(try #require(assembled.durationSeconds) > 0)
        for name in [SegmentLayout.systemTrackFileName, SegmentLayout.micTrackFileName] {
            let valid = await isRealAudioFile(directory.appendingPathComponent(name))
            #expect(valid, "\(name): the assembled track is not playable audio")
        }

        let manifest = try readManifest(in: directory)
        #expect(manifest.status == .done)
        #expect(manifest.segmentCount > 0, "session.json still claims nothing was recorded")
    }

    @Test
    @available(macOS 15.0, *)
    func aNonInterleavedSourceBufferStillReachesASegment() async throws {
        // `SCStreamConfiguration` asks for a sample rate and a channel count; it does not promise a
        // PCM layout. So "48 kHz stereo" is a realistic format, not a guaranteed one, and the layout
        // is where fake-only confidence is most likely to be misplaced: a non-interleaved buffer is a
        // differently shaped `AudioBufferList`, and the format propagation from the buffer through
        // `sourceFormatHint` into a WAV is the part that would quietly break.
        let directory = makeTemporaryDirectory("pipeline-noninterleaved")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FakeCaptureSource()
        source.setFormat(.stereo48kNonInterleaved)
        let permissions = FakePermissions()
        let clock = TestClock()
        clock.onSleep { _ in source.emitBatch() }

        let session = RecordingSession(directory: directory, settings: makeSettings(),
                                       wakeLock: CountingWakeLock().makeWakeLock(),
                                       dependencies: makeDependencies(source: source,
                                                                      permissions: permissions,
                                                                      clock: clock))
        try await session.start()
        _ = await session.stop()

        for track in [SegmentLayout.systemDirName, SegmentLayout.micDirName] {
            let segments = segmentFiles(in: directory, track: track)
            #expect(!segments.isEmpty, "\(track): a non-interleaved buffer never reached a segment")
            for segment in segments.dropLast() {
                let valid = await isRealAudioFile(segment)
                #expect(valid, "\(segment.lastPathComponent): a non-interleaved buffer produced an unplayable segment")
            }
        }
    }

    // MARK: - Failure paths

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
}

// MARK: - The controller's own job

@Suite
struct FailedStartCleanupThroughControllerTests {
    @Test
    @available(macOS 15.0, *)
    @MainActor
    func aStartRejectedForAMissingPermissionLeavesNoPhantomFolderBehind() async {
        // Through `RecordingController`, and not `RecordingSession`, because the cleanup is the
        // controller's. `RecordingSession.start()` writes `session.json` *before* it starts the
        // recorder, so a permission denial genuinely does leave a `status=recording` marker on disk —
        // and `Recovery` reads any such folder as an interrupted recording and would retry it,
        // failing, on every launch for the rest of the archive's life. What removes it is
        // `FailedStartCleanup.removeIfEmpty` on the controller's failure path. The session is not
        // "fixed" to avoid writing the marker: that ordering is deliberate (a kill -9 a millisecond
        // later must leave the folder recoverable), and changing it is a behaviour change.
        let root = makeTemporaryDirectory("controller-archive")
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = UserDefaults(suiteName: "acta-test-\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.save(RecordingSettings(archivePath: root.path, segmentSeconds: testSegmentSeconds))

        let source = FakeCaptureSource()
        let permissions = FakePermissions(screenGranted: false)
        let clock = TestClock()
        let controller = RecordingController(settingsStore: settingsStore) { directory, settings in
            RecordingSession(directory: directory, settings: settings,
                             wakeLock: CountingWakeLock().makeWakeLock(),
                             dependencies: RecordingDependencies(makeSource: { source },
                                                                 makePermissions: { permissions },
                                                                 makeClock: { clock }))
        }
        controller.title = "Phantom meeting"

        controller.start()
        await controller.stopAndWait()

        #expect(controller.phase == .error)
        #expect(controller.errorMessage == StartupFailure.noScreenRecordingPermission.userMessage)
        // Meeting folders specifically: the archive root also holds the generated `CLAUDE.md`, which
        // `MeetingStore` writes whenever it makes sure the root exists and which has nothing to do
        // with this start.
        let leftovers = meetingFolders(in: root)
        #expect(leftovers.isEmpty,
                "a start that never recorded left \(leftovers) behind — recovery would retry that folder forever")
    }
}

// MARK: - The shipped wiring

@Suite
struct RecordingDependenciesTests {
    @Test
    @available(macOS 15.0, *)
    func theLiveCompositionUsesTheRealImplementations() {
        // The seams are only worth having if the app still gets the real thing, and that claim is
        // exactly what a refactor breaks silently: swap a default to a fake and every test above goes
        // *greener*, while the shipped app records nothing.
        //
        // Asserted against the composition itself rather than by prying open a session's private
        // fields — those would prove a session holds something, not that this is what production
        // passes it.
        let dependencies = RecordingDependencies.live
        #expect(dependencies.makeSource() is SCKCaptureSource)
        #expect(dependencies.makePermissions() is SystemPermissions)
        #expect(dependencies.makeClock() is SystemClock)
    }

    @Test
    @available(macOS 15.0, *)
    func eachSessionGetsItsOwnCaptureSource() {
        // A source is stateful and belongs to exactly one recording. Handing the same instance to two
        // sessions would let a stopped recording's source deliver into a live one's writers.
        let first = RecordingDependencies.live.makeSource()
        let second = RecordingDependencies.live.makeSource()
        #expect(first !== second)
    }
}
