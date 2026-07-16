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
    /// What a recovery pass changed in the archive.
    ///
    /// Three lists rather than one, because the outcomes need different things said about them: a
    /// folder that assembled whole holds audio the user can play, whereas one that gave up holds a
    /// meeting that lives, in part or entirely, only as raw segments. Reporting either give-up as
    /// "recovered" would be false, and not reporting it at all would leave the audio undiscoverable
    /// outside `log show`.
    public struct Outcome: Sendable {
        /// Folders whose every track assembled — nothing was left behind in the segments.
        public var recovered: [URL] = []
        /// Folders closed over a track that assembled while audio the plan vouched for stayed in the
        /// segments. Apart from `recovered` because this is the loss that hides: the folder holds a
        /// wav that plays, so nothing about it looks wrong until the missing track is wanted.
        public var partial: [URL] = []
        /// Folders closed with their audio still only in the segments: no track assembled, so there
        /// is no wav to play and the segments are the sole copy of the meeting.
        public var unassembled: [URL] = []
        /// Folders the pass found interrupted and left interrupted, to try again on a later launch —
        /// an attempt spent on audio the assembly could not place, or a cause outside the folder
        /// (no `ffmpeg`). Apart from the three above because they are terminal and this is not: the
        /// marker still says `recording`.
        ///
        /// It exists because without it such a folder is invisible to the caller — the pass returns
        /// the same empty outcome it returns for an archive with nothing to recover, and those are
        /// opposite answers. That ambiguity is exactly what `RecordingController.awaitRecovery()`
        /// has to resolve.
        public var retrying: [URL] = []

        /// Whether the pass left the archive as it found it.
        public var isEmpty: Bool {
            recovered.isEmpty && partial.isEmpty && unassembled.isEmpty && retrying.isEmpty
        }
    }

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
    /// affect the others (isolated in a `do/catch`). Returns what the pass changed.
    @discardableResult
    public func recoverInterruptedSessions() -> Outcome {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: archiveRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return Outcome()
        }

        var outcome = Outcome()
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir, let manifest = store.read(from: dir), Recovery.needsRecovery(manifest) else {
                continue
            }
            do {
                try recover(directory: dir, manifest: manifest)
                outcome.recovered.append(dir)
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
            } catch SegmentAssembler.AssembleError.segmentsUnrepairable,
                    SegmentAssembler.AssembleError.concatFailed {
                // The segments hold audio that never reached a final file — the repair could not
                // place it, or `ffmpeg` refused to concat it. Either way the segments are its only
                // copy, so retry on a later launch — but not forever; see `retryOrCloseIncomplete`.
                //
                // `concatFailed` belongs here and not in the generic `catch` below: `-xerror` is
                // what turned it from a failure `ffmpeg` used to swallow (exit 0, short file) into a
                // live one, and its usual causes — segments `-c copy` cannot splice, a torn file —
                // are as permanent as a failed repair. Left unbounded it would re-run a full concat
                // on every launch, with every `start()` waiting on it, forever.
                switch retryOrCloseIncomplete(directory: dir, manifest: manifest) {
                case .retrying: outcome.retrying.append(dir)
                case .closedWithTracks: outcome.partial.append(dir)
                case .closedWithoutTracks: outcome.unassembled.append(dir)
                }
            } catch {
                // `ffmpegNotFound` lands here deliberately, and must stay unbounded: without the
                // binary nothing assembles for reasons outside this folder, and installing it is
                // exactly the kind of fix a later launch is meant to pick up. The folder keeps its
                // `recording` marker, so it is a retry like any other and is reported as one.
                outcome.retrying.append(dir)
                let name = dir.lastPathComponent
                log.error("""
                    Failed to recover \(name, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        return outcome
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

    /// How many times a folder may come back with audio that reached no final file before recovery
    /// stops retrying it. Three, because the two outcomes it arbitrates are asymmetric: a retry costs
    /// one more `ffmpeg` concat at launch, whereas giving up too early costs the audio its last
    /// chance of reaching a file.
    public static let maxAssemblyAttempts = 3

    /// What a pass over an incomplete folder decided.
    private enum IncompleteOutcome {
        /// An attempt was spent; the folder stays `recording` for the next launch.
        case retrying
        /// The attempts ran out and the folder closed over at least one assembled track, with the
        /// audio that never assembled left in the segments.
        case closedWithTracks
        /// The attempts ran out and no track assembled: the meeting survives only as segments.
        case closedWithoutTracks
    }

    /// A folder whose segments still hold audio the assembly could not place — a failed repair, or a
    /// concat `ffmpeg` refused. Spend an attempt and leave it `recording` so the next launch tries
    /// again — until the attempts run out, at which point keep the tracks that did assemble and close
    /// the folder.
    ///
    /// Bounded rather than eternal because neither cause is reliably transient. A failed concat is a
    /// property of the segments themselves — a stream `-c copy` cannot splice, a torn file — and they
    /// do not change between launches. A failed repair is the same story: `SegmentRepair.apply`
    /// overwrites eight bytes of an existing file, so it never needs a free block, and what actually
    /// stops it — a wrong permission, an immutable flag, failing hardware — is still there next time.
    ///
    /// Giving up loses nothing: `assemble` throws before any deletion and recovery never deletes
    /// anyway, so the segments outlive us and stay the audio's copy of record.
    private func retryOrCloseIncomplete(directory: URL, manifest: SessionManifest) -> IncompleteOutcome {
        let name = directory.lastPathComponent
        var updated = manifest
        updated.assemblyAttempts += 1

        guard updated.assemblyAttempts >= Self.maxAssemblyAttempts else {
            // Status stays `recording`: that marker *is* the retry request.
            log.error("""
                \(name, privacy: .public): segments hold audio that did not reach the assembly \
                (attempt \(updated.assemblyAttempts, privacy: .public) of \
                \(Self.maxAssemblyAttempts, privacy: .public)) — will retry on the next launch
                """)
            writeMarker(updated, to: directory)
            return .retrying
        }

        log.error("""
            \(name, privacy: .public): segments still hold audio that did not reach the assembly \
            after \(Self.maxAssemblyAttempts, privacy: .public) attempts — closing the recording \
            with the tracks that did assemble; the segments are kept and remain the only copy of the \
            rest
            """)
        // Measured off the tracks that made it, exactly as a clean assembly would — they are on disk
        // already (`concatTrack` renames each into place before the throw). Short by the audio that
        // never assembled, but it is the length of the files the user actually has, and `info.md`
        // must match them.
        let tracks = assembledTracks(in: directory)
        let duration = tracks.compactMap { SegmentAssembler.measuredDuration(of: $0) }.max()

        updated.status = .recovered
        // `segmentCount` is deliberately left as the crash found it. It counts segments, and the
        // crash-time count is the last true one anybody wrote: overwriting it with `tracks.count`
        // would seal a terminal marker around a number in the wrong unit — a 240-segment meeting
        // closing as `segment_count: 2` — which reads plausible and is exactly the kind of wrong the
        // duration fallback in `recover` would then multiply by `segmentSeconds`.
        //
        // The marker is what actually closes the folder, so a failed write means it is not closed:
        // `session.json` still says `recording` and the next launch will assemble it again. Report
        // `.retrying` to match, and leave `info.md` alone — writing the give-up note over a folder
        // the code will keep retrying would state the one thing that is not true, and hand the user
        // a "could not be assembled" notification on every launch from here on.
        guard writeMarker(updated, to: directory) else { return .retrying }

        // Every give-up leaves audio behind, so every give-up says so. Neither shape can state it in
        // the front-matter alone: with no track the folder is byte-for-byte `closeEmpty`'s — terminal,
        // zero duration, no wav — while meaning the opposite, and with a track it is
        // indistinguishable from a clean recovery, only short. `info.md` is the archive's metadata
        // and is read without the app (SPEC §6), so that is where the difference has to be visible;
        // a `log.error` nobody runs `log show` for is not a diagnosis.
        let note = tracks.isEmpty ? Self.unassembledNote : Self.partialNote
        updateInfo(in: directory, status: updated.status,
                   durationSeconds: duration.map { max(0, Int($0.rounded())) } ?? 0,
                   note: note)

        return tracks.isEmpty ? .closedWithoutTracks : .closedWithTracks
    }

    /// What `info.md` says about a meeting whose audio never reached a track. Spelled out in the file
    /// itself so the segments are discoverable by whoever opens the folder.
    static let unassembledNote = """
        > **The audio could not be assembled.** Recovery tried \(maxAssemblyAttempts) times and \
        `ffmpeg` never produced a track. The raw segments under `system/` and `mic/` were kept — \
        they are the only copy of this recording.
        """

    /// What `info.md` says about a meeting that closed over some of its audio. The track that did
    /// assemble is what makes this worth spelling out: it plays, and the `duration` above is measured
    /// off it, so nothing in the folder would otherwise hint that the rest is missing.
    static let partialNote = """
        > **Part of the audio could not be assembled.** Recovery tried \(maxAssemblyAttempts) times \
        and `ffmpeg` never placed all of it into a track. What did assemble is in this folder; the \
        rest exists only in the raw segments under `system/` and `mic/`, which were kept — the \
        `duration` above is the length of the assembled audio, not of the meeting.
        """

    /// The final tracks sitting in a recording folder, in the order `info.md` would report them.
    private func assembledTracks(in directory: URL) -> [URL] {
        [SegmentLayout.systemTrackFileName, SegmentLayout.micTrackFileName]
            .map { directory.appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
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
        // Same rule as the give-up path: the marker is what makes this terminal, so if it did not
        // land the folder is still `recording` and `info.md` must not say otherwise.
        guard writeMarker(updated, to: directory) else { return }
        // "No segments" is not "no audio": a clean stop assembles the tracks and *then* deletes the
        // segments, so a marker write that failed after that (a full disk, a transient I/O error —
        // `RecordingSession.stop` swallows it) leaves exactly this shape, with two whole wavs next to
        // it. Writing a flat zero here would then overwrite the real duration `performStop` had
        // already recorded — an hour-long meeting reading `00:00:00` in the one file that is meant to
        // outlive the app (SPEC §6). So measure what is on disk, as the give-up path does, and fall
        // back to zero only when there genuinely is nothing to measure.
        let duration = assembledTracks(in: directory)
            .compactMap { SegmentAssembler.measuredDuration(of: $0) }
            .max()
        updateInfo(in: directory, status: updated.status,
                   durationSeconds: duration.map { max(0, Int($0.rounded())) } ?? 0)
    }

    /// Persist the marker, logging a failure instead of swallowing it. `false` = the marker on disk
    /// is still the old one.
    ///
    /// The write is the one step the retry bound cannot do without: if it fails, `assemblyAttempts`
    /// never rises and the folder re-runs a full concat on every launch — the very loop the bound
    /// exists to stop. That case is also unfixable from here (an unwritable folder cannot be sealed
    /// terminal either, because sealing it *is* a write), so the honest thing this code can do is
    /// leave a trace of why the bound stopped working — and tell the caller, so nothing downstream
    /// describes a folder as closed when the file that closes it never landed.
    @discardableResult
    private func writeMarker(_ manifest: SessionManifest, to directory: URL) -> Bool {
        do {
            try store.write(manifest, to: directory)
            return true
        } catch {
            log.error("""
                \(directory.lastPathComponent, privacy: .public): could not write \
                \(SessionManifest.fileName, privacy: .public) — the folder will be retried on every \
                launch: \(error.localizedDescription, privacy: .public)
                """)
            return false
        }
    }

    /// Bring `info.md` in line with the marker: at start it is written as `recording` with a zero
    /// duration, and without this a recovered meeting would stay "recording" forever — `info.md`
    /// *is* the archive metadata (SPEC §6), and it is read without the app.
    ///
    /// `note` is appended to the body for the cases the front-matter has no vocabulary for — a
    /// give-up that assembled nothing looks identical to an empty recording in `status`+`duration`
    /// alone.
    private func updateInfo(in directory: URL, status: SessionManifest.Status,
                            durationSeconds: Int, note: String? = nil) {
        let url = directory.appendingPathComponent(MeetingArchive.infoFileName)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        var patched = MeetingInfo.patchedFrontMatter(contents, status: status,
                                                     durationSeconds: durationSeconds)
        if let note { patched = MeetingInfo.appendingNote(patched, note: note) }
        try? patched.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
