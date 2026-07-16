import ActaKit
import ActaRuntime
import Foundation
import Testing

/// The payoff: a real recording, a real `SIGKILL`, and a **fresh process** that recovers it — checked
/// frame by frame against the encoding, not merely "it decodes".
///
/// This is the one mandatory property that could never be tested in-process. Throwing, cancelling a
/// task and dropping an object all run cleanup; `SIGKILL` runs none, which is the entire difference
/// between a tidy shutdown and the crash recovery exists for. So the child is a real subprocess, the
/// signal is real, the recovery happens in a process that shares nothing with it, and every assertion
/// here reads the durable filesystem state — the only thing that outlives the child.
///
/// It is **approximate** E2E, and the boundary is worth stating: nothing here proves ScreenCaptureKit
/// captures anything, that TCC prompts appear, or that a microphone was ever opened. It proves the
/// crash-safety machinery — segmentation → `SIGKILL` → fresh-process recovery → header repair →
/// assembly — end to end, automatically.
///
/// Nested in `HarnessTests` for the same reason `Plumbing` is: the parent carries `.serialized`, and
/// only a shared parent can keep these children from racing that suite's — see the note there.
extension HarnessTests {
    @Suite
    struct Crash {
        /// What one crash run may take, end to end. A bound on a hang rather than an expectation — a
        /// cold `AVAssetWriter`, real finalisation and a real `ffmpeg` concat on a loaded machine are
        /// not quick — but asserted, because a harness whose failure mode is "never returns" is not a
        /// test.
        ///
        /// **Derived from the waits it bounds, never restated as a number.** A run that spends every
        /// second the harness itself allows — the parent's readiness wait, then recovery's — is slow,
        /// not broken; a budget under that sum would fail a load-delayed success and point the message
        /// at the harness instead of at the machine. The margin covers the two spawns and the kill.
        private static let wallClockBudgetSeconds =
            Harness.readinessWaitSeconds + Harness.recoveryTimeoutSeconds + 30.0

        @Test("A SIGKILLed recording is recovered by a fresh process, frame for frame")
        @available(macOS 15.0, *)
        func aKilledRecordingIsRecoveredFrameForFrame() async throws {
            let started = Date()
            let run = try await CrashRun.stage(label: "crash", fault: nil)
            defer { run.tearDown() }

            // The marker the recovery pass leaves: `.recovered`, not `.done`. A crashed folder that came
            // back is not the same thing as one that was stopped, and the archive says so.
            #expect(try readSessionManifest(in: run.meeting).status == .recovered)
            #expect(await bothTracksAssembled(in: run.meeting))

            for track in Track.allCases {
                switch try run.verifyAssembled(track) {
                case .ok(let frames):
                    // Strictly greater, and that is the assertion this test exists for. `>=` would be
                    // satisfied by a recovery that threw the unfinalised segment away and assembled the
                    // closed ones — which is not recovery, it is the data loss recovery prevents.
                    // Readiness guarantees the open segment was `.repair`, i.e. that `WAV.headerRepair`
                    // found a whole frame of body in it, and emission was frozen before the kill, so a
                    // repaired tail *must* carry the track past its closed prefix.
                    #expect(frames > run.closedFrames(track),
                            """
                            \(track) recovered \(frames) frames — the unfinalised tail past \
                            \(run.closedFrames(track)) was lost, not repaired
                            """)
                    #expect(frames <= run.readiness.frames(track))
                case let other:
                    Issue.record("\(track) did not survive the crash intact: \(other)")
                }
            }

