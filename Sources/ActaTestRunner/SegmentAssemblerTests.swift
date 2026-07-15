import Testing
import Foundation
import ActaKit
import ActaRuntime

// Filesystem-level assembly (Task 12): `SegmentAssembler` takes a directory, so the whole thing is
// automatable from fixture WAV segments — no capture, no UI. This is what proves that dropping the
// mix did not break assembly itself: everything below `assemble` (the segment plan, the header
// repair, the `ffmpeg` concat, the segment deletion) is exercised for real.
//
// These tests need `ffmpeg` (a required runtime tool — see CLAUDE.md). Without it there is nothing
// to assert about assembly, so they fail rather than pass quietly.

// MARK: - The two tracks, and nothing else

/// The heart of Task 12: a mix is derived data and is no longer written. `exactly` matters here —
/// asserting only "system.wav and mic.wav exist" would pass just as happily with a third 108 MB
/// file next to them.
@Test
func assembleProducesExactlySystemAndMicWAV() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 3, micSegments: 3)

        let result = try SegmentAssembler().assemble(in: directory, deleteSegments: false)

        #expect(finalFileNames(in: directory) == ["system.wav", "mic.wav"])
        #expect(result.systemWAV?.lastPathComponent == "system.wav")
        #expect(result.micWAV?.lastPathComponent == "mic.wav")
        #expect(result.segmentCount == 3)
        #expect(!exists(directory.appendingPathComponent("combined.wav")))
    }
}

/// One track empty is not an error — it is a Mac without a microphone, or a meeting where nobody
/// unmuted. The surviving track is the entire recording, and it must come out whole.
@Test
func assembleSucceedsWhenOneTrackHasNoSegments() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 2, micSegments: nil)

        let result = try SegmentAssembler().assemble(in: directory, deleteSegments: false)

        #expect(finalFileNames(in: directory) == ["system.wav"])
        #expect(result.systemWAV != nil)
        #expect(result.micWAV == nil)
        #expect(result.segmentCount == 2)
    }
}

/// `noSegments` specifically, not "some error": `RecoveryManager` catches this case *by name* to
/// close a folder that will never assemble, and lets every other error keep the marker at
/// `recording`. A regression to `concatFailed` here would doom such a folder to an eternal "not
/// finished" — which `#expect(throws: AssembleError.self)` would happily wave through, along with
/// the `ffmpegNotFound` thrown on the first line of `assemble`.
@Test
func assembleThrowsNoSegmentsWhenBothTracksAreEmpty() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: nil, micSegments: nil)

        #expect(throws: SegmentAssembler.AssembleError.noSegments) {
            try SegmentAssembler().assemble(in: directory, deleteSegments: false)
        }
    }
}

// MARK: - Never destroy the only copy of the audio

/// A failed concat must leave the segments alone even with `deleteSegments: true`: at that moment
/// they are the only copy of the meeting. The throw keeps the session marker at `recording`, so
/// recovery retries on the next launch — deleting here would make that retry meaningless.
@Test
func assembleKeepsSegmentsWhenConcatFails() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 0, micSegments: 2)
        try makeConcatFailingSystemTrack(in: directory)
        let systemDir = directory.appendingPathComponent(SegmentLayout.systemDirName)

        // `concatFailed` for the system track, named: `AssembleError.self` would match just as well
        // if `assemble` had bailed out at its first line with `ffmpegNotFound` — and then the
        // "segments survive" assertions below would hold for the trivial reason that nothing ran.
        #expect(throws: SegmentAssembler.AssembleError
            .concatFailed(track: SegmentLayout.systemDirName)) {
            try SegmentAssembler().assemble(in: directory, deleteSegments: true)
        }

        #expect(exists(systemDir))
        #expect(exists(systemDir.appendingPathComponent("0000.wav")))
        #expect(exists(systemDir.appendingPathComponent("0001.wav")))
        #expect(exists(directory.appendingPathComponent(SegmentLayout.micDirName)))
    }
}

