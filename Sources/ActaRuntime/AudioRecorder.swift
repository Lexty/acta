import AVFoundation
import ActaKit
import CoreMedia
import os

/// Meeting audio recording: it takes the two capture tracks a `CaptureSource` produces — system audio
/// (the other participants' voices) and microphone — and routes them into **two separate**
/// `SegmentWriter`s (`system/`, `mic/`), counting what arrived and what was actually written.
///
/// The capture itself lives behind `CaptureSource` (`SCKCaptureSource` in production), so this class
/// knows nothing about how buffers are produced. What it does own is the composition the source
/// cannot: permissions, the writers, and `restart()`.
///
/// Buffers arrive on the source's per-track queues and are appended on that very callback, with no
/// hop of its own — the per-track serialization the writers need is the source's, which is exactly
/// why `CaptureSource.stop()` must drain before it returns.
///
/// `captureMicrophone` is available from macOS 15, hence the availability annotation on the whole
/// recorder.
@available(macOS 15.0, *)
public final class AudioRecorder: @unchecked Sendable {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "AudioRecorder")

    /// The recording folder — its subdirectories hold the segments of both tracks.
    private let directory: URL

    private let source: CaptureSource
    private let permissions: PermissionChecking

    private let systemWriter: SegmentWriter
    private let micWriter: SegmentWriter

    // Counters of received buffers per track under a lock: the buffer handler is driven by the
    // source's two queues, while the self-diagnosis/watchdog reads them from yet another one. We
    // count the tracks separately so that the system audio flow does not mask a dead microphone
    // track (Task 4).
    private let bufferCountLock = NSLock()
    private var receivedSystemBuffers = 0
    private var receivedMicBuffers = 0

    /// How many audio buffers have arrived from the system since the start, per track.
    public var receivedBufferCounts: (system: Int, mic: Int) {
        bufferCountLock.lock()
        defer { bufferCountLock.unlock() }
        return (receivedSystemBuffers, receivedMicBuffers)
    }

    /// How many buffers the writers actually accepted into segments, per track. Unlike
    /// `receivedBufferCounts` it confirms that the data reached the file, not just the handler.
    public var writtenBufferCounts: (system: Int, mic: Int) {
        (systemWriter.appendedCount, micWriter.appendedCount)
    }

    /// Total size of both tracks' segments on disk, bytes. A second signal for the self-diagnosis
    /// (independent of the writer): the files are growing → data really is landing on disk.
    public var segmentBytesOnDisk: Int {
        [SegmentLayout.systemDirName, SegmentLayout.micDirName]
            .map { Self.directorySize(directory.appendingPathComponent($0)) }
            .reduce(0, +)
    }

    private static func directorySize(_ url: URL) -> Int {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
        return names.reduce(0) { total, name in
            let attrs = try? manager.attributesOfItem(atPath: url.appendingPathComponent(name).path)
            return total + ((attrs?[.size] as? Int) ?? 0)
        }
    }

    /// Whether the capture is currently up (for the self-diagnosis snapshot). The source's actual
    /// state, not a flag of our own: an asynchronous failure must be visible here too.
    public var isStreaming: Bool { source.isStreaming }

    // Finalized segments per track under a lock: the writers fire the callback from the source's
    // per-track queues, while `RecordingSession`'s counter reads it from a third one. The arithmetic
    // lives in the pure `SegmentProgress` (ActaKit); this is only the serialization.
    private let progressLock = NSLock()
    private var progress = SegmentProgress()
    private var onSegmentCountChange: (@Sendable (Int) -> Void)?

    /// Subscribe to changes in the number of finalized segments — `session.json` is updated on this
    /// signal (Task 8.2). The subscriber is called from the track's queue: it must not block it.
    /// The subscription must be set up before `start()`.
    public func setSegmentCountObserver(_ observer: @escaping @Sendable (Int) -> Void) {
        progressLock.lock()
        onSegmentCountChange = observer
        progressLock.unlock()
    }

    /// Account for a finalized segment of a track and, if the total counter moved, notify the
    /// subscriber.
    private func countFinalizedSegment(track: SegmentProgress.Track) {
        progressLock.lock()
        let changed = progress.recordFinalizedSegment(track: track)
        let count = progress.segmentCount
        let observer = onSegmentCountChange
        progressLock.unlock()
        guard changed else { return }
        observer?(count)
    }

    /// - Parameter directory: the recording folder; segments are written into its `system/` and
    ///   `mic/` subdirectories.
    /// - Parameter source: where the buffers come from.
    /// - Parameter permissions: who answers the TCC questions.
    ///
    /// Neither has a default: what production passes is claimed once, in `RecordingDependencies.live`,
    /// where a test can assert it. A default argument here would restate that claim in a form no test
    /// can reach — you cannot ask a function what it *would* have passed.
    public init(directory: URL,
                segmentSeconds: Double = Double(SegmentLayout.defaultSegmentSeconds),
                source: CaptureSource,
                permissions: PermissionChecking) {
        self.directory = directory
        self.source = source
        self.permissions = permissions
        self.systemWriter = SegmentWriter(
            directory: directory.appendingPathComponent(SegmentLayout.systemDirName),
            segmentSeconds: segmentSeconds
        )
        self.micWriter = SegmentWriter(
            directory: directory.appendingPathComponent(SegmentLayout.micDirName),
            segmentSeconds: segmentSeconds
        )
        systemWriter.onSegmentFinalized = { [weak self] in self?.countFinalizedSegment(track: .system) }
        micWriter.onSegmentFinalized = { [weak self] in self?.countFinalizedSegment(track: .mic) }
        // Installed here, and not in `start()`: the contract is that the handler is in place before
        // the source can produce anything.
        source.setBufferHandler { [weak self] track, buffer in self?.append(track, buffer) }
    }

    /// Start the capture. Throws a `StartupFailure` with ready-made text for the menu bar: the
    /// reason a start produced no recording is what the user must see, not an "error 1" from
    /// `localizedDescription`.
    public func start() async throws {
        try await requestPermissionsIfNeeded()
        do {
            try await source.start()
        } catch {
            // Raw capture errors are not let out: without `.streamNotStarted` the caller cannot tell
            // "the stream did not come up" (healed by a restart) from other failures, and the
            // self-healing (`SelfCheck`) would not spend its attempts (Task 4).
            log.error("Stream did not come up: \(error.localizedDescription, privacy: .public)")
            throw StartupFailure.streamNotStarted
        }
    }

    /// Show the system TCC dialogs if the permissions have not been granted yet, and make sure they
    /// are there afterwards. Without an explicit request the first launch would silently hit a
    /// denial: the capture will not come up without the screen recording permission, and without
    /// the microphone only half the meeting gets recorded.
    ///
    /// This stays here rather than in the source: the source produces buffers, it does not decide
    /// whether it is allowed to. Every restart re-checks, because `restart()` ends in `start()`.
    ///
    /// The first screen-recording request shows the dialog, but the permission it grants only applies
    /// to the **next launch** of the process (see `SystemPermissions`) — so even a user who agrees
    /// cannot record now, and this start still fails, with a hint saying "grant the permission and
    /// restart Acta".
    private func requestPermissionsIfNeeded() async throws {
        if !permissions.hasScreenRecording {
            permissions.requestScreenRecording()
            guard permissions.hasScreenRecording else {
                log.error("No Screen Recording permission — start rejected")
                throw StartupFailure.noScreenRecordingPermission
            }
        }
        if permissions.microphoneStatus == .notDetermined {
            _ = await permissions.requestMicrophone()
        }
        guard permissions.hasMicrophone else {
            log.error("No Microphone permission — start rejected")
            throw StartupFailure.noMicrophonePermission
        }
    }

    /// Restart the capture **keeping the segments already recorded** — for the self-healing
    /// (`SelfCheck`) and the watchdog. The current segments are finalized and stay valid, the track
    /// counters move forward, and a fresh capture is brought up.
    ///
    /// The order is the whole point and must not be rearranged. By the `CaptureSource` contract an
    /// awaited `stop()` delivers nothing further, so no callback can append while the writers
    /// advance; and advancing them before the new capture exists means nothing can be appended into
    /// a segment that is being finalized. It ends in `self.start()`, not `source.start()`, because
    /// that is what re-checks the permissions.
    public func restart() async throws {
        await source.stop()
        systemWriter.finishAndAdvance()
        micWriter.finishAndAdvance()
        log.info("Restarting stream")
        try await start()
    }

    /// Stop the capture and finalize the current segments of both tracks. Safe by the same argument
    /// as `restart()`: after an awaited `stop()` the source delivers nothing more, so no buffer can
    /// land in a writer that is being finalized — which would delete the very tail being closed.
    public func stop() async {
        await source.stop()
        systemWriter.finish()
        micWriter.finish()
        log.info("Capture stopped")
    }

    /// The number of finalized segments to publish in `session.json`. The arithmetic over the two
    /// tracks lives in the pure `SegmentProgress`; this only serializes the read.
    public var finalizedSegmentCount: Int {
        progressLock.lock()
        defer { progressLock.unlock() }
        return progress.segmentCount
    }

    // MARK: - Buffers

    /// Called synchronously on the source's per-track queue.
    private func append(_ track: Track, _ buffer: CMSampleBuffer) {
        switch track {
        case .system:
            countBuffer(system: true)
            systemWriter.append(buffer)
        case .mic:
            countBuffer(system: false)
            micWriter.append(buffer)
        }
    }

    private func countBuffer(system: Bool) {
        bufferCountLock.lock()
        if system {
            receivedSystemBuffers += 1
        } else {
            receivedMicBuffers += 1
        }
        bufferCountLock.unlock()
    }
}
