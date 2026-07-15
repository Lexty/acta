import ActaKit
import Foundation
import os

/// Assembly of the final recording files from segments via `ffmpeg`. Used both on a clean stop
/// and during recovery (`RecoveryManager`) — the segment-selection rule is the same.
///
/// Order: for each track build a segment plan (`Recovery.recoveryPlan`) → repair unfinalized
/// headers → `ffmpeg -f concat -c copy` → `system.wav`/`mic.wav`; if both came out — mix into
/// `combined.wav`. The plan drops a segment without usable audio, so assembly does not fail, while
/// an unfinalized one (but with audio) is repaired from its actual size rather than lost.
///
/// The `ffmpeg` arguments are pure functions `FFmpeg.*` (covered by unit tests); this file only
/// launches the process.
struct SegmentAssembler {
    /// Assembly result — which final files were produced.
    struct Result: Sendable {
        var systemWAV: URL?
        var micWAV: URL?
        var combinedWAV: URL?
        /// How many valid segments went into the assembly (maximum across the tracks).
        var segmentCount: Int = 0
        /// Duration of the assembled audio, in seconds — measured from the final file, not from
        /// the clock. `nil` if it could not be measured (no file / unreadable header).
        ///
        /// The clock lies: `SCStream` does not come up instantly, and in a live run a "29 s"
        /// recording contained 23.66 s of audio. It is exactly this value that goes into `info.md`
        /// (Task 8.3).
        var durationSeconds: Double?
    }

    enum AssembleError: Error {
        case ffmpegNotFound
        case noSegments
        /// `ffmpeg` failed to assemble a track. Kept separate from `noSegments`: an empty track is
        /// not an error, whereas a failed assembly means the segments are the only copy of the
        /// audio and must not be touched.
        case concatFailed(track: String)
        /// Both tracks were assembled, but `ffmpeg` could not mix them into `combined.wav`. This is
        /// an error, not a "the mix didn't work out": with the "combined only" setting the user
        /// asked for exactly that file, and staying silent about its absence is the same as showing
        /// a "mute" recording.
        case mixFailed
    }

    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "SegmentAssembler")
    private let fileManager = FileManager.default

    /// Assemble the final files in `directory`.
    ///
    /// - Parameters:
    ///   - directory: the recording folder (contains `system/`, `mic/`).
    ///   - deleteSegments: delete the segment directories after a successful assembly.
    ///   - tracks: which final tracks to keep (Task 7 setting). `combined` requires both tracks, so
    ///     the intermediate `system.wav`/`mic.wav` are assembled even when the track's flag is off,
    ///     provided the mix is needed, and are deleted afterwards.
    @discardableResult
    func assemble(in directory: URL, deleteSegments: Bool,
                  tracks: RecordingSettings.TrackSelection = .init(system: true, mic: true, combined: true)
    ) throws -> Result {
        guard let ffmpeg = Self.locateFFmpeg() else { throw AssembleError.ffmpegNotFound }

        // combined = a mix of the two tracks, so the source wavs are needed even if the track itself
        // is not kept.
        let needSystem = tracks.system || tracks.combined
        let needMic = tracks.mic || tracks.combined

        let system = needSystem
            ? try concatTrack(dirName: SegmentLayout.systemDirName,
                              outputName: "system.wav", in: directory, ffmpeg: ffmpeg)
            : (url: nil, count: 0)
        let mic = needMic
            ? try concatTrack(dirName: SegmentLayout.micDirName,
                              outputName: "mic.wav", in: directory, ffmpeg: ffmpeg)
            : (url: nil, count: 0)

        let systemWAV = system.url
        let micWAV = mic.url
        guard systemWAV != nil || micWAV != nil else { throw AssembleError.noSegments }

        var result = Result(systemWAV: systemWAV, micWAV: micWAV, combinedWAV: nil,
                            segmentCount: max(system.count, mic.count))

        // Both tracks assembled but the mix did not = an ffmpeg failure: the assembly cannot be
        // trusted, so we throw, just like for `concatFailed`. The session marker stays `recording`,
        // the segments and the intermediate wavs are intact, and recovery on the next launch will
        // retry. Returning "success" here without `combined.wav` would mean claiming "saved" about
        // a file that does not exist.
        if tracks.combined, let systemWAV, let micWAV {
            let combined = directory.appendingPathComponent("combined.wav")
            let args = FFmpeg.mixArgs(systemPath: systemWAV.path, micPath: micWAV.path,
                                      outputPath: combined.path)
            guard runFFmpeg(ffmpeg, args: args) else { throw AssembleError.mixFailed }
            result.combinedWAV = combined
        }

        // The mix was requested, but one of the tracks simply did not exist (mic off — `concatTrack`
        // returned nil; a failure would have thrown `concatFailed`): there is nothing to mix. The
        // surviving track is the only result of the recording, and deleting it because of the
        // "combined only" setting is not allowed: the stop would lose the meeting entirely.
        let combinedMissing = tracks.combined && result.combinedWAV == nil

        // Remove the intermediate tracks the user did not ask to keep.
        if !tracks.system, let systemWAV, !combinedMissing {
            try? fileManager.removeItem(at: systemWAV)
            result.systemWAV = nil
        }
        if !tracks.mic, let micWAV, !combinedMissing {
            try? fileManager.removeItem(at: micWAV)
            result.micWAV = nil
        }

        // We get here once every track that there was anything to assemble from already sits next
        // to us as its own wav: any assembly failure throws above, and `combinedMissing` means one
        // of the source tracks did not exist and the surviving one (`system.wav`/`mic.wav`) was
        // deliberately left in place above. That is, the segments are by now redundant raw material,
        // and a Mac without a microphone (where a mix is impossible in principle) does not hoard
        // them forever either.
        if deleteSegments {
            for name in [SegmentLayout.systemDirName, SegmentLayout.micDirName] {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }

        // We measure the very file the user will get; the tracks of one recording are equal in
        // length, so the choice between them does not affect the number.
        result.durationSeconds = [result.combinedWAV, result.systemWAV, result.micWAV]
            .compactMap { $0 }
            .lazy
            .compactMap { Self.measuredDuration(of: $0) }
            .first

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
