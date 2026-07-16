import ActaKit
import CoreMedia

/// The capture seam: everything `AudioRecorder` needs from the audio capture below it, and nothing
/// else. It owns **only the capture lifecycle and buffer production** — it knows nothing about
/// writers, segments or permissions.
///
/// The contract, honoured by every implementation (a fake that breaks any of it is worse than no
/// fake at all):
///
/// - the buffer handler is installed **before** `start()`;
/// - **no delivery after an awaited `stop()`**, and it takes two halves: `stop()` must both stop
///   delivering *and* not return until the callback already in flight has finished. Draining alone
///   is not enough — a source whose underlying machinery can still call back after the drain (the
///   real one can: `SCStream.stopCapture()` does not stop the callbacks) would deliver into a writer
///   the caller is already finalizing. See `SCKCaptureSource.stop()`, where both halves are produced;
/// - delivery is **ordered per track**, and each track has its own serial queue: the handler is
///   called synchronously on it, so the two tracks can be delivered simultaneously;
/// - `isStreaming` reflects the source's **actual** state, including a failure that arrives
///   asynchronously after `start()` has already returned — not merely whether `start()` threw.
///
/// There is deliberately **no `restart()`**. Restart is `AudioRecorder`'s composition (stop → finalize
/// both writers → start), and it cannot be pushed down here: the source knows nothing about the
/// writers, and either order it could pick on its own is wrong — finalize-then-restart lets old
/// queued callbacks append after finalisation, restart-first lets the replacement deliver before the
/// writers have advanced.
@available(macOS 15.0, *)
public protocol CaptureSource: AnyObject, Sendable {
    /// Whether capture is currently up.
    var isStreaming: Bool { get }

    /// Install the buffer handler. Must be called before `start()`; the handler is invoked
    /// synchronously on the track's own serial queue.
    func setBufferHandler(_ handler: @escaping @Sendable (Track, CMSampleBuffer) -> Void)

    /// Bring the capture up. Failures inside capture creation surface as
    /// `StartupFailure.streamNotStarted`, which is what lets `SelfCheck` spend its restart attempts.
    func start() async throws

    /// Tear the capture down: stop delivering, and do not return until the callback already in
    /// flight has finished. After an awaited `stop()` the handler must not be called again.
    func stop() async
}
