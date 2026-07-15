import AVFoundation
import ActaKit
import os

/// Streaming **segmented** recording of a single track to disk.
///
/// We write not one long file but short segments of about `SegmentLayout.defaultSegmentSeconds` s
/// (see the `crash-safe-recording` skill): every segment is a separate `AVAssetWriter` which, once
/// the interval elapses, is **finalized** (`finishWriting`) and becomes a valid WAV. A hard
/// crash/restart loses at most the last unclosed segment.
///
/// All methods are called from the serialized queue of the `SCStream` delegate (one per track), so
/// the internal state needs no additional synchronization.
final class SegmentWriter {
    /// The track's directory (for example `.../system`) where `NNNN.wav` files are written.
    private let directory: URL

    /// The rotation threshold in seconds.
    private let segmentSeconds: Double

    private let log: Logger

    /// Called when each segment is closed — from the track's queue, synchronously. This way
    /// `session.json` learns about a new segment exactly when it appears on disk (Task 8.2); the
    /// subscriber must not block the queue (writing the marker goes to its own queue, see
    /// `RecordingSession`), otherwise it would hang on the hot audio path.
    var onSegmentFinalized: (@Sendable () -> Void)?

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var segmentIndex = 0
    private var segmentStart: CMTime = .invalid

    /// Finalizations started by a rotation/restart that have not completed yet. A segment file is
    /// valid only after its completion handler has run, so `finish()` (before the assembly) waits
    /// for the whole group, not just for the current writer: otherwise a stop right after a rotation
    /// would hand `ffmpeg` a segment that is still being written.
    private let pendingWrites = DispatchGroup()

    // Counter of buffers accepted by the writer: written from the track's queue, read by the
    // self-diagnosis from another one — hence the lock. It is the "data really landed in a segment"
    // signal, not just "data arrived" (Task 4).
    private let appendedLock = NSLock()
    private var appended = 0
    private var dropped = 0

    /// How many buffers the writer has actually accepted into a segment since the recording started.
    var appendedCount: Int {
        appendedLock.lock()
        defer { appendedLock.unlock() }
        return appended
    }

    /// How many buffers were thrown away because the writer was not ready for them. Audio that never
    /// reached the file: without a counter a shortened track looks exactly like a quiet meeting.
    var droppedCount: Int {
        appendedLock.lock()
        defer { appendedLock.unlock() }
        return dropped
    }

    init(directory: URL, segmentSeconds: Double = Double(SegmentLayout.defaultSegmentSeconds)) {
        self.directory = directory
        self.segmentSeconds = segmentSeconds
        self.log = Logger(subsystem: AppInfo.bundleID, category: "SegmentWriter")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The segment URL for the current index.
    private func segmentURL(index: Int) -> URL {
        directory.appendingPathComponent(SegmentLayout.segmentFileName(index: index))
    }

    /// Write the next buffer. Opens the first segment on the first buffer, rotates by time.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return }

        if writer == nil {
            startSegment(at: pts, formatHint: CMSampleBufferGetFormatDescription(sampleBuffer))
        } else if CMTimeGetSeconds(CMTimeSubtract(pts, segmentStart)) >= segmentSeconds {
            rotate(at: pts, formatHint: CMSampleBufferGetFormatDescription(sampleBuffer))
        }

        guard let input, input.isReadyForMoreMediaData else {
            countDrop()
            return
        }
        guard input.append(sampleBuffer) else {
            log.error("Writer rejected a buffer: \(String(describing: self.writer?.error), privacy: .public)")
            return
        }
        appendedLock.lock()
        appended += 1
        appendedLock.unlock()
    }

    /// Account for a buffer the writer refused to take. Logged on the powers of two so that a long
    /// backpressure spell leaves a trace without flooding the log from the hot audio path.
    private func countDrop() {
        appendedLock.lock()
        dropped += 1
        let total = dropped
        appendedLock.unlock()
        if total & (total - 1) == 0 {
            log.error("Writer was not ready — buffer dropped (total dropped: \(total))")
        }
    }

