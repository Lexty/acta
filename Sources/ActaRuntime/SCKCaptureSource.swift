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

    // The current stream under a lock: `start()` sets it and `stop()` takes it (the Swift concurrency
    // pool), while the `didStopWithError` delegate clears it from its own ScreenCaptureKit queue; and
    // the self-diagnosis reads it through `isStreaming` from a third one. Without the lock
    // this is a race for the reference: releasing the old stream in parallel with storing a new one
    // corrupts the retain count, and an unsynchronized read in the `===` check could see a stale
    // value and clear an already-restarted stream.
    private let streamLock = NSLock()
    private var currentStream: SCStream?
    /// Streams that are no longer current but are still owed a microphone teardown. `didStopWithError`
    /// drops a dead stream to keep `isStreaming` honest, but under this file's own premise — the tap
    /// outlives `stopCapture()` and even the process — dropping the reference does **not** release the
    /// microphone. Without this slot the watchdog path leaks a tap per restart: the stream errors out,
    /// `restart()` calls `stop()`, `stop()` finds nothing to disable, and `start()` opens a second
    /// mic-on stream. An array rather than one slot so a second error can never overwrite a pending
    /// teardown, even though today's single-stream-at-a-time invariant makes that unreachable.
    private var streamsAwaitingTeardown: [SCStream] = []

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
    ///
    /// The cleared stream is handed to `streamsAwaitingTeardown` rather than simply dropped: it is dead
    /// as far as `isStreaming` is concerned, but its microphone tap is not, and only `stop()` can
    /// dismantle that.
    private func clearStream(ifIdentical stream: SCStream) {
        streamLock.lock()
        if currentStream === stream {
            currentStream = nil
            streamsAwaitingTeardown.append(stream)
        }
        streamLock.unlock()
    }

    /// Take every stream this source still owes a microphone teardown — the current one plus anything
    /// `didStopWithError` set aside — and disown them all in one acquisition.
    ///
    /// Taking and clearing under a single lock is what the old `activeStream = nil` could not do across
    /// the teardown's two suspension points: a restart storing a new stream mid-teardown would have had
    /// its stream cleared out from under it. The returned array is what keeps each stream alive through
    /// the awaits that follow.
    private func takeStreamsForTeardown() -> [SCStream] {
        streamLock.lock()
        defer { streamLock.unlock() }
        var streams = streamsAwaitingTeardown
        streamsAwaitingTeardown.removeAll()
        if let currentStream {
            streams.append(currentStream)
            self.currentStream = nil
        }
        return streams
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
    ///
    /// The microphone flag is a parameter because the teardown re-applies this configuration with the
    /// microphone off (see `stop()`). `updateConfiguration` **replaces** the configuration rather than
    /// merging into it, so the mic-off variant must be this same complete object with one field
    /// flipped — a bare `SCStreamConfiguration()` with only `captureMicrophone = false` would silently
    /// drop the sample rate, the channel count and the audio capture itself.
    private func makeConfiguration(captureMicrophone: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = captureMicrophone
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
            let stream = SCStream(filter: filter,
                                  configuration: makeConfiguration(captureMicrophone: true),
                                  delegate: self)
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
            // All three halves matter, and none is optional. The gate: it was opened above before
            // `startCapture()`, and a failed start must leave it shut — otherwise a buffer from a
            // stream that reported failure still reaches `AudioRecorder`, and on the `restart()` path
            // it lands in a writer being finalized, which is the tail-loss the gate exists to
            // prevent. The teardown: the stream never became `activeStream`, so nothing else will
            // ever stop it. The drain: for the same reason `stop()` needs one — closing the gate
            // stops *later* callbacks, but a callback that read the gate as open before it shut is
            // delivering right now, so a `start()` that threw would otherwise return with a delivery
            // still in flight. Same order as `stop()`, and for the same reason: gate first, drain
            // second.
            setStopped(true)
            // The same teardown as `stop()`, and for the same reason: a partially-started stream may
            // already own the microphone tap, and nothing else will ever stop this stream. The mic-off
            // update may legitimately fail on a stream whose `startCapture()` never reached a running
            // state — `disableMicrophone` logs that and moves on, so the cleanup failure never
            // obscures the start failure below.
            if let created {
                await disableMicrophone(on: created)
                await stopCapture(created)
            }
            drainSampleHandlerQueues()
            throw StartupFailure.streamNotStarted
        }
    }

    /// Disable the microphone on a live stream, awaited. This is the actual mitigation: `stopCapture()`
    /// alone does not appear to dismantle the macOS 26 ScreenCaptureKit microphone tap (the indicator
    /// and Control Center's attribution to Acta survive even process exit), and the configuration is
    /// the API-level state that says whether the mic is captured. So we turn it off while the stream is
    /// still alive, *then* stop.
    ///
    /// Its own `do`/`catch`, never combined with `stopCapture()`'s: a failure here must not skip the
    /// stop. Nothing is propagated — `stop()` is non-throwing by contract — but every failure is logged
    /// distinctly, because the log is how this bug was found in the first place.
    private func disableMicrophone(on stream: SCStream) async {
        do {
            try await stream.updateConfiguration(makeConfiguration(captureMicrophone: false))
        } catch {
            log.error("Disabling the microphone failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopCapture(_ stream: SCStream) async {
        do {
            try await stream.stopCapture()
        } catch {
            log.error("Stopping the capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Wait out any callback already in flight on the sample-handler queues. All three, including
    /// `screenQueue`: it delivers nothing, but the drain is about the queues the framework calls us
    /// on, not about the tracks we forward.
    ///
    /// ⚠️ Must never run on one of these queues — a synchronous drain of the queue you are on
    /// deadlocks. Both callers reach here from `AudioRecorder`'s serialized context (the Swift
    /// concurrency pool), never from a sample handler; keep it that way.
    private func drainSampleHandlerQueues() {
        systemQueue.sync {}
        micQueue.sync {}
        screenQueue.sync {}
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
    ///
    /// Between the two steps sits the microphone teardown: for **every** stream still owed one — the
    /// current stream and any that `didStopWithError` set aside — the mic is disabled on the stream and
    /// awaited **before** its `stopCapture()` (see `disableMicrophone(on:)`). The array returned by
    /// `takeStreamsForTeardown()` retains each stream across both awaits, so none is released until its
    /// teardown has run.
    public func stop() async {
        // Gate first, before touching the stream: everything below is asynchronous, and every moment
        // the gate is open past this point is a moment a straggler can reach a writer being finalized.
        setStopped(true)
        for stream in takeStreamsForTeardown() {
            await disableMicrophone(on: stream)
            await stopCapture(stream)
        }
        // Unconditional, including the no-stream path: `didStopWithError` clears the stream from its
        // own queue while leaving the gate open, so a delivery that observed the open gate can be in
        // flight even when there is nothing left to stop. Returning without the drain would break the
        // guarantee exactly there.
        drainSampleHandlerQueues()
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
