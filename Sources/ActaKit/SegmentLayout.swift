import Foundation

/// On-disk layout of a segmented recording — **pure logic** of names and directories.
///
/// Each track is recorded as short segments (see the `crash-safe-recording` skill):
/// `system/0000.wav`, `system/0001.wav`, …, and likewise for `mic/`. The names are needed both by
/// the recorder (`SegmentWriter`) and by recovery (`RecoveryManager`, Task 3) — hence they are
/// factored out into testable pure logic (see `SegmentLayoutTests`).
public enum SegmentLayout {
    /// Subdirectory holding the system-audio track's segments.
    public static let systemDirName = "system"

    /// Subdirectory holding the microphone track's segments.
    public static let micDirName = "mic"

    /// File extension of a segment.
    public static let segmentExtension = "wav"

    /// The assembled system-audio track, sitting in the recording folder next to `info.md`.
    public static let systemTrackFileName = "system.wav"

    /// The assembled microphone track.
    public static let micTrackFileName = "mic.wav"

    /// Width of the sequence number in a name (zero-padded) — `%04d`.
    public static let indexDigits = 4

    /// Recommended segment length, s. A trade-off: a crash loses at most this much, but segments
    /// that are too short multiply files and finalisation overhead.
    public static let defaultSegmentSeconds = 15

    /// Segment file name for a sequence number: `0000.wav`, `0001.wav`, …
    public static func segmentFileName(index: Int) -> String {
        let padded = String(format: "%0\(indexDigits)d", index)
        return "\(padded).\(segmentExtension)"
    }

    /// The sequence number parsed from a segment file name, or `nil` if the name does not match
    /// the scheme.
    ///
    /// Filters out foreign files (`.DS_Store`, partially written junk, and so on) so that recovery
    /// assembles only real segments. Names are zero-padded to at least `indexDigits` (`%04d`), but
    /// an index ≥ 10000 makes them longer — so we accept **no shorter than** `indexDigits` rather
    /// than exactly that many (otherwise long recordings would lose segments during assembly).
    public static func segmentIndex(fromFileName name: String) -> Int? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == segmentExtension else { return nil }
        let stem = parts[0]
        guard stem.count >= indexDigits, stem.allSatisfy(\.isNumber) else { return nil }
        return Int(stem)
    }

    /// The valid segments from a list of file names, sorted by ascending number.
    ///
    /// Returns "number + name" pairs; unsuitable names are dropped. This is the basis of segment
    /// selection for assembly (Task 3) — kept here so it can be tested separately from the file
    /// system.
    public static func orderedSegments(fromFileNames names: [String]) -> [(index: Int, fileName: String)] {
        names
            .compactMap { name -> (index: Int, fileName: String)? in
                guard let idx = segmentIndex(fromFileName: name) else { return nil }
                return (index: idx, fileName: name)
            }
            .sorted { $0.index < $1.index }
    }
}
