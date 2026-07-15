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

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = SessionManifest(status: .recording, startedAt: startedAt,
                                       segmentSeconds: 15, segmentCount: 2)
        try manifest.encoded().write(to: directory.appendingPathComponent(SessionManifest.fileName))
        try MeetingInfo(title: "Standup", date: startedAt, source: "Slack",
                        durationSeconds: 0, status: .recording)
            .rendered()
            .write(to: directory.appendingPathComponent(MeetingArchive.infoFileName),
                   atomically: true, encoding: .utf8)

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
