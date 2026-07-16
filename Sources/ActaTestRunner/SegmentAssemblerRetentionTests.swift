import Testing
import Foundation
import ActaKit
import ActaRuntime

// The retention guard: what `assemble` must NOT delete. A segment is discarded at two steps — the
// plan and the repair — and audio lost at either one leaves the segment file as its only copy.
// These tests live apart from `SegmentAssemblerTests` because they assert the opposite outcome:
// there, assembly succeeds and the segments are redundant; here, it reports a loss and they are the
// recording.

/// The blind spot the retention guard was missing. A segment is discarded at *two* steps — the plan
/// and the repair — and the guard used to measure only the second, because it compared the repaired
/// count against the plan the drop had already happened in.
///
/// The damage needs the mixed case: with one good segment the track concats, the assembly looks
/// clean, and `deleteSegments` (the default in production) then deletes the only copy of the audio
/// the plan could not read. A `data` chunk past the probe window is how that happens for real.
@Test
func assembleKeepsSegmentsWhenThePlanCouldNotReadOneOfThem() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 1, micSegments: 1)
        let systemDir = directory.appendingPathComponent(SegmentLayout.systemDirName)
        try writeWAV(to: systemDir.appendingPathComponent("0000.wav"), frames: 24_000) // 0.5 s
        try writeWAVWithDataBeyondProbe(to: systemDir.appendingPathComponent("0001.wav"))

        // `deleteSegments: true` is the point: this is production's setting, and the bug was that it
        // took the unreadable segment with it.
        #expect(throws: SegmentAssembler.AssembleError.segmentsUnrepairable) {
            try SegmentAssembler().assemble(in: directory, deleteSegments: true)
        }

        // The audio that reached no final file is still on disk, under its own name.
        #expect(exists(systemDir.appendingPathComponent("0001.wav")))
        #expect(exists(systemDir.appendingPathComponent("0000.wav")))
        #expect(exists(directory.appendingPathComponent(SegmentLayout.micDirName)))
    }
}

/// The carve-out that keeps the guard from firing on every recording: `AVAssetWriter` creates a
/// segment file before the first buffer, so a sub-`minValidSegmentBytes` stub holds nothing at all.
/// Counting it as a loss would retain the segments of every clean recording forever — the guard has
/// to distinguish "we could not read this audio" from "there was never any audio here".
@Test
func assembleStillDeletesSegmentsWhenTheOnlyDropIsAnEmptyPreamble() throws {
    try withRecordingDirectory { directory in
        try makeRecording(in: directory, systemSegments: 1, micSegments: 1)
        let systemDir = directory.appendingPathComponent(SegmentLayout.systemDirName)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: systemDir.appendingPathComponent("0001.wav"))

        let result = try SegmentAssembler().assemble(in: directory, deleteSegments: true)

        #expect(result.systemWAV != nil)
        #expect(!exists(systemDir))
        #expect(!exists(directory.appendingPathComponent(SegmentLayout.micDirName)))
    }
}
