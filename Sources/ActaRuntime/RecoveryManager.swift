import ActaKit
import Foundation
import os

/// Recovery of interrupted recordings at app start (see the `crash-safe-recording` skill).
///
/// On `kill -9`/a computer restart the process never reaches a clean stop: the recording folder is
/// left with a `session.json` carrying `status=recording` and unassembled segments. On launch,
/// `RecoveryManager` scans the archive, finds such folders, assembles the surviving segments into
/// `system.wav`/`mic.wav` (the unfinalized last segment is repaired from its actual size, not
/// dropped) and moves the marker to `status=recovered`.
public struct RecoveryManager {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "RecoveryManager")
    private let fileManager = FileManager.default
    private let store = SessionManifestStore()
    private let assembler = SegmentAssembler()

    /// The root of the recordings archive.
    public let archiveRoot: URL

    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    /// Scan the archive and recover every interrupted recording. An error in one folder does not
    /// affect the others (isolated in a `do/catch`). Returns the folders that were recovered.
    @discardableResult
    public func recoverInterruptedSessions() -> [URL] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: archiveRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var recovered: [URL] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir, let manifest = store.read(from: dir), Recovery.needsRecovery(manifest) else {
                continue
            }
            do {
                try recover(directory: dir, manifest: manifest)
                recovered.append(dir)
            } catch SegmentAssembler.AssembleError.noSegments {
                // There is nothing to salvage and never will be: the crash managed to create the
                // marker, but not a single valid segment was left. Leaving `recording` would doom
                // the folder to a futile assembly on every launch and an eternal "not finished" in
                // the list with no way to clear it. We do not add it to `recovered`: there was
                // nothing to recover, and there is no reason to lie in the notification.
                //
                // `segmentsUnrepairable` deliberately does not come here: there the segments *do*
                // hold audio, so it gets its own bounded retry below.
                closeEmpty(directory: dir, manifest: manifest)
            } catch SegmentAssembler.AssembleError.segmentsUnrepairable {
                // The segments hold audio that the repair could not get into a final file. Retry on
                // a later launch — but not forever; see `retryOrCloseIncomplete`.
                retryOrCloseIncomplete(directory: dir, manifest: manifest)
            } catch {
                let name = dir.lastPathComponent
                log.error("""
                    Failed to recover \(name, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        return recovered
    }

    /// Recover a single folder: assemble the surviving segments, mark it `recovered`.
    private func recover(directory: URL, manifest: SessionManifest) throws {
        log.info("Recovering an interrupted recording: \(directory.lastPathComponent, privacy: .public)")
        // During recovery we do not delete the segments: we keep the raw material in case the
        // assembly turns out to have problems.
        let result = try assembler.assemble(in: directory, deleteSegments: false)

        var updated = manifest
        updated.status = .recovered
        updated.segmentCount = result.segmentCount
        try store.write(updated, to: directory)
        // From the assembled audio, not from the segment count × length: the last segment is almost
        // never full (the crash lands in the middle of it), and a ×15 estimate would round it up to
        // a whole segment.
        let duration = result.durationSeconds.map { max(0, Int($0.rounded())) }
            ?? (result.segmentCount * manifest.segmentSeconds)
        updateInfo(in: directory, status: updated.status, durationSeconds: duration)
    }

    /// How many times a folder may come back `segmentsUnrepairable` before recovery stops retrying
    /// it. Three, because the two outcomes it arbitrates are asymmetric: a retry costs one more
    /// `ffmpeg` concat at launch, whereas giving up too early costs the audio its last chance of
    /// reaching a file.
    public static let maxAssemblyAttempts = 3

    /// A folder whose segments still hold audio the repair could not place. Spend an attempt and
    /// leave it `recording` so the next launch tries again — until the attempts run out, at which
    /// point keep the tracks that did assemble and close the folder.
    ///
    /// Bounded rather than eternal because the causes of a failed repair are mostly *not* transient:
    /// `SegmentRepair.apply` overwrites eight bytes of an existing file, so it does not need a free
    /// block, and what actually stops it — a read-only volume, a wrong permission, an immutable
    /// flag, failing hardware — will still be there on the next launch and the one after it.
    ///
    /// Giving up loses nothing: `assemble` throws before any deletion and recovery never deletes
    /// anyway, so the segments outlive us and stay the audio's copy of record.
    private func retryOrCloseIncomplete(directory: URL, manifest: SessionManifest) {
        let name = directory.lastPathComponent
        var updated = manifest
        updated.assemblyAttempts += 1

        guard updated.assemblyAttempts >= Self.maxAssemblyAttempts else {
            // Status stays `recording`: that marker *is* the retry request.
            log.error("""
                \(name, privacy: .public): segments hold audio that could not be repaired into the \
                assembly (attempt \(updated.assemblyAttempts, privacy: .public) of \
                \(Self.maxAssemblyAttempts, privacy: .public)) — will retry on the next launch
                """)
            try? store.write(updated, to: directory)
            return
        }

        log.error("""
            \(name, privacy: .public): segments still hold audio that could not be repaired after \
            \(Self.maxAssemblyAttempts, privacy: .public) attempts — closing the recording with the \
            tracks that did assemble; the segments are kept and remain the only copy of the rest
            """)
        updated.status = .recovered
        try? store.write(updated, to: directory)
        // Measured off the tracks that made it, exactly as a clean assembly would — they are on disk
        // already (`concatTrack` renames each into place before the throw). Short by the audio that
        // never got repaired, but it is the length of the files the user actually has, and `info.md`
        // must match them.
        let duration = [SegmentLayout.systemTrackFileName, SegmentLayout.micTrackFileName]
            .map { directory.appendingPathComponent($0) }
            .compactMap { SegmentAssembler.measuredDuration(of: $0) }
            .max()
        updateInfo(in: directory, status: updated.status,
                   durationSeconds: duration.map { max(0, Int($0.rounded())) } ?? 0)
    }

    /// Close the marker of a folder with nothing to salvage: `recovered` with zero segments is a
    /// terminal status, so the next launch will not touch it again. We do not delete the folder
    /// itself: `info.md` with the meeting's title and time is the only trace that a recording was
    /// even attempted, and the decision to erase it stays with the user.
    private func closeEmpty(directory: URL, manifest: SessionManifest) {
        log.error("""
            Nothing to recover (no valid segments): \
            \(directory.lastPathComponent, privacy: .public)
            """)
        var updated = manifest
        updated.status = .recovered
        updated.segmentCount = 0
        try? store.write(updated, to: directory)
        updateInfo(in: directory, status: updated.status, durationSeconds: 0)
    }

    /// Bring `info.md` in line with the marker: at start it is written as `recording` with a zero
    /// duration, and without this a recovered meeting would stay "recording" forever — `info.md`
    /// *is* the archive metadata (SPEC §6), and it is read without the app.
    private func updateInfo(in directory: URL, status: SessionManifest.Status,
                            durationSeconds: Int) {
        let url = directory.appendingPathComponent(MeetingArchive.infoFileName)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let patched = MeetingInfo.patchedFrontMatter(contents, status: status,
                                                     durationSeconds: durationSeconds)
        try? patched.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
