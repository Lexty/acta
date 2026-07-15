import Foundation

/// Pure logic of selecting segments for assembly during recovery and on a clean stop.
///
/// Kept separate from the file system and `ffmpeg` so that the main crash-safety rule — "an
/// unfinished last segment does not break recovery, it gets rescued" — is covered by a unit test
/// (`RecoveryTests`). The runtime (`RecoveryManager`, `SegmentAssembler`) merely feeds file names,
/// their sizes and the head of each file from the FS in here, and executes the decision.
public enum Recovery {
    /// Minimum size of a valid WAV segment, bytes. A RIFF/WAVE header is ~44 bytes; a file below
    /// the threshold is an empty/unfinished (broken) segment — the typical result of a `kill -9`
    /// mid-way.
    public static let minValidSegmentBytes = 64

    /// How many bytes from the start of a file must be read to check the header.
    ///
    /// A `data` chunk not found within the prefix makes the segment invalid, so we take a wide
    /// margin: a real `AVAssetWriter(fileType: .wav)` inserts an `FLLR` padding chunk before `data`
    /// and puts the `data` header at exactly 4088..4096 — it fit into 4 KiB only barely, byte for
    /// byte. A slightly different `sourceFormatHint`, an extra chunk or a change of alignment in a
    /// new macOS would push `data` out of the window, and then **all** segments would become invalid
    /// at once: assembly would silently return nothing, and recovery — the whole point of writing
    /// this way — would find nothing at all. Reading 64 KiB once per segment is cheaper than such a
    /// breakdown.
    public static let headerProbeBytes = 65536

    /// What to do with a segment so that it makes it into the assembly.
    public enum Action: Equatable, Sendable {
        /// The header is complete — the file goes to `ffmpeg` as is.
        case include
        /// The header is unfinished, but there is audio in the file: repaired from the actual size.
        case repair(WAV.HeaderRepair)
    }

    /// A segment that made it into the plan, and what to do with it before assembly.
    public struct PlannedSegment: Equatable, Sendable {
        public let fileName: String
        public let action: Action

        public init(fileName: String, action: Action) {
            self.fileName = fileName
            self.action = action
        }
    }

    /// Assembly plan for a single track: the usable segments, sorted by number.
    ///
    /// - Parameters:
    ///   - names: file names from the track's directory (may contain junk — it gets filtered out).
    ///   - sizeByFileName: the size of each file in bytes (from the FS).
    ///   - headerByFileName: the first `headerProbeBytes` bytes of each file (from the FS). A file
    ///     whose header could not be read is dropped: there is nothing to confirm its integrity
    ///     with.
    /// - Returns: the segments in ascending order of number, each with its action.
    ///
    /// The only source of truth about what was actually recorded is the file system: `segment_count`
    /// from `session.json` does not reach here and must not — the marker is updated after the fact
    /// and lags behind on a crash, so trusting it would mean losing the whole recording (see
    /// Task 8.2).
    public static func recoveryPlan(fromFileNames names: [String],
                                    sizeByFileName: [String: Int],
                                    headerByFileName: [String: Data]) -> [PlannedSegment] {
        SegmentLayout.orderedSegments(fromFileNames: names)
            .map(\.fileName)
            .compactMap { name in
                let action = self.action(bytes: sizeByFileName[name] ?? 0,
                                         header: headerByFileName[name] ?? Data())
                return action.map { PlannedSegment(fileName: name, action: $0) }
            }
    }

    /// What to do with a segment: include it as is, repair its header, or discard it (`nil`).
    ///
    /// The order is deliberate: first try to accept the file, then to rescue it, and only if there
    /// is nothing to rescue — discard it. The former rule, "header unfinished → into the bin", cost
    /// us live audio: a `kill -9` leaves the last segment with sizes unset but with real seconds of
    /// audio inside (2.92 s in a live run), and the promise of "we lose at most one segment" was
    /// broken for no reason at all.
    public static func action(bytes: Int, header: Data) -> Action? {
        guard bytes >= minValidSegmentBytes else { return nil }
        if isFinalizedWAVHeader(header, fileSize: bytes) { return .include }
        return WAV.headerRepair(header: header, fileSize: bytes).map(Action.repair)
    }

    /// Whether a segment is usable for assembly — either on its own or after a header repair.
    public static func isUsableSegment(bytes: Int, header: Data) -> Bool {
        action(bytes: bytes, header: header) != nil
    }

    /// Whether a segment is valid **as is**: large enough and containing a finalised WAV header.
    ///
    /// Size alone is not enough: a `kill -9` in the middle of a segment leaves `AVAssetWriter` with
    /// a file holding kilobytes of audio but with the sizes in the header unset — `ffmpeg` crashes
    /// on such a file and drags the assembly of the whole track down with it. Such a segment is not
    /// discarded but repaired (`WAV.headerRepair`); hence this check only answers the question "is a
    /// repair needed".
    public static func isValidSegment(bytes: Int, header: Data) -> Bool {
        bytes >= minValidSegmentBytes && isFinalizedWAVHeader(header, fileSize: bytes)
    }

    /// Whether the WAV header was written through to the end: the RIFF/WAVE magic is in place, the
    /// `fmt `/`data` chunks were actually found, and the sizes are set and fit within the real file
    /// size.
    ///
    /// An unclosed segment is caught by the **size of the `data` chunk**: `AVAssetWriter` sets it
    /// only in `finishWriting`, so after a `kill -9` it is zero while megabytes of real audio follow
    /// (verified against a live writer). The RIFF-size check is a safety net here, not the primary
    /// signal: in a killed file that field keeps the size of the preamble (4088) — **less** than the
    /// file, so it passes.
    ///
    /// The `data` check deliberately says "fits" rather than "matches byte for byte": a header that
    /// declares **less** than the physical size is read by `ffmpeg` without errors (just without the
    /// tail), whereas requiring exact equality would send such a segment to a pointless repair that
    /// truncates the file.
    public static func isFinalizedWAVHeader(_ header: Data, fileSize: Int) -> Bool {
        // 36 is the minimum meaningful RIFF (fmt + empty data); larger than the file means the size
        // was never set.
        guard let riffSize = WAV.riffSize(header), riffSize >= 36, riffSize + 8 <= fileSize,
              let layout = WAV.layout(header) else { return false }
        return layout.declaredDataSize > 0
            && layout.dataBodyOffset + layout.declaredDataSize <= fileSize
    }

    /// Whether there is anything to recover: the session marker points at an interrupted recording.
    ///
    /// `recording` = the process never reached a clean stop (crash/restart). `done`/`recovered` are
    /// already finalised — there is no need to touch them.
    public static func needsRecovery(_ manifest: SessionManifest) -> Bool {
        manifest.status == .recording
    }
}