/// The half of a failed concat that the throw alone does not cover. `-xerror` makes `ffmpeg` exit
/// non-zero, but only *after* it has muxed everything it read before the bad segment — so the failure
/// arrives with a short, perfectly playable file already written. Left under its final name that file
/// is indistinguishable from the real track: it sits next to `info.md`, it opens, it plays, and it
/// silently under-reports a 2 s meeting while the segments that hold the rest wait for a retry.
@Test
func assembleLeavesNoPlausibleTrackFileBehindWhenConcatFails() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 0, micSegments: 2)
        try makeConcatFailingSystemTrack(in: directory)

        #expect(throws: SegmentAssembler.AssembleError
            .concatFailed(track: SegmentLayout.systemDirName)) {
            try SegmentAssembler().assemble(in: directory, deleteSegments: false)
        }

        // Nothing under the final name, and no temp left lying around either.
        #expect(!exists(directory.appendingPathComponent("system.wav")))
        #expect(!exists(directory.appendingPathComponent("system.partial.wav")))
        #expect(finalFileNames(in: directory).isEmpty)
    }
}

/// A recovery that re-assembles a folder whose earlier attempt left a `system.wav` must not be
/// blocked by it: the concat writes under a temp name and renames over whatever is there. Without
/// clearing the way first, `moveItem` would refuse and turn a healthy assembly into `concatFailed`
/// on every launch.
@Test
func assembleOverwritesATrackFileLeftByAnEarlierAttempt() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 0, micSegments: 1)
        let systemDir = directory.appendingPathComponent(SegmentLayout.systemDirName)
        try writeWAV(to: systemDir.appendingPathComponent("0000.wav"), frames: 96_000) // 2 s
        // The earlier attempt's leftover: a short file under the final name.
        try writeWAV(to: directory.appendingPathComponent("system.wav"), frames: 24_000) // 0.5 s

        let result = try SegmentAssembler().assemble(in: directory, deleteSegments: false)

        let systemWAV = try #require(result.systemWAV)
        // The fresh assembly replaced it — a stale 0.5 s would mean the rename never happened.
        let duration = try #require(durationOfWAV(at: systemWAV))
        #expect(abs(duration - 2.0) < 0.05)
    }
}

/// The total case of the rule `assembleKeepsSegmentsWhenAPlannedSegmentCouldNotBeRepaired` covers
/// partially: when *every* planned segment of *both* tracks fails its repair, no track comes out at
/// all. The distinction is the whole point — `RecoveryManager` reads `noSegments` as "nothing was
/// ever recorded, close the folder for good", and that verdict is false here. The audio is sitting
/// in the segments, and the repair failed for a reason that commonly clears.
@Test
func assembleThrowsSegmentsUnrepairableWhenEveryTrackHeldAudioThatFailedRepair() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: nil, micSegments: nil)
        var segments: [URL] = []
        for dirName in [SegmentLayout.systemDirName, SegmentLayout.micDirName] {
            let segment = directory.appendingPathComponent(dirName).appendingPathComponent("0000.wav")
            try writeUnfinalizedWAV(to: segment, frames: 24_000)
            try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                                  ofItemAtPath: segment.path)
            segments.append(segment)
        }

        // `segmentsUnrepairable`, not `noSegments`: the two differ only in what the caller does next,
        // and getting that wrong strands the audio under a terminal marker forever.
        #expect(throws: SegmentAssembler.AssembleError.segmentsUnrepairable) {
            try SegmentAssembler().assemble(in: directory, deleteSegments: true)
        }

        // And the audio the plan vouched for is still on disk, waiting for that retry.
        for segment in segments {
            #expect(exists(segment))
        }
    }
}

