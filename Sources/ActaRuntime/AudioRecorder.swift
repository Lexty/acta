import AVFoundation
import ActaKit
import os
@preconcurrency import ScreenCaptureKit

/// Meeting audio capture with a single `SCStream`: system audio (the other participants' voices) +
/// microphone.
///
/// Buffers arrive in the delegate with different types and formats (`SCStreamOutputType.audio` /
/// `.microphone`), so they are routed into **two separate** `SegmentWriter`s (`system/`, `mic/`) —
/// they cannot be written into a single container (see the `screencapturekit-audio` skill).
/// `.screen` frames are ignored: video is not needed, but an `SCContentFilter` is mandatory even
/// for audio-only.
///
/// `captureMicrophone` is available from macOS 15, hence the availability annotation on the whole
/// recorder.
@available(macOS 15.0, *)
public final class AudioRecorder: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "AudioRecorder")

    /// The recording folder — its subdirectories hold the segments of both tracks.
    private let directory: URL

    private let systemWriter: SegmentWriter
    private let micWriter: SegmentWriter

    // Separate serialized queues per track: the SegmentWriter's delegate needs no external
    // synchronization as long as a single queue drives it.
    private let systemQueue = DispatchQueue(label: "dev.personal.acta.audio.system")
    private let micQueue = DispatchQueue(label: "dev.personal.acta.audio.mic")
    private let screenQueue = DispatchQueue(label: "dev.personal.acta.audio.screen")

    // The current stream under a lock: `startStream()` sets it and `stop()`/`restart()` clear it
    // (the Swift concurrency pool), while the `didStopWithError` delegate does so from its own
    // ScreenCaptureKit queue; and the self-diagnosis reads it from a third one. Without the lock
    // this is a race for the reference: releasing the old stream in parallel with storing a new one
    // corrupts the retain count, and an unsynchronized read in the `===` check could see a stale
    // value and clear an already-restarted stream.
    private let streamLock = NSLock()
    private var currentStream: SCStream?

    private var activeStream: SCStream? {
        get { streamLock.lock(); defer { streamLock.unlock() }; return currentStream }
        set { streamLock.lock(); currentStream = newValue; streamLock.unlock() }
    }

    /// Clear the stream only if it is still the very same one — the check and the clearing happen
    /// under a single lock, otherwise `restart()` with its new stream could slip in between them.
    private func clearStream(ifIdentical stream: SCStream) {
        streamLock.lock()
        if currentStream === stream { currentStream = nil }
        streamLock.unlock()
    }

    // Counters of received buffers per track under a lock: the delegate is driven by different
    // queues (`systemQueue`/`micQueue`), while the self-diagnosis/watchdog reads them from yet
    // another one. We count the tracks separately so that the system audio flow does not mask a
    // dead microphone track (Task 4).
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
    /// `receivedBufferCounts` it confirms that the data reached the file, not just the delegate.
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

    /// Whether an `SCStream` is currently up (for the self-diagnosis snapshot).
    public var isStreaming: Bool { activeStream != nil }

    // Finalized segments per track under a lock: the writers fire the callback from their own queues
    // (`systemQueue`/`micQueue`), while `RecordingSession`'s counter reads it from a third one. The
    // arithmetic lives in the pure `SegmentProgress` (ActaKit); this is only the serialization.
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
    public init(directory: URL, segmentSeconds: Double = Double(SegmentLayout.defaultSegmentSeconds)) {
        self.directory = directory
        self.systemWriter = SegmentWriter(
            directory: directory.appendingPathComponent(SegmentLayout.systemDirName),
            segmentSeconds: segmentSeconds
        )
        self.micWriter = SegmentWriter(
            directory: directory.appendingPathComponent(SegmentLayout.micDirName),
            segmentSeconds: segmentSeconds
        )
        super.init()
        systemWriter.onSegmentFinalized = { [weak self] in self?.countFinalizedSegment(track: .system) }
        micWriter.onSegmentFinalized = { [weak self] in self?.countFinalizedSegment(track: .mic) }
    }

    /// Build the stream configuration. Extracted to keep the capture "magic" in one place.
    private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Minimal video config: we do not use the frames, but a display filter is mandatory.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return config
    }

    /// Start the capture. Throws a `StartupFailure` with ready-made text for the menu bar: the
    /// reason a start produced no recording is what the user must see, not an "error 1" from
    /// `localizedDescription`.
    public func start() async throws {
        try await requestPermissionsIfNeeded()
        do {
            try await startStream()
        } catch {
            // Raw ScreenCaptureKit errors are not let out: without `.streamNotStarted` the caller
            // cannot tell "the stream did not come up" (healed by a restart) from other failures,
            // and the self-healing (`SelfCheck`) would not spend its attempts (Task 4).
            log.error("Stream did not come up: \(error.localizedDescription, privacy: .public)")
            throw StartupFailure.streamNotStarted
        }
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw StartupFailure.streamNotStarted }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try await stream.startCapture()
        activeStream = stream
        log.info("Capture started")
    }

    /// Show the system TCC dialogs if the permissions have not been granted yet, and make sure they
    /// are there afterwards. Without an explicit request the first launch would silently hit a
    /// denial: an `SCStream` will not come up without the screen recording permission, and without
    /// the microphone only half the meeting gets recorded.
    ///
    /// On its first call `CGRequestScreenCaptureAccess` shows the dialog, but the permission only
    /// applies to the next launch of the process — so here we still fail with a hint saying "grant
    /// the permission and restart Acta".
    private func requestPermissionsIfNeeded() async throws {
        if !Permissions.hasScreenRecording {
            Permissions.requestScreenRecording()
            guard Permissions.hasScreenRecording else {
                log.error("No Screen Recording permission — start rejected")
                throw StartupFailure.noScreenRecordingPermission
            }
        }
        if Permissions.microphoneStatus == .notDetermined {
            _ = await Permissions.requestMicrophone()
        }
        guard Permissions.hasMicrophone else {
            log.error("No Microphone permission — start rejected")
            throw StartupFailure.noMicrophonePermission
        }
    }

    /// Restart the stream **keeping the segments already recorded** — for the self-healing
    /// (`SelfCheck`) and the watchdog. The current segments are finalized and stay valid, the track
    /// counters move forward, and a new `SCStream` is brought up.
    public func restart() async throws {
        if let stream = activeStream {
            try? await stream.stopCapture()
        }
        activeStream = nil
        systemQueue.sync { systemWriter.finishAndAdvance() }
        micQueue.sync { micWriter.finishAndAdvance() }
        log.info("Restarting stream")
        try await start()
    }

    /// Stop the capture and finalize the current segments of both tracks.
    public func stop() async {
        if let stream = activeStream {
            try? await stream.stopCapture()
        }
        activeStream = nil
        systemQueue.sync { systemWriter.finish() }
        micQueue.sync { micWriter.finish() }
        log.info("Capture stopped")
    }

    /// The number of finalized segments to publish in `session.json`. The arithmetic over the two
    /// tracks lives in the pure `SegmentProgress`; this only serializes the read.
    public var finalizedSegmentCount: Int {
        progressLock.lock()
        defer { progressLock.unlock() }
        return progress.segmentCount
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        switch type {
        case .audio:
            countBuffer(system: true)
            systemWriter.append(sampleBuffer)
        case .microphone:
            countBuffer(system: false)
            micWriter.append(sampleBuffer)
        default:
            break // .screen and the rest — ignored
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

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Stream stopped with an error: \(error.localizedDescription, privacy: .public)")
        // The stream is dead — drop it, otherwise `isStreaming` would keep showing the
        // self-diagnosis a live stream, and it would explain the failed capture to the user as a
        // broken audio device instead of the real cause. We check identity: while the error was
        // being delivered, `restart()` could have already stored a new stream, and clearing it here
        // would be a lie in the other direction.
        clearStream(ifIdentical: stream)
    }
}
