import ActaKit
import Foundation
import os

/// Assembly of the final recording files from segments via `ffmpeg`. Used both on a clean stop
/// and during recovery (`RecoveryManager`) — the segment-selection rule is the same.
///
/// Order: for each track build a segment plan (`Recovery.recoveryPlan`) → repair unfinalized
/// headers → `ffmpeg -f concat -c copy` → `system.wav`/`mic.wav`. The plan drops a segment without
/// usable audio, so assembly does not fail, while an unfinalized one (but with audio) is repaired
/// from its actual size rather than lost.
///
/// Two tracks and nothing else: a mix is derived data — it costs a third full copy on disk and
/// collapses the "me vs. them" attribution the separate tracks exist for. `ffmpeg` reproduces one
/// from the two in seconds, on demand, if a whole-meeting listen-back is ever wanted.
///
/// The `ffmpeg` arguments are pure functions `FFmpeg.*` (covered by unit tests); this file only
/// launches the process.
public struct SegmentAssembler {
    /// Assembly result — which final files were produced.
    public struct Result: Sendable {
        public var systemWAV: URL?
        public var micWAV: URL?
        /// How many valid segments went into the assembly (maximum across the tracks).
        public var segmentCount: Int = 0
        /// Duration of the assembled audio, in seconds — measured from the final file, not from
        /// the clock. `nil` if it could not be measured (no file / unreadable header).
        ///
        /// The clock lies: `SCStream` does not come up instantly, and in a live run a "29 s"
        /// recording contained 23.66 s of audio. It is exactly this value that goes into `info.md`
        /// (Task 8.3).
        public var durationSeconds: Double?
    }

