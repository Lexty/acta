import ActaKit
import Foundation

/// Deciding what to do with the folder left behind by a start that failed. Filesystem work, kept out
/// of `RecordingController` alongside `ArchiveOpener` — the view model should not be the thing that
/// reasons about which files on disk are worth keeping.
enum FailedStartCleanup {
    /// Remove the folder of a failed start — but only if nothing was ever written into it.
    ///
    /// An empty folder must be deleted: with status `recording` it would be stuck forever — recovery
    /// would try to assemble it on every launch (no segments → error), and it would loiter in the
    /// list as "unfinished". But "the start failed" does not mean "there is nothing on disk":
    /// `.diskWriteFailed` is also raised when one track was being written fine and the other broke
    /// (`brokenTrack`) — there is real audio there already, and it is the only copy. Such a folder is
    /// handed over to recovery instead of being deleted.
    static func removeIfEmpty(_ directory: URL?) {
        guard let directory, !hasSegments(in: directory) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Whether the folder holds at least one segment with salvageable audio (including one that is
    /// unfinished but repairable) — the same rule the assembly will follow.
    ///
    /// Salvageable specifically, not "a file with a matching name": `AVAssetWriter` creates `0000.wav`
    /// before the very first buffer, so a start that broke while writing leaves an empty preamble.
    /// Counting it as audio would mean keeping a folder with `status=recording` that recovery would
    /// vainly assemble on every launch, and that the list would forever show as "unfinished".
    private static func hasSegments(in directory: URL) -> Bool {
        [SegmentLayout.systemDirName, SegmentLayout.micDirName].contains { trackDir in
            !SegmentAssembler.plannedSegments(
                inTrackDir: directory.appendingPathComponent(trackDir)).isEmpty
        }
    }
}
