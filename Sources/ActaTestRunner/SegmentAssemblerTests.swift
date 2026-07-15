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

// MARK: - Fixtures

/// Build a valid, finalized PCM WAV: RIFF/WAVE + `fmt ` + `data` with `frames` frames of silence.
/// The sizes are written through, so `Recovery.action` returns `.include` and `ffmpeg` reads it.
///
/// The `fmt ` fields can be overridden to build a file that passes the segment plan but that
/// `ffmpeg` refuses — the plan only checks the RIFF/`data` sizes, not whether the format makes
/// sense.
private func writeWAV(to url: URL, frames: Int = 480, format: Int = 1, channels: Int = 2,
                      sampleRate: Int = 48_000, bitsPerSample: Int = 16) throws {
    let align = max(1, channels * bitsPerSample / 8)
    let fmtBody = pcmFormatBody(format: format, channels: channels, sampleRate: sampleRate,
                                bitsPerSample: bitsPerSample)
    let audio = [UInt8](repeating: 0, count: frames * align)

    var body: [UInt8] = Array("WAVE".utf8)
    body += Array("fmt ".utf8) + le32(fmtBody.count) + fmtBody
    body += Array("data".utf8) + le32(audio.count) + audio

    let bytes = Array("RIFF".utf8) + le32(body.count) + body
    try Data(bytes).write(to: url)
}

/// A recording folder with the requested number of valid segments per track. A track given `nil`
/// still gets its (empty) directory — that is what the writers create before the first buffer.
private func makeRecording(in directory: URL, systemSegments: Int?, micSegments: Int?) throws {
    for (dirName, count) in [(SegmentLayout.systemDirName, systemSegments),
                             (SegmentLayout.micDirName, micSegments)] {
        let trackDir = directory.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)
        for index in 0..<(count ?? 0) {
            try writeWAV(to: trackDir.appendingPathComponent(String(format: "%04d.wav", index)))
        }
    }
}

private func withRecordingDirectory(_ body: (URL) throws -> Void) rethrows {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acta-assembler-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// Seconds of audio an assembled track really holds, read off its header (`WAV.durationSeconds` is
/// the same pure function `SegmentAssembler` measures with).
private func durationOfWAV(at url: URL) -> Double? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return WAV.durationSeconds(header: data.prefix(Recovery.headerProbeBytes), fileSize: data.count)
}

/// The names of the final files sitting in the recording folder (the track directories and the
/// concat lists are not final files).
private func finalFileNames(in directory: URL) -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return Set(names.filter { $0.hasSuffix(".wav") })
}

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
        try makeRecording(in: directory, systemSegments: 2, micSegments: 2)
        // The segments are valid — the failure has to happen at the `ffmpeg` stage, which is the
        // one this test is about. A broken segment would not get there: the plan drops it and the
        // track comes out simply empty. So the output path is blocked with a directory instead:
        // `ffmpeg` reads the segments fine and fails to write `system.wav`.
        let systemDir = directory.appendingPathComponent(SegmentLayout.systemDirName)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("system.wav"),
                                                withIntermediateDirectories: true)

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
