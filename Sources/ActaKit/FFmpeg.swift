import Foundation

/// Pure builders of `ffmpeg` arguments for assembling segments and mixing tracks.
///
/// Launching the actual process lives in the `Acta` executable target; this file holds only
/// **pure logic** (covered by unit tests — see `FFmpegTests`). That keeps the requirement of
/// crash-safe assembly of final files from segments verifiable without starting the audio stack.
public enum FFmpeg {
    /// Contents of `list.txt` for the ffmpeg concat demuxer.
    ///
    /// Each line is `file '<path>'`. Single quotes inside a path are escaped as `'\''` (the
    /// standard trick for the concat demuxer); otherwise a path with an apostrophe breaks list
    /// parsing.
    public static func concatListContents(segmentPaths: [String]) -> String {
        segmentPaths
            .map { "file '\(escapeForConcatList($0))'" }
            .joined(separator: "\n")
            + (segmentPaths.isEmpty ? "" : "\n")
    }

    /// Arguments that concatenate one track's segments into a single file (without re-encoding).
    ///
    /// `-f concat -safe 0 -i list.txt -c copy output` — a fast assembly of segments that share the
    /// same format. `-y` overwrites an existing output (which matters during recovery).
    ///
    /// `-xerror` is the load-bearing flag: on a segment it fails to demux, `ffmpeg` logs the error,
    /// writes the audio it did manage to read and **exits 0** (measured). Without `-xerror` that
    /// reads as a clean assembly — the caller marks the meeting `done` and deletes the segments,
    /// which were the only copy of the part that never made it into the track. Failing loudly keeps
    /// the segments and lets recovery retry.
    public static func concatArgs(listPath: String, outputPath: String) -> [String] {
        ["-y", "-xerror", "-f", "concat", "-safe", "0", "-i", listPath, "-c", "copy", outputPath]
    }

    /// Arguments that mix the two tracks (system + microphone) into a combined file.
    ///
    /// `amix=inputs=2:duration=longest` — the duration follows the longest track. `normalize=0`
    /// disables dividing the amplitude by the number of inputs (otherwise the mix sounds half as
    /// loud).
    public static func mixArgs(systemPath: String, micPath: String, outputPath: String) -> [String] {
        [
            "-y",
            "-i", systemPath,
            "-i", micPath,
            "-filter_complex", "amix=inputs=2:duration=longest:normalize=0",
            outputPath
        ]
    }

    /// Escaping of a single quote for a `file '...'` line of the concat list.
    static func escapeForConcatList(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }
}
