import ActaKit
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// The one and only ScreenCaptureKit integration: a single `SCStream` producing system audio (the
/// other participants' voices) + microphone.
///
/// Buffers arrive with different types and formats (`SCStreamOutputType.audio` / `.microphone`) and
/// are forwarded as two separate tracks — they cannot be written into a single container (see the
/// `screencapturekit-audio` skill). `.screen` frames are ignored: video is not needed, but an
/// `SCContentFilter` is mandatory even for audio-only.
///
/// `captureMicrophone` is available from macOS 15, hence the availability annotation.
@available(macOS 15.0, *)
public final class SCKCaptureSource: NSObject, SCStreamDelegate, SCStreamOutput, CaptureSource,
                                     @unchecked Sendable {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "SCKCaptureSource")

    // Separate serialized queues per track: these are the ScreenCaptureKit sample-handler queues,
    // and the per-track serialization every consumer relies on is theirs. They are also what makes
    // the drain in `stop()` possible at all.
    private let systemQueue = DispatchQueue(label: "dev.personal.acta.audio.system")
    private let micQueue = DispatchQueue(label: "dev.personal.acta.audio.mic")
    private let screenQueue = DispatchQueue(label: "dev.personal.acta.audio.screen")

    // The current stream under a lock: `start()` sets it and `stop()` clears it (the Swift
    // concurrency pool), while the `didStopWithError` delegate does so from its own ScreenCaptureKit
    // queue; and the self-diagnosis reads it through `isStreaming` from a third one. Without the lock
    // this is a race for the reference: releasing the old stream in parallel with storing a new one
    // corrupts the retain count, and an unsynchronized read in the `===` check could see a stale
    // value and clear an already-restarted stream.
    private let streamLock = NSLock()
    private var currentStream: SCStream?

    // The handler is installed before `start()` and read from both sample-handler queues; the lock
    // is what makes that publication safe rather than merely likely. It also guards `isStopped`,
    // which every delivery is gated on — the two are read together, on the hot path, in one
    // acquisition.
    private let deliveryLock = NSLock()
    private var bufferHandler: (@Sendable (Track, CMSampleBuffer) -> Void)?
    /// Closed between `stop()` and the next `start()`. See `stop()`: the drain alone does **not**
    /// deliver the contract, and this flag is the other half of it.
    private var isStopped = true

    private var activeStream: SCStream? {
        get { streamLock.lock(); defer { streamLock.unlock() }; return currentStream }
        set { streamLock.lock(); currentStream = newValue; streamLock.unlock() }
    }

    /// Clear the stream only if it is still the very same one — the check and the clearing happen
    /// under a single lock, otherwise a restart with its new stream could slip in between them.
    private func clearStream(ifIdentical stream: SCStream) {
        streamLock.lock()
        if currentStream === stream { currentStream = nil }
        streamLock.unlock()
    }

    /// Whether an `SCStream` is currently up (for the self-diagnosis snapshot).
    public var isStreaming: Bool { activeStream != nil }

    public func setBufferHandler(_ handler: @escaping @Sendable (Track, CMSampleBuffer) -> Void) {
        deliveryLock.lock()
        bufferHandler = handler
        deliveryLock.unlock()
    }

    /// Open or close the delivery gate. A separate non-async method on purpose: `NSLock` is
    /// unavailable from an asynchronous context, and `start()`/`stop()` are async.
    private func setStopped(_ stopped: Bool) {
        deliveryLock.lock()
        isStopped = stopped
        deliveryLock.unlock()
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

    /// Bring the stream up. Raw ScreenCaptureKit errors are not let out: without `.streamNotStarted`
    /// the caller cannot tell "the stream did not come up" (healed by a restart) from other failures,
    /// and the self-healing (`SelfCheck`) would not spend its attempts (Task 4).
    public func start() async throws {
        // Declared outside the `do`, so the catch can still reach a stream that `startCapture()`
        // brought partway up before throwing. Assigning `activeStream` only after a successful start
        // would otherwise orphan it: `stop()` finds `nil` and never calls `stopCapture()` on it.
        var created: SCStream?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                               onScreenWindowsOnly: false)
            guard let display = content.displays.first else { throw StartupFailure.streamNotStarted }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
            created = stream
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
            // Open the gate before the first buffer can exist, so a start never drops one.
            setStopped(false)
            try await stream.startCapture()
            activeStream = stream
            log.info("Capture started")
        } catch {
            log.error("Stream creation failed: \(error.localizedDescription, privacy: .public)")
            // Both halves matter, and neither is optional. The gate: it was opened above before
            // `startCapture()`, and a failed start must leave it shut — otherwise a buffer from a
            // stream that reported failure still reaches `AudioRecorder`, and on the `restart()` path
            // it lands in a writer being finalized, which is the tail-loss the gate exists to
            // prevent. The teardown: the stream never became `activeStream`, so nothing else will
            // ever stop it.
            setStopped(true)
            if let created { try? await created.stopCapture() }
            throw StartupFailure.streamNotStarted
        }
    }

    /// Stop the stream, guaranteeing **no delivery after an awaited `stop()`** — the contract
    /// `AudioRecorder` composes on top of when it finalizes its writers straight after this call.
    ///
    /// The guarantee takes **two** steps, and a drain alone is not enough. `stopCapture()` does not
    /// stop the callbacks: ScreenCaptureKit still delivers stragglers after it returns (that is the
    /// very buffer `SegmentWriter.isFinished` was written for). So:
    ///
    /// 1. **close the gate** — every later callback finds `isStopped` and delivers nothing;
    /// 2. **drain** — `sync` onto each sample-handler queue, which returns only once the callback
    ///    that was already in flight has finished. Such a callback read the gate as open and *is*
    ///    delivering; waiting it out is what makes the guarantee hold for it too.
    ///
    /// The order matters and is not interchangeable: draining first would leave the window between
    /// the drain and the gate wide open, and a straggler landing in it would append into a writer
    /// that `AudioRecorder` is concurrently finalizing — deleting the segment being closed. That is
    /// precisely the tail-loss `isFinished` describes, and it used to be prevented by finalizing
    /// *on* these queues.
    public func stop() async {
        if let stream = activeStream {
            try? await stream.stopCapture()
        }
        activeStream = nil
        setStopped(true)
        systemQueue.sync {}
        micQueue.sync {}
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        switch type {
        case .audio:
            deliver(.system, sampleBuffer)
        case .microphone:
            deliver(.mic, sampleBuffer)
        default:
            break // .screen and the rest — ignored
        }
    }

    /// Forward the buffer synchronously, on the sample-handler queue we were called on: an extra
    /// asynchronous hop here would put the buffer outside the queue that `stop()` drains, and the
    /// no-delivery-after-stop guarantee would quietly stop holding.
    ///
    /// The gate is read in the same acquisition as the handler, and the handler runs outside the
    /// lock — holding it across the append would serialize the two tracks against each other.
    private func deliver(_ track: Track, _ buffer: CMSampleBuffer) {
        deliveryLock.lock()
        let handler = isStopped ? nil : bufferHandler
        deliveryLock.unlock()
        handler?(track, buffer)
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Stream stopped with an error: \(error.localizedDescription, privacy: .public)")
        // The stream is dead — drop it, otherwise `isStreaming` would keep showing the
        // self-diagnosis a live stream, and it would explain the failed capture to the user as a
        // broken audio device instead of the real cause. We check identity: while the error was
        // being delivered, a restart could have already stored a new stream, and clearing it here
        // would be a lie in the other direction.
        clearStream(ifIdentical: stream)
    }
}