            let elapsed = Date().timeIntervalSince(started)
            #expect(elapsed < Self.wallClockBudgetSeconds,
                    "the crash run took \(Int(elapsed))s, over the \(Int(Self.wallClockBudgetSeconds))s budget")
        }

        /// The negative control, and it is permanent for a reason: every assertion above is only worth
        /// what the oracle's ability to fail is worth. An oracle that always says `.ok` would make the
        /// crash test green forever, including on the day recovery starts losing audio.
        ///
        /// So the same harness runs against a child that really does lose audio, and the oracle must name
        /// **that** loss — the exact frame and the exact width. Not "some failure": a timeout, an
        /// `ffmpeg` error or a dead child would all be failures too, and none of them would show the
        /// oracle working.
        @Test("The oracle names a dropped frame in a surviving segment, in the harness")
        @available(macOS 15.0, *)
        func theOracleCatchesAudioLostInASurvivingSegment() async throws {
            let started = Date()
            let run = try await CrashRun.stage(label: "dropped", fault: CrashRun.fault)
            defer { run.tearDown() }

            // The run is otherwise a good one: the fault is missing audio, not a broken recording, so
            // everything around the hole must still work. Without this the test could pass on a child
            // that produced nothing at all.
            #expect(try readSessionManifest(in: run.meeting).status == .recovered)
            #expect(await bothTracksAssembled(in: run.meeting))

            for track in Track.allCases {
                let result = try run.verifyAssembled(track)
                #expect(result == .discontinuity(frame: CrashRun.faultFrame, skipped: CrashRun.fault.frames),
                        "the oracle did not name the hole in \(track): \(result)")
            }

            // The same bound its positive twin carries, for the same reason: the harness suites are
            // serialized, so a wedge here stalls the run rather than failing it.
            let elapsed = Date().timeIntervalSince(started)
            #expect(elapsed < Self.wallClockBudgetSeconds,
                    "the negative control took \(Int(elapsed))s, over the \(Int(Self.wallClockBudgetSeconds))s budget")
        }
    }
}

/// One staged crash: spawn a child, let it record until the archive is worth killing, kill it, prove
/// it died of the signal, and recover it in a fresh process.
///
/// A type rather than a helper function because the two tests need the same eight steps in the same
/// order and differ only in what they then ask the oracle. Every step that can invalidate the run —
/// a child that exited on its own, a kill that raced the recording, a recovery that failed — fails
/// here, so the tests above are left saying only what they are about.
@available(macOS 15.0, *)
struct CrashRun {
    let child: HarnessProcess
    let readiness: Harness.Readiness
    let meeting: URL
    /// Per track, the frames the writer had already finalised when the signal landed — measured
    /// before recovery ran.
    private let closed: [Track: Int]

    /// The negative control's fault: a hole one second into the track.
    ///
    /// Both halves of the position are load-bearing. **One second in** (buffer index 1) is inside the
    /// first segment, which readiness guarantees is closed and valid — so the hole is in the part of
    /// the recording the crash was never going to take, and a failure here cannot be confused with
    /// the truncated tail. **Buffer 1, not buffer 0**, because a hole at frame zero is not a hole; it
    /// is a track that starts late, and the oracle would rightly say so about a healthy pipeline too.
    ///
    /// 4096 frames because the encoding wraps at 65536: a hole that size is unambiguously a loss,
    /// whereas one of 48000 (a whole buffer) is arithmetically indistinguishable from a 17536-frame
    /// repetition. See `Harness.Fault`.
    static let fault = Harness.Fault(frames: 4096, bufferIndex: 1)!
    /// Where that hole lands in the output — derived from the source's own buffer size, because the
    /// fault is placed by buffer index and this is the frame that index means.
    static let faultFrame = fault.bufferIndex * Int(FakeCaptureSource.framesPerBuffer)

