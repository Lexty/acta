import Testing
import Foundation
import ActaKit
import ActaRuntime

// The bounded retry of an assembly that keeps coming back `segmentsUnrepairable`.
//
// `RecoveryManager` takes an archive root, so this drives the real thing: real fixture segments, a
// real `session.json`, a real `info.md`, a real `ffmpeg`. The seam is the read-only segment — the
// one input that makes `SegmentRepair.apply` fail the way a read-only volume or a wrong permission
// would.
//
// The two outcomes under test are the ones that decide whether audio is ever seen again: retry while
// the cause might clear, and stop before the folder becomes a launch-time tax that never resolves.

/// The marker and metadata a crash leaves behind: `status=recording` and an `info.md` to patch.
private func writeInterruptedMarker(in directory: URL, title: String, segmentCount: Int) throws {
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let manifest = SessionManifest(status: .recording, startedAt: startedAt,
                                   segmentSeconds: 15, segmentCount: segmentCount)
    try manifest.encoded().write(to: directory.appendingPathComponent(SessionManifest.fileName))
    try MeetingInfo(title: title, date: startedAt, source: "Slack",
                    durationSeconds: 0, status: .recording)
        .rendered()
        .write(to: directory.appendingPathComponent(MeetingArchive.infoFileName),
               atomically: true, encoding: .utf8)
}

