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
//
// The success path lives here; the failure paths — denied permissions, a source that never delivers,
// the watchdog — are in `RecordingPipelineFailureTests.swift`. Their shared fixtures are in
// `PipelineTestSupport.swift`.

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

        try await session.start()
        // Snapshotted the instant the start is confirmed, before the watchdog has had a chance to do
        // anything: "start() exactly once" is a claim about the clean start path.
        let startsAtConfirm = source.startCount
        let stopsAtConfirm = source.stopCount
        let sleepsAtConfirm = clock.sleepCount
        let result = await session.stop()

        // The injected clock, asserted directly rather than through wall-clock time. The startup probe
        // waits on `clock.sleep`, so a confirmed start leaves at least one wait on it; a clock that was
        // not wired would sleep on real time instead and leave this at zero. Wall-clock timing cannot
        // decide this — under parallel load the real `AVAssetWriter` setup alone can outlast any bound
        // short of the 2 s real probe, which is exactly the flake this replaces.
        #expect(sleepsAtConfirm >= 1,
                "start confirmed with \(sleepsAtConfirm) injected-clock waits; 0 means the probe slept on real time")
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
            // Every segment, the last one included: `stop()` has returned, and `SegmentWriter.finish()`
            // waits on its pending writes, so there is no segment still open to excuse.
            for segment in segments {
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

        let manifest = try readSessionManifest(in: directory)
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
            // At least one segment, and *every* one of them playable. `dropLast()` here would have
            // made the single-segment case assert nothing at all — which is precisely the case a
            // broken format hint produces: one unplayable stub.
            #expect(!segments.isEmpty, "\(track): a non-interleaved buffer never reached a segment")
            for segment in segments {
                let valid = await isRealAudioFile(segment)
                #expect(valid, "\(segment.lastPathComponent): a non-interleaved buffer produced an unplayable segment")
            }
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

        let suiteName = "acta-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
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

    @Test
    @MainActor
    @available(macOS 15.0, *)
    func theLiveSessionFactoryBuildsARealSessionForTheFolderItIsGiven() {
        // The other half of the same claim, one level up: `RecordingDependencies.live` is only what
        // the app records with if the controller actually reaches for it. Swap the factory default to
        // a fake and every controller test goes greener while the shipped app records nothing.
        //
        // The directory is what is asserted because it is the one thing a session exposes, and it is
        // also the part that matters: a factory that ignored it would record every meeting into the
        // same folder.
        let directory = makeTemporaryDirectory("live-session-factory")
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = RecordingController.liveSessionFactory(directory, .default)
        #expect(session.directory == directory)
    }
}