    /// Run the whole thing, or fail trying.
    static func stage(label: String, fault: Harness.Fault?) async throws -> CrashRun {
        let child = try HarnessProcess(mode: .record(root: makeHarnessRoot(label), fault: fault))
        let readiness = await child.waitForReadiness()
        guard let readiness else {
            child.tearDown()
            throw HarnessRunError.neverReady(child.diagnostics)
        }

        // Alive *now*, before the signal: a child that has already exited cannot be crashed, and
        // signalling its pid would be signalling whatever inherited it.
        guard child.isRunning else {
            child.tearDown()
            throw HarnessRunError.diedBeforeTheKill(child.diagnostics)
        }
        // The pid the child published, not the one this side spawned — the child is the thing that
        // knows which process wrote the archive. Fatal to the run rather than a bare `#expect`: the
        // kill below is aimed at this number, and signalling a pid the child never claimed is
        // signalling an unrelated process on the developer's machine.
        guard readiness.pid == child.processIdentifier else {
            child.tearDown()
            throw HarnessRunError.pidDisagreed(published: readiness.pid, spawned: child.processIdentifier)
        }
        _ = Foundation.kill(readiness.pid, SIGKILL)

        // The assertion the whole scenario rests on. A child that exited *normally* means the kill
        // arrived after the recording was already over — the run would then be proving that a clean
        // stop recovers, which is a different claim and one the plumbing test already makes.
        let termination = await child.waitForExit()
        guard termination.signalled(by: SIGKILL) else {
            child.tearDown()
            throw HarnessRunError.notKilled(termination, child.diagnostics)
        }

        let meeting = Harness.archiveRoot(in: child.root)
            .appendingPathComponent(readiness.meeting, isDirectory: true)
        // Measured here, and it has to be here: recovery finalises the repaired tail, after which
        // every segment looks closed and this number would silently become the whole file — a lower
        // bound equal to the answer bounds nothing.
        let closed = Dictionary(uniqueKeysWithValues: Track.allCases.map {
            ($0, closedSegmentFrames(in: meeting, track: $0))
        })
        // The prefix has to be a real number, and this is what says so. It is the sole lower bound
        // both tests rest on: at zero, `frames > closedFrames` weakens to "at least one frame came
        // back" and `low...high` to "any length at all" — a harness that still passes while proving
        // almost nothing. Readiness already guarantees a finalised segment per track, so a zero here
        // means the measurement broke (a header format change, a moved directory), not that the run
        // was unlucky — and a broken oracle must fail loudly rather than quietly rubber-stamp.
        for (track, frames) in closed where frames <= 0 {
            child.tearDown()
            throw HarnessRunError.closedPrefixEmpty(track: track)
        }

        // Recovery, in a process that shares nothing with the one that died — no in-memory state
        // survived it, which is exactly the point. Required to succeed before anything is inspected:
        // an assertion about an archive whose recovery failed says nothing about recovery.
        // Spawned inside a `do`, not with a bare `try`: every other exit from this function tears the
        // child down first, and a spawn that throws must not be the one that walks out leaving a
        // staged archive behind.
        let recoverer: HarnessProcess
        do {
            recoverer = try HarnessProcess(mode: .recover(root: child.root))
        } catch {
            child.tearDown()
            throw error
        }
        let recovery = await recoverer.waitForExit()
        guard recovery.exited(.ok) else {
            child.tearDown()
            throw HarnessRunError.recoveryFailed(recoverer.diagnostics)
        }

        return CrashRun(child: child, readiness: readiness, meeting: meeting, closed: closed)
    }

    /// The oracle's verdict on one assembled track, over the length the crash allows.
    ///
    /// **Length is bounded, not exact, and it cannot be otherwise.** The signal lands wherever it
    /// lands: the closed segments are a guaranteed prefix, the emitted-frame count published at
    /// readiness is a ceiling nothing could have been produced past, and the repaired open segment
    /// contributes a whole-frame prefix of whatever was in flight. Demanding an exact count would be
    /// demanding that a crash be scheduled.
    func verifyAssembled(_ track: Track) throws -> PositionEncodedAudio.Verification {
        let name = track == .system ? SegmentLayout.systemTrackFileName : SegmentLayout.micTrackFileName
        let wav = try Data(contentsOf: meeting.appendingPathComponent(name))
        let low = closedFrames(track), high = readiness.frames(track)
        // A finalised prefix longer than everything ever emitted is impossible, and the check is here
        // because `low...high` would otherwise *trap* on it — killing the whole suite where the
        // harness should be reporting a failed run.
        guard low <= high else { throw HarnessRunError.boundsInverted(track: track, closed: low, emitted: high) }
        return PositionEncodedAudio.verify(wav: wav, track: track, frames: low...high)
    }

    func closedFrames(_ track: Track) -> Int { closed[track] ?? 0 }

    func tearDown() { child.tearDown() }

    enum HarnessRunError: Error {
        case neverReady(String)
        case diedBeforeTheKill(String)
        case pidDisagreed(published: Int32, spawned: Int32)
        case notKilled(HarnessProcess.Termination, String)
        case recoveryFailed(String)
        case boundsInverted(track: Track, closed: Int, emitted: Int)
        case closedPrefixEmpty(track: Track)
    }
}

/// The frames of `track` the writer had already finalised — the crash's guaranteed prefix.
///
/// A segment counts only once its header declares its own size, which `AVAssetWriter` writes in
/// `finishWriting`: a segment still open declares zero, and the scan stops at the first one, because
/// a prefix with a hole in it is not a prefix.
@available(macOS 15.0, *)
func closedSegmentFrames(in meeting: URL, track: Track) -> Int {
    let dirName = track == .system ? SegmentLayout.systemDirName : SegmentLayout.micDirName
    var frames = 0
    for url in segmentFiles(in: meeting, track: dirName) {
        guard let data = try? Data(contentsOf: url), let layout = WAV.layout(data),
              layout.declaredDataSize > 0, layout.format.blockAlign > 0 else { break }
        frames += layout.declaredDataSize / layout.format.blockAlign
    }
    return frames
}