/// The other half of the same rule, and the reason the plan's strictness is not a loophole: a
/// segment `ffmpeg` would choke on never reaches it — `WAV.layout` refuses a `fmt ` that does not
/// describe playable PCM, so the segment drops out of the plan rather than sinking the whole
/// track's concat.
@Test
func assembleDropsASegmentWhoseFormatIsNotPlayablePCM() throws {
    try withRecordingDirectory { directory in
        // The counts are deliberately lopsided. `segmentCount` is `max(system, mic)`, so with two
        // segments per track it reads 2 whether or not the bad one drops — the assertion would pass
        // against a build that had stopped dropping anything. One mic segment makes the number
        // answer for the system track alone.
        try makeRecording(in: directory, systemSegments: 1, micSegments: 1)
        let systemDir = directory.appendingPathComponent(SegmentLayout.systemDirName)
        try writeWAV(to: systemDir.appendingPathComponent("0000.wav"), frames: 24_000) // 0.5 s
        try writeWAV(to: systemDir.appendingPathComponent("0001.wav"), frames: 24_000,
                     format: 0, channels: 0, sampleRate: 0, bitsPerSample: 0)

        let result = try SegmentAssembler().assemble(in: directory, deleteSegments: false)

        // The good segment still assembles; only the unusable one is left out.
        #expect(result.systemWAV != nil)
        #expect(result.segmentCount == 1) // the good system segment; the bad one never entered the plan
        #expect(finalFileNames(in: directory) == ["system.wav", "mic.wav"])
        // And the audio proves it: one segment's worth reached the track, not two.
        let systemWAV = try #require(result.systemWAV)
        let duration = try #require(durationOfWAV(at: systemWAV))
        #expect(abs(duration - 0.5) < 0.05)
    }
}

/// The repair path, end to end and through a real `ffmpeg` — the promise "we lose at most one
/// segment" is what this file exists to keep, and until now no fixture here ever produced a
/// `.repair`: `writeWAV` writes its sizes through, so every segment took `.include`.
///
/// It matters most right next to `-xerror`: a repaired segment (truncated in place, sizes patched
/// from the actual bytes) is exactly the input a newly strict `ffmpeg` could reject — and under
/// `-xerror` one rejected segment sinks the whole track's concat rather than costing it a tail.
@Test
func assembleRepairsAnUnfinalizedSegmentAndKeepsItsAudio() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 1, micSegments: 1)
        let systemDir = directory.appendingPathComponent(SegmentLayout.systemDirName)
        try writeWAV(to: systemDir.appendingPathComponent("0000.wav"), frames: 24_000) // 0.5 s
        // The crashed tail: 0.5 s of audio behind a header that declares none of it.
        try writeUnfinalizedWAV(to: systemDir.appendingPathComponent("0001.wav"), frames: 24_000)

        let result = try SegmentAssembler().assemble(in: directory, deleteSegments: false)

        // Both segments reached the track: the tail was repaired, not dropped. `segmentCount` is
        // `max(system, mic)` and mic holds one, so 2 can only have come from the system track.
        #expect(result.segmentCount == 2)
        let systemWAV = try #require(result.systemWAV)
        // The audio is the real assertion — a count of 2 would also hold if `ffmpeg` had written the
        // repaired segment's header and dropped its samples.
        let duration = try #require(durationOfWAV(at: systemWAV))
        #expect(abs(duration - 1.0) < 0.05)
    }
}

/// The failure the plan cannot absorb: a segment holding audio that `SegmentRepair` cannot write
/// back. It drops out of the assembly to save the rest of the track — a deliberate trade — and that
/// makes its segment file the only copy of those seconds. Deleting the track directory then would
/// destroy exactly the audio the repair path exists to rescue, and `status=done` means recovery
/// never comes back for it.
@Test
func assembleKeepsSegmentsWhenAPlannedSegmentCouldNotBeRepaired() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 2, micSegments: nil)
        // Mic: a single unfinalized segment with real audio, read-only so the repair's write fails.
        // The plan still sees the audio — `Recovery.action` reads it, it just cannot be rescued.
        let micDir = directory.appendingPathComponent(SegmentLayout.micDirName)
        let micSegment = micDir.appendingPathComponent("0000.wav")
        try writeUnfinalizedWAV(to: micSegment, frames: 24_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: micSegment.path)

        let result = try SegmentAssembler().assemble(in: directory, deleteSegments: true)

        // The healthy track is unaffected — the point is not to sink the assembly, only to keep the
        // raw material of what did not make it.
        #expect(result.systemWAV != nil)
        #expect(result.micWAV == nil)
        // The mic audio survives as the segment it still is.
        #expect(exists(micSegment))
        // And the system segments stay too: deletion is all-or-nothing per folder.
        #expect(exists(directory.appendingPathComponent(SegmentLayout.systemDirName)))
    }
}