    /// Finalize the current segment (a clean stop). After the call the writer is reset.
    ///
    /// We wait for **all** started finalizations (the current one and those left over from
    /// rotations): the segment assembly (`SegmentAssembler`) starts right after this call, and a
    /// file is valid only once its completion handler has run. Otherwise `ffmpeg` would read a
    /// segment that is still being written — the tail of the recording would be lost.
    func finish() {
        finalizeCurrent()
        // We wait with a cap: `finish()` is called synchronously from the track's queue inside
        // `stop()`, and a `finishWriting` hung inside AVFoundation would, without a timeout, jam the
        // stop forever — the UI would stay on "recording" with a button that does nothing any more
        // (`isStopping` would never clear). On timeout we move on: the segment is left with an
        // unfinalized header, which `Recovery.action` repairs from the actual file size — the tail
        // is rescued, not lost.
        if pendingWrites.wait(timeout: .now() + Self.finishTimeoutSeconds) == .timedOut {
            log.error("Segment finalization did not fit the timeout — continuing without it")
        }
    }

    /// The cap on waiting for segment finalization on stop, s. Comfortably longer than a normal
    /// flush (a fraction of a second): it should only fire on a writer that has genuinely hung.
    private static let finishTimeoutSeconds = 30.0

    /// Finalize the current segment and move on to the next index — for a stream restart by the
    /// watchdog (Task 4). Unlike `finish()`, it advances the counter so that after the restart the
    /// new stream writes into a new file and the already closed segment is **not overwritten**.
    /// There is no need to wait for the flush: recording continues, and the assembly only happens on
    /// a stop/recovery.
    func finishAndAdvance() {
        guard writer != nil else { return }
        finalizeCurrent()
        segmentIndex += 1
    }

    // MARK: - Private

    private func startSegment(at pts: CMTime, formatHint: CMFormatDescription?) {
        let url = segmentURL(index: segmentIndex)
        try? FileManager.default.removeItem(at: url)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.pcmOutputSettings,
                                           sourceFormatHint: formatHint)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                log.error("""
                    Failed to add an input to the writer for \
                    \(url.lastPathComponent, privacy: .public)
                    """)
                return
            }
            writer.add(input)
            guard writer.startWriting() else {
                log.error("startWriting failed: \(String(describing: writer.error), privacy: .public)")
                return
            }
            writer.startSession(atSourceTime: pts)
            self.writer = writer
            self.input = input
            self.segmentStart = pts
        } catch {
            let name = url.lastPathComponent
            log.error("""
                Failed to create segment \(name, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    private func rotate(at pts: CMTime, formatHint: CMFormatDescription?) {
        // Rotation on the hot recording path: we do not block the track's queue waiting for the
        // flush — the segment finishes being written in the background while the next one already
        // accepts buffers. The waiting is `finish()`'s job.
        finalizeCurrent()
        segmentIndex += 1
        startSegment(at: pts, formatHint: formatHint)
    }

    /// Close the current segment and start its finalization in the background, registering it in
    /// `pendingWrites` — so that `finish()` can wait for all of them before the assembly.
    private func finalizeCurrent() {
        guard let writer, let input else { return }
        self.writer = nil
        self.input = nil
        self.segmentStart = .invalid
        input.markAsFinished()
        // The completion handler arrives on AVFoundation's internal queue, not on our track's queue,
        // so waiting for the group in `finish()` does not deadlock.
        pendingWrites.enter()
        writer.finishWriting { [pendingWrites] in pendingWrites.leave() }
        onSegmentFinalized?()
    }

    /// Unified WAV/PCM settings: 48 kHz, stereo, 16 bit. We bring both tracks to the same format so
    /// that the segments can be assembled with `-c copy` without re-encoding.
    private static var pcmOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}