/// An archive root holding one interrupted meeting: `status=recording`, an `info.md` to patch, two
/// healthy system segments, and a mic segment holding real audio that the repair cannot write back.
private func withInterruptedMeeting(_ body: (URL, URL) throws -> Void) throws {
    try withRecordingDirectory { root in
        let directory = root.appendingPathComponent("2026-07-15-1200-standup", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try makeRecording(in: directory, systemSegments: 2, micSegments: nil)
        let micSegment = directory
            .appendingPathComponent(SegmentLayout.micDirName)
            .appendingPathComponent("0000.wav")
        try writeUnfinalizedWAV(to: micSegment, frames: 24_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: micSegment.path)

        try writeInterruptedMarker(in: directory, title: "Standup", segmentCount: 2)
        try body(root, directory)
    }
}

/// The same interrupted folder, failing at the other end of the assembly: the system segments are
/// ones `ffmpeg` will not splice under `-c copy`, while the mic track is perfectly whole.
private func withConcatFailingMeeting(_ body: (URL, URL) throws -> Void) throws {
    try withRecordingDirectory { root in
        let directory = root.appendingPathComponent("2026-07-15-1300-planning", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try makeRecording(in: directory, systemSegments: 0, micSegments: 2)
        try makeConcatFailingSystemTrack(in: directory)

        try writeInterruptedMarker(in: directory, title: "Planning", segmentCount: 2)
        try body(root, directory)
    }
}

private func readManifest(in directory: URL) throws -> SessionManifest {
    let data = try Data(contentsOf: directory.appendingPathComponent(SessionManifest.fileName))
    return try SessionManifest.decode(from: data)
}

private func readInfo(in directory: URL) -> String {
    (try? String(contentsOf: directory.appendingPathComponent(MeetingArchive.infoFileName),
                 encoding: .utf8)) ?? ""
}

/// `assemblyAttempts` is the retry bound, so it has to survive the round-trip to disk — a counter
/// that silently reset to 0 on every read would restore exactly the unbounded loop it exists to
/// stop. (Its *absence* from an older marker decoding to 0 is pinned in `RecoveryTests`.)
@Test
func sessionManifestRoundTripsTheAssemblyAttemptCounter() throws {
    let manifest = SessionManifest(status: .recording, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   segmentSeconds: 15, segmentCount: 4, assemblyAttempts: 2)

    let decoded = try SessionManifest.decode(from: manifest.encoded())

    #expect(decoded.assemblyAttempts == 2)
    #expect(decoded == manifest)
}

/// The first failures must leave the door open. The audio is in the segments and the repair might
/// succeed once whatever blocked it is gone, so the marker stays `recording` — that marker *is* the
/// retry request, and a terminal status here would mean no launch ever looks at the folder again.
@Test
func recoveryRetriesAFolderWhoseSegmentsCouldNotBeRepaired() throws {
    try withInterruptedMeeting { root, directory in
        RecoveryManager(archiveRoot: root).recoverInterruptedSessions()

        let manifest = try readManifest(in: directory)
        #expect(manifest.status == .recording)
        #expect(manifest.assemblyAttempts == 1)
        // Nothing is deleted while a retry is still owed: the segments are the only copy.
        #expect(exists(directory.appendingPathComponent(SegmentLayout.micDirName)))
        #expect(exists(directory.appendingPathComponent(SegmentLayout.systemDirName)))
        // And `info.md` must not claim the recording finished.
        #expect(readInfo(in: directory).contains("status: recording"))
    }
}

/// Attempts have to actually accumulate across launches. If each run reset the counter, the bound
/// would never be reached and the loop would be unbounded in practice.
@Test
func recoveryCountsAssemblyAttemptsAcrossLaunches() throws {
    try withInterruptedMeeting { root, directory in
        let manager = RecoveryManager(archiveRoot: root)
        manager.recoverInterruptedSessions()
        manager.recoverInterruptedSessions()

        let manifest = try readManifest(in: directory)
        #expect(manifest.assemblyAttempts == 2)
        #expect(manifest.status == .recording)
    }
}

/// The bound itself. A read-only segment is not a condition that clears, and without a stop the
/// folder would re-run a full `ffmpeg` concat on every launch — with every `start()` waiting on it —
/// while reading "not finished" forever with no way for the user to clear it.
///
/// Giving up keeps everything: the tracks that assembled, and the segments holding what did not.
@Test
func recoveryStopsRetryingAfterTheAttemptBoundAndKeepsTheSegments() throws {
    try withInterruptedMeeting { root, directory in
        let manager = RecoveryManager(archiveRoot: root)
        for _ in 0..<RecoveryManager.maxAssemblyAttempts {
            manager.recoverInterruptedSessions()
        }

        let manifest = try readManifest(in: directory)
        #expect(manifest.status == .recovered)
        #expect(manifest.assemblyAttempts == RecoveryManager.maxAssemblyAttempts)
        // The mic audio never made it into a file, so its segment stays its only copy.
        #expect(exists(directory.appendingPathComponent(SegmentLayout.micDirName)))
        // The system track did assemble, and the folder closes with it rather than with nothing.
        #expect(exists(directory.appendingPathComponent(SegmentLayout.systemTrackFileName)))

        // A terminal marker is the whole point: the next launch must walk past this folder instead
        // of paying for its concat again.
        manager.recoverInterruptedSessions()
        let afterExtraLaunch = try readManifest(in: directory)
        #expect(afterExtraLaunch.assemblyAttempts == RecoveryManager.maxAssemblyAttempts)
    }
}

/// A failed concat has to be bounded exactly like a failed repair, and this is the test that says so.
///
/// `-xerror` is what makes this reachable: before it, `ffmpeg` swallowed a failed concat (exit 0, a
/// short file) and this path was effectively dead. Left in the generic `catch`, such a folder spends
/// no attempt and keeps `status=recording` forever — re-running a full concat on every launch, with
/// every `start()` waiting on it, and reading "not finished" with no way for the user to clear it.
@Test
func recoveryStopsRetryingAFolderWhoseTrackCannotBeConcatenated() throws {
    try withConcatFailingMeeting { root, directory in
        let manager = RecoveryManager(archiveRoot: root)

        // The attempts have to be *spent* — a failure that never increments the counter is the
        // unbounded loop wearing a bound.
        manager.recoverInterruptedSessions()
        #expect(try readManifest(in: directory).assemblyAttempts == 1)
        #expect(try readManifest(in: directory).status == .recording)

        for _ in 1..<RecoveryManager.maxAssemblyAttempts {
            manager.recoverInterruptedSessions()
        }

        let manifest = try readManifest(in: directory)
        #expect(manifest.status == .recovered)
        #expect(manifest.assemblyAttempts == RecoveryManager.maxAssemblyAttempts)
        // The system audio reached no file, so its segments stay its only copy.
        #expect(exists(directory.appendingPathComponent(SegmentLayout.systemDirName)))
        #expect(!exists(directory.appendingPathComponent(SegmentLayout.systemTrackFileName)))

        // The next launch must walk past the folder rather than pay for the concat again.
        manager.recoverInterruptedSessions()
        #expect(try readManifest(in: directory).assemblyAttempts == RecoveryManager.maxAssemblyAttempts)
    }
}

/// A track that fails to concat must not take its healthy sibling down with it. `system` and `mic`
/// fail for reasons of their own, and a mic track skipped because *system* threw would be audio lost
/// to a deterministic cause no retry can clear — while the folder closes over it.
@Test
func recoveryAssemblesTheHealthyTrackWhenTheOtherCannotBeConcatenated() throws {
    try withConcatFailingMeeting { root, directory in
        let manager = RecoveryManager(archiveRoot: root)
        for _ in 0..<RecoveryManager.maxAssemblyAttempts {
            manager.recoverInterruptedSessions()
        }

        #expect(exists(directory.appendingPathComponent(SegmentLayout.micTrackFileName)))
    }
}

/// A give-up that assembled a track reports it as recovered — the archive gained audio the user can
/// play, and staying silent would leave them to notice by chance.
@Test
func recoveryReportsAClosedFolderAsRecoveredWhenATrackActuallyAssembled() throws {
    try withConcatFailingMeeting { root, directory in
        let manager = RecoveryManager(archiveRoot: root)
        for _ in 1..<RecoveryManager.maxAssemblyAttempts {
            manager.recoverInterruptedSessions()
        }
        // The closing launch: `mic.wav` assembles, so this folder is worth telling the user about.
        // Compared by name: the scan walks the archive root, and `/var` resolving to `/private/var`
        // makes the two URLs unequal while naming the same folder.
        let outcome = manager.recoverInterruptedSessions()
        #expect(outcome.recovered.map(\.lastPathComponent) == [directory.lastPathComponent])
        #expect(outcome.unassembled.isEmpty)

        // Terminal by now: the next launch must walk past it rather than report it again.
        #expect(manager.recoverInterruptedSessions().isEmpty)
    }
}

/// The worst case, and the one that must not be silent: every track failed, so the meeting exists
/// only as segments and no launch will ever retry it. `closeEmpty`'s shape (terminal, zero duration,
/// no wav) with the opposite meaning — so it is reported separately, and `info.md` says in the file
/// itself where the audio actually is.
@Test
func recoveryReportsAFolderWhoseAudioNeverReachedATrackAndSaysSoInInfo() throws {
    try withRecordingDirectory { root in
        let directory = root.appendingPathComponent("2026-07-15-1400-retro", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Both tracks fail their concat, so nothing lands: `system` holds segments `-c copy` cannot
        // splice and `mic` holds none at all.
        try makeRecording(in: directory, systemSegments: 0, micSegments: nil)
        try makeConcatFailingSystemTrack(in: directory)
        try writeInterruptedMarker(in: directory, title: "Retro", segmentCount: 2)

        let manager = RecoveryManager(archiveRoot: root)
        for _ in 1..<RecoveryManager.maxAssemblyAttempts {
            manager.recoverInterruptedSessions()
        }
        let outcome = manager.recoverInterruptedSessions() // the closing launch

        // Not reported as recovered: there is no track to play.
        #expect(outcome.recovered.isEmpty)
        #expect(outcome.unassembled.map(\.lastPathComponent) == [directory.lastPathComponent])
        // The segments are the only copy and must survive the give-up.
        #expect(exists(directory.appendingPathComponent(SegmentLayout.systemDirName)))
        #expect(!exists(directory.appendingPathComponent(SegmentLayout.systemTrackFileName)))
        // And the folder says what happened without the app and without `log show`.
        #expect(readInfo(in: directory).contains("could not be assembled"))
    }
}

/// The crash-time segment count is the last true one anybody wrote, and a terminal marker must not
/// seal a number in the wrong unit over it: `tracks.count` would close a 2-segment meeting as
/// `segment_count: 0`, and a 240-segment one as `2`.
@Test
func recoveryKeepsTheSegmentCountWhenItGivesUp() throws {
    try withConcatFailingMeeting { root, directory in
        let manager = RecoveryManager(archiveRoot: root)
        for _ in 0..<RecoveryManager.maxAssemblyAttempts {
            manager.recoverInterruptedSessions()
        }

        let manifest = try readManifest(in: directory)
        #expect(manifest.status == .recovered)
        #expect(manifest.segmentCount == 2) // as written at crash time, not the number of tracks
    }
}

/// `info.md` is archival metadata read without the app (SPEC §6), so on give-up it has to stop
/// saying `recording` and carry the length of the audio that actually exists — measured off the
/// assembled track, not the clock and not the segment count.
@Test
func recoveryWritesTheMeasuredDurationIntoInfoWhenItGivesUp() throws {
    try withInterruptedMeeting { root, directory in
        let manager = RecoveryManager(archiveRoot: root)
        for _ in 0..<RecoveryManager.maxAssemblyAttempts {
            manager.recoverInterruptedSessions()
        }

        let info = readInfo(in: directory)
        #expect(info.contains("status: recovered"))
        // Two 480-frame segments at 48 kHz is 0.02 s of audio — under a second, and the duration
        // rounds to zero. What matters is that it came from the file: a clock or `segmentCount ×
        // segmentSeconds` estimate would have written 30 s over 0.02 s of real audio.
        let systemWAV = directory.appendingPathComponent(SegmentLayout.systemTrackFileName)
        let measured = try #require(durationOfWAV(at: systemWAV))
        #expect(measured < 1.0)
        #expect(info.contains("duration: \"\(MeetingInfo.formatDuration(seconds: 0))\""))
    }
}
