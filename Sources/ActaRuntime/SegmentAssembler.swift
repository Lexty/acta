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

        let system = try concatTrack(dirName: SegmentLayout.systemDirName,
                                     outputName: "system.wav", in: directory, ffmpeg: ffmpeg)
        let mic = try concatTrack(dirName: SegmentLayout.micDirName,
                                  outputName: "mic.wav", in: directory, ffmpeg: ffmpeg)

        let systemWAV = system.url
        let micWAV = mic.url
        guard systemWAV != nil || micWAV != nil else { throw AssembleError.noSegments }

        var result = Result(systemWAV: systemWAV, micWAV: micWAV,
                            segmentCount: max(system.count, mic.count))

        // We get here once every track that there was anything to assemble from already sits next
        // to us as its own wav: any assembly failure throws above. That is, the segments are by now
        // redundant raw material.
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

    /// Assemble the valid segments of a single track into `outputName`. Returns the URL of the
    /// result or `nil` if there are no valid segments (an empty track is not an error, there is
    /// simply nothing to assemble). Throws `concatFailed` if segments exist but `ffmpeg` did not
    /// assemble them: silently returning `nil` is not an option — the caller would consider the
    /// track empty and delete its segments.
    private func concatTrack(dirName: String, outputName: String, in directory: URL,
                             ffmpeg: String) throws -> (url: URL?, count: Int) {
        let trackDir = directory.appendingPathComponent(dirName)
        let plan = preparedSegments(inTrackDir: trackDir)
        guard !plan.isEmpty else {
            log.info("Track \(dirName, privacy: .public): no valid segments")
            return (nil, 0)
        }

        let paths = plan.map { trackDir.appendingPathComponent($0).path }
        let listURL = directory.appendingPathComponent("\(dirName)_concat.txt")
        try FFmpeg.concatListContents(segmentPaths: paths).write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: listURL) }

        let output = directory.appendingPathComponent(outputName)
        let args = FFmpeg.concatArgs(listPath: listURL.path, outputPath: output.path)
        guard runFFmpeg(ffmpeg, args: args) else { throw AssembleError.concatFailed(track: dirName) }
        return (output, plan.count)
    }

    /// The assembly plan for a track (`Recovery.recoveryPlan` on top of the real FS) — read only.
    ///
    /// Static and internal, because `RecordingController` uses the very same rule to decide whether
    /// a folder holds salvageable audio: `AVAssetWriter` creates the segment file **before** the
    /// first buffer, so a check like "a file named NNNN.wav exists" would mistake an empty preamble
    /// for audio.
    static func plannedSegments(inTrackDir trackDir: URL) -> [Recovery.PlannedSegment] {
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
        return Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: headers)
    }

    /// Names of the track's segments ready for assembly: the plan + in-place repair of unfinalized
    /// headers.
    ///
    /// The repair has to happen right here, before `ffmpeg`: `kill -9` leaves the last segment with
    /// seconds of real audio and unwritten sizes, and there is no other chance to get that audio
    /// back. A segment that could not be repaired (the file did not open for writing) drops out of
    /// the plan — handing `ffmpeg` a knowingly broken file would mean sinking the assembly of the
    /// whole track for the sake of its tail.
    private func preparedSegments(inTrackDir trackDir: URL) -> [String] {
        Self.plannedSegments(inTrackDir: trackDir).compactMap { segment in
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
    private func runFFmpeg(_ ffmpeg: String, args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                log.error("ffmpeg exited with code \(proc.terminationStatus)")
                return false
            }
            return true
        } catch {
            log.error("Failed to launch ffmpeg: \(error.localizedDescription, privacy: .public)")
            return false
        }
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
