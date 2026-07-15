import Foundation

/// Applying a `WAV.HeaderRepair` to a segment on disk.
///
/// The rest of `ActaKit` is deliberately free of the file system, and this is the exception: it is
/// the code that actually rescues the audio a `kill -9` left behind, and under CLT-only a unit test
/// can only reach what lives in `ActaKit` (see `SegmentRepairTests`). Left in the executable target
/// it would be untestable — and a swapped seek/write pair or a dropped truncate yields a plan that
/// is correct and a file that `ffmpeg` still refuses, which no pure test of `WAV.headerRepair` can
/// catch.
public enum SegmentRepair {
    /// Write the sizes into the header and cut the file to a whole number of frames.
    /// - Returns: `false` if the file would not cooperate — the caller then leaves the segment out
    ///   of the assembly rather than handing `ffmpeg` a file it would choke on.
    public static func apply(_ repair: WAV.HeaderRepair, to url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(repair.riffSizeOffset))
            try handle.write(contentsOf: WAV.le32(repair.riffSize))
            try handle.seek(toOffset: UInt64(repair.dataSizeOffset))
            try handle.write(contentsOf: WAV.le32(repair.dataSize))
            try handle.truncate(atOffset: UInt64(repair.truncatedFileSize))
            try handle.synchronize()
            return true
        } catch {
            return false
        }
    }
}