    public enum AssembleError: Error, Equatable {
        case ffmpegNotFound
        case noSegments
        /// The plan vouched for audio that then failed its repair, so those bytes reached no final
        /// file and the segment is their only copy.
        ///
        /// Kept separate from `noSegments`: that one means the crash left nothing behind and never
        /// will, which is why the caller closes the folder for good. Here the audio exists, and the
        /// repair failed for reasons that may clear (a read-only volume, a permission, a transient
        /// I/O error). Closing the folder would strand it: the marker would go terminal and no later
        /// launch would ever retry.
        ///
        /// This fires whether or not the rest of the track assembled around the hole. A partial
        /// track is the *likelier* shape — a crash leaves at most one unfinalized segment per track,
        /// so the usual failure is one bad segment among many good ones — and it is the one that
        /// must not pass as success: `system.wav` would be sitting there, playable and short, with
        /// `info.md` reporting `done` and a duration measured off the truncated audio.
        ///
        /// The tracks that did assemble are left on disk: they are a strict improvement over
        /// nothing, and a later retry overwrites them.
        case segmentsUnrepairable
        /// `ffmpeg` failed to assemble a track. Kept separate from `noSegments`: an empty track is
        /// not an error, whereas a failed assembly means the segments are the only copy of the
        /// audio and must not be touched.
        case concatFailed(track: String)
    }

    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "SegmentAssembler")
    private let fileManager = FileManager.default

    public init() {}

    /// Assemble the final files in `directory`.
    ///
    /// - Parameters:
    ///   - directory: the recording folder (contains `system/`, `mic/`).
    ///   - deleteSegments: delete the segment directories after a successful assembly.
    @discardableResult
    public func assemble(in directory: URL, deleteSegments: Bool) throws -> Result {
        guard let ffmpeg = Self.locateFFmpeg() else { throw AssembleError.ffmpegNotFound }

        // Both tracks are attempted before either failure is reported. A concat dies on properties
        // of its own segments — a mid-meeting device change leaves `system` unconcatable while `mic`
        // is perfectly whole — and throwing out of the first call would mean the second track never
        // ran at all. Its audio would then reach no file for a reason that has nothing to do with
        // it, and the cause being deterministic, no later retry would rescue it either.
        let systemOutcome = Swift.Result { try concatTrack(dirName: SegmentLayout.systemDirName,
                                                           outputName: SegmentLayout.systemTrackFileName,
                                                           in: directory, ffmpeg: ffmpeg) }
        let micOutcome = Swift.Result { try concatTrack(dirName: SegmentLayout.micDirName,
                                                        outputName: SegmentLayout.micTrackFileName,
                                                        in: directory, ffmpeg: ffmpeg) }
        let system = try systemOutcome.get()
        let mic = try micOutcome.get()

        // A segment big enough to hold audio that the plan discarded, or that failed its repair,
        // means audio reached no final file and the segment is its only copy. That is the same
        // statement whether the track around it came out empty or assembled happily, so it takes the
        // same exit: returning success on the partial case would hand the caller a `Result`
        // indistinguishable from a clean one, and the caller's next move is to close the folder for
        // good.
        //
        // Throwing here is what keeps the segments, too: every deletion below sits past this point.
        if system.retainedSegments || mic.retainedSegments {
            throw AssembleError.segmentsUnrepairable
        }

        let systemWAV = system.url
        let micWAV = mic.url
        guard systemWAV != nil || micWAV != nil else { throw AssembleError.noSegments }

        var result = Result(systemWAV: systemWAV, micWAV: micWAV,
                            segmentCount: max(system.count, mic.count))

        // The segments are redundant raw material only now: every track there was anything to
        // assemble from sits next to us as its own whole wav.
        if deleteSegments {
            for name in [SegmentLayout.systemDirName, SegmentLayout.micDirName] {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }

        // We measure the very file the user will get. The longest track, not the first one: the two
        // are nominally the same length, but only nominally — a dropped or unrepairable segment
        // shortens one track alone, and the meeting lasted as long as its longest track. `combined`
        // used to answer this (it was mixed `duration=longest`); with it gone, `max` is what keeps
        // `info.md` from under-reporting.
        result.durationSeconds = [result.systemWAV, result.micWAV]
            .compactMap { $0 }
            .compactMap { Self.measuredDuration(of: $0) }
            .max()

        return result
    }

    /// Duration of a finished wav from its header (`WAV.durationSeconds` on top of the FS).
    static func measuredDuration(of url: URL) -> Double? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        guard let size else { return nil }
        return WAV.durationSeconds(header: headerPrefix(of: url), fileSize: size)
    }

    // MARK: - Private

    /// The outcome of assembling a single track.
    private struct TrackResult {
        /// The assembled file, or `nil` if the track had no valid segments to assemble.
        var url: URL?
        /// How many segments went into it.
        var count: Int
        /// The track lost audio: a segment was discarded by the plan or failed its repair, so its
        /// bytes are in no final file and its segment file is the only copy left.
        ///
        /// `url == nil` cannot carry this on its own — an empty track and a track whose every
        /// segment failed to repair both come back `nil`, and only the second must survive the
        /// caller's deletion.
        var retainedSegments: Bool
    }

    /// Assemble the valid segments of a single track into `outputName`. Returns a `url` of `nil` if
    /// there are no valid segments (an empty track is not an error, there is simply nothing to
    /// assemble). Throws `concatFailed` if segments exist but `ffmpeg` did not assemble them:
    /// silently returning `nil` is not an option — the caller would consider the track empty and
    /// delete its segments.
    private func concatTrack(dirName: String, outputName: String, in directory: URL,
                             ffmpeg: String) throws -> TrackResult {
        let trackDir = directory.appendingPathComponent(dirName)
        let scan = Self.scanTrack(inTrackDir: trackDir)
        let planned = scan.plan
        let plan = prepareSegments(planned, inTrackDir: trackDir)
        // Audio goes missing at two steps, and both have to count here — the guard exists to stop the
        // caller deleting the only copy of audio that reached no final file.
        //
        // The plan lists only segments with usable audio in them, so anything that drops out of
        // `prepareSegments` dropped out of the *output*, not out of a set of empty files. But a
        // segment can also be discarded a step earlier, by the plan itself, and `planned` cannot show
        // that: `recoveryPlan` has already dropped it. Measuring only `plan.count < planned.count`
        // left that half invisible — a segment whose `data` chunk sits past `Recovery.headerProbeBytes`
        // is dropped silently, the surviving segments concat fine, and the deletion below then takes
        // the dropped audio with it.
        let lostInRepair = planned.count - plan.count
        let lostInPlan = scan.discardedWithAudio
        let retainedSegments = lostInRepair + lostInPlan > 0
        if retainedSegments {
            log.error("""
                Track \(dirName, privacy: .public): \(lostInPlan) segment(s) unreadable and \
                \(lostInRepair) unrepairable — that audio is in no final file, keeping the segments
                """)
        }
        guard !plan.isEmpty else {
            log.info("Track \(dirName, privacy: .public): no valid segments")
            return TrackResult(url: nil, count: 0, retainedSegments: retainedSegments)
        }

        let paths = plan.map { trackDir.appendingPathComponent($0).path }
        let listURL = directory.appendingPathComponent("\(dirName)_concat.txt")
        try FFmpeg.concatListContents(segmentPaths: paths).write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: listURL) }

        // `ffmpeg` writes as it demuxes, so a concat that dies partway leaves the audio it had
        // already muxed on disk. With `-xerror` making that failure loud, the leftover is the
        // dangerous part: a short but perfectly playable `system.wav`, sitting next to `info.md`,
        // indistinguishable from the real track. Assembling under a temp name and renaming only on
        // success means the final name never exists unless it is whole.
        // The temp keeps the `.wav` extension: `ffmpeg` picks its muxer from the output extension,
        // so a name it cannot map to a format fails the concat before it reads a single segment.
        let output = directory.appendingPathComponent(outputName)
        let partial = directory
            .appendingPathComponent("\(output.deletingPathExtension().lastPathComponent).partial.wav")
        let args = FFmpeg.concatArgs(listPath: listURL.path, outputPath: partial.path)
        guard runFFmpeg(ffmpeg, args: args) else {
            try? fileManager.removeItem(at: partial)
            throw AssembleError.concatFailed(track: dirName)
        }
        // Recovery re-assembles a folder that may already hold an output from an earlier attempt,
        // and `moveItem` refuses to clobber. `replaceItemAt` commits in one step instead of
        // unlinking the old track first: a delete-then-move whose move fails would leave the folder
        // with neither file, destroying a track an earlier attempt had assembled whole and making
        // the give-up misreport it as `closedWithoutTracks`.
        do {
            if fileManager.fileExists(atPath: output.path) {
                _ = try fileManager.replaceItemAt(output, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: output)
            }
        } catch {
            log.error("""
                Track \(dirName, privacy: .public): assembled audio could not be moved into place: \
                \(error.localizedDescription, privacy: .public)
                """)
            try? fileManager.removeItem(at: partial)
            throw AssembleError.concatFailed(track: dirName)
        }
        return TrackResult(url: output, count: plan.count, retainedSegments: retainedSegments)
    }

    /// The assembly plan for a track (`Recovery.recoveryPlan` on top of the real FS) — read only.
    ///
    /// Static and internal, because `RecordingController` uses the very same rule to decide whether
    /// a folder holds salvageable audio: `AVAssetWriter` creates the segment file **before** the
    /// first buffer, so a check like "a file named NNNN.wav exists" would mistake an empty preamble
    /// for audio.
    static func plannedSegments(inTrackDir trackDir: URL) -> [Recovery.PlannedSegment] {
        scanTrack(inTrackDir: trackDir).plan
    }

    /// What a track's segment directory holds: the plan, and how much audio the plan could not take.
    struct TrackScan {
        /// The segments to assemble, in order.
        var plan: [Recovery.PlannedSegment]
        /// Segments large enough to hold audio that the plan discarded anyway
        /// (`Recovery.discardedSegmentCount`).
        var discardedWithAudio: Int
    }

    /// Read the track directory once and derive both the plan and its losses from the same scan.
    ///
    /// One scan, not two: the headers cost `Recovery.headerProbeBytes` per segment, and a long
    /// meeting has hundreds of them.
    static func scanTrack(inTrackDir trackDir: URL) -> TrackScan {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: trackDir.path)) ?? []

        var sizes: [String: Int] = [:]
        var headers: [String: Data] = [:]
        for name in names {
            let url = trackDir.appendingPathComponent(name)
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            sizes[name] = (attrs?[.size] as? Int) ?? 0
            headers[name] = headerPrefix(of: url)
        }
        return TrackScan(
            plan: Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                        headerByFileName: headers),
            discardedWithAudio: Recovery.discardedSegmentCount(fromFileNames: names,
                                                               sizeByFileName: sizes,
                                                               headerByFileName: headers))
    }

    /// Names of the track's segments ready for assembly: the plan + in-place repair of unfinalized
    /// headers.
    ///
    /// The repair has to happen right here, before `ffmpeg`: `kill -9` leaves the last segment with
    /// seconds of real audio and unwritten sizes, and there is no other chance to get that audio
    /// back. A segment that could not be repaired (the file did not open for writing) drops out of
    /// the plan — handing `ffmpeg` a knowingly broken file would mean sinking the assembly of the
    /// whole track for the sake of its tail. That trade costs the tail its place in the output but
    /// not its existence: the caller reads the shortfall against `planned` and keeps the segments.
    private func prepareSegments(_ planned: [Recovery.PlannedSegment],
                                 inTrackDir trackDir: URL) -> [String] {
        planned.compactMap { segment in
            switch segment.action {
            case .include:
                return segment.fileName
            case .repair(let repair):
                let url = trackDir.appendingPathComponent(segment.fileName)
                guard SegmentRepair.apply(repair, to: url) else {
                    log.error("""
                        Failed to repair the header of \(segment.fileName, privacy: .public) — \
                        segment skipped
                        """)
                    return nil
                }
                log.info("""
                    Repaired the unfinalized header of \(segment.fileName, privacy: .public): \
                    \(repair.dataSize) bytes of audio
                    """)
                return segment.fileName
            }
        }
    }

    /// Read the beginning of the file so `Recovery.action` can judge the WAV header. An empty
    /// result = the file is unreadable → the segment is not considered valid.
    private static func headerPrefix(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: Recovery.headerProbeBytes)) ?? Data()
    }

    /// Run `ffmpeg`; `true` on exit code 0.
    ///
    /// A failure captures `ffmpeg`'s stderr, because `-xerror` made the exit code load-bearing: it
    /// turns any error-level event into a failed concat, which `RecoveryManager` retries only three
    /// times before closing the folder over audio that exists solely as segments. A bare exit code
    /// cannot say whether that was a segment `-c copy` refused to splice or a full disk, and
    /// "self-diagnosis comes first" is not served by a number.
    ///
    /// Redirected to a file rather than a `Pipe`: `ffmpeg` is chatty enough to fill a pipe buffer,
    /// and a full pipe with nobody draining it deadlocks `waitUntilExit` forever — with `start()`
    /// waiting behind it.
    private func runFFmpeg(_ ffmpeg: String, args: [String]) -> Bool {
        let errLog = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acta-ffmpeg-\(UUID().uuidString).log")
        fileManager.createFile(atPath: errLog.path, contents: nil)
        defer { try? fileManager.removeItem(at: errLog) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        let errHandle = try? FileHandle(forWritingTo: errLog)
        proc.standardError = errHandle ?? FileHandle.nullDevice
        defer { try? errHandle?.close() }
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                log.error("""
                    ffmpeg exited with code \(proc.terminationStatus, privacy: .public): \
                    \(Self.tail(of: errLog), privacy: .public)
                    """)
                return false
            }
            return true
        } catch {
            log.error("Failed to launch ffmpeg: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The last few lines of `ffmpeg`'s stderr — the part that names the failure. Bounded because the
    /// preamble is banner and per-stream noise, and a whole log does not belong in `os_log`.
    private static func tail(of file: URL, maxBytes: Int = 4096) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "stderr unavailable" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return "stderr empty" }
        // Lenient decode, not `String(data:encoding:)`: the window starts at an arbitrary byte offset,
        // so a strict decode returns nil whenever it lands mid-character — and `ffmpeg` echoes the
        // path it was given, which `MeetingArchive.slug` keeps Unicode-aware. A non-ASCII meeting
        // title would then turn the only diagnosis of an `-xerror` failure into "stderr empty".
        // The failable initializer `optional_data_string_conversion` asks for is the defect itself:
        // there is no valid-UTF-8 guarantee to assert here, and replacement characters on a torn
        // edge beat losing the message.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").suffix(5).joined(separator: " | ")
    }

    /// Locate the `ffmpeg` binary: the usual Homebrew paths (Apple Silicon/Intel) + `PATH`.
    static func locateFFmpeg() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/ffmpeg"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }
}