@Test
func assembleDeletesSegmentDirectoriesAfterSuccess() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 2, micSegments: 2)

        try SegmentAssembler().assemble(in: directory, deleteSegments: true)

        #expect(!exists(directory.appendingPathComponent(SegmentLayout.systemDirName)))
        #expect(!exists(directory.appendingPathComponent(SegmentLayout.micDirName)))
        #expect(finalFileNames(in: directory) == ["system.wav", "mic.wav"])
    }
}

@Test
func assembleKeepsSegmentDirectoriesWhenDeleteIsOff() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 2, micSegments: 2)

        try SegmentAssembler().assemble(in: directory, deleteSegments: false)

        #expect(exists(directory.appendingPathComponent(SegmentLayout.systemDirName)))
        #expect(exists(directory.appendingPathComponent(SegmentLayout.micDirName)))
    }
}

// MARK: - Old recordings

/// "A mix is no longer produced" means the pipeline never *creates* one. It does not mean the folder
/// gets scrubbed: re-assembling or recovering a folder that already holds a `combined.wav` from an
/// older build leaves that file in place. Deleting a user's audio to satisfy a tidiness rule would
/// be the worse bug.
@Test
func assembleLeavesAnExistingCombinedWAVFromAnOlderBuildAlone() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 2, micSegments: 2)
        let combined = directory.appendingPathComponent("combined.wav")
        try writeWAV(to: combined, frames: 960)
        let sizeBefore = try Data(contentsOf: combined).count

        let result = try SegmentAssembler().assemble(in: directory, deleteSegments: true)

        #expect(exists(combined))
        #expect(try Data(contentsOf: combined).count == sizeBefore)
        #expect(finalFileNames(in: directory) == ["system.wav", "mic.wav", "combined.wav"])
        // It survives as a leftover, not as an assembly result: nothing re-created it.
        #expect(result.systemWAV != nil)
        #expect(result.micWAV != nil)
    }
}

// MARK: - Duration

/// The duration comes from the assembled file, not from the clock or the segment count: `SCStream`
/// does not come up instantly, and a "29 s" recording once held 23.66 s of audio.
@Test
func assembleMeasuresDurationFromTheAssembledFile() throws {
    try withRecordingDirectory { directory in
        // 48 kHz, 4 segments x 24 000 frames = 2 s of audio.
        let systemDir = directory.appendingPathComponent(SegmentLayout.systemDirName)
        let micDir = directory.appendingPathComponent(SegmentLayout.micDirName)
        for dir in [systemDir, micDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for index in 0..<4 {
                try writeWAV(to: dir.appendingPathComponent(String(format: "%04d.wav", index)),
                             frames: 24_000)
            }
        }

        let result = try SegmentAssembler().assemble(in: directory, deleteSegments: false)

        let duration = try #require(result.durationSeconds)
        #expect(abs(duration - 2.0) < 0.05)
    }
}

/// The tracks are only nominally the same length: a segment dropped from one of them shortens that
/// track alone. The meeting lasted as long as its longest track, so an uneven pair must report the
/// longer number — `combined.wav` used to supply it (mixed `duration=longest`), and taking whichever
/// track happens to come first instead would silently under-report the meeting in `info.md`.
@Test
func assembleReportsTheLongerTrackWhenTheTracksAreUneven() throws {
    try withRecordingDirectory { directory in
        let systemDir = directory.appendingPathComponent(SegmentLayout.systemDirName)
        let micDir = directory.appendingPathComponent(SegmentLayout.micDirName)
        for dir in [systemDir, micDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // system: 0.5 s — the shorter track, and the one listed first.
        try writeWAV(to: systemDir.appendingPathComponent("0000.wav"), frames: 24_000)
        // mic: 2 s.
        try writeWAV(to: micDir.appendingPathComponent("0000.wav"), frames: 96_000)

        let result = try SegmentAssembler().assemble(in: directory, deleteSegments: false)

        let duration = try #require(result.durationSeconds)
        #expect(abs(duration - 2.0) < 0.05)
    }
}
