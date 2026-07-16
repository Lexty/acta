import AVFoundation
import ActaKit
import ActaRuntime
import CoreMedia
import Foundation

/// Carries a `CMSampleBuffer` to a track queue. `CMSampleBuffer` is not `Sendable`, but the hand-off
/// is the same one ScreenCaptureKit makes to `SCKCaptureSource`'s sample-handler queue: the buffer is
/// created here, handed over exactly once, and never touched again on this side. The box states that
/// where the compiler can check the shape of it, rather than leaving a warning to be read past.
private struct BufferBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

// The seams Task B injects, driven from the test side: a scripted capture source, a permission
// answerer that shows no dialog, and a clock that makes the self-diagnosis instant without making it
// meaningless.

// MARK: - Fake capture source

/// A deliberately dumb `CaptureSource`: it emits a fixed batch of buffers when told to, and that is
/// all. Dumb on purpose — a fake with a scheduler inside it drifts into being a second, unverified
/// implementation of the thing under test, and the arbitrary-cadence version of this is parked
/// oracle work.
///
/// What it can be scripted to do, and nothing more: emit N buffers per track on `start()`, emit
/// another batch when the test (or the clock) says so, go silent, and fail chosen `start()` calls.
///
/// **The two tracks are delivered from distinct serial queues, and that is the point.** The likeliest
/// way a fake diverges from `SCKCaptureSource` is not the bytes in the buffers — it is callback
/// concurrency. A fake calling back inline from the test thread could never expose simultaneous
/// system/mic delivery, a `stop()` racing an already-queued callback, or an old failure arriving
/// after a restart. So this one owes the same guarantee the real source owes: per-track serial
/// queues, a delivery gate, and a `stop()` that drains before it returns.
@available(macOS 15.0, *)
final class FakeCaptureSource: CaptureSource, @unchecked Sendable {
    private let systemQueue = DispatchQueue(label: "dev.personal.acta.test.fake.system")
    private let micQueue = DispatchQueue(label: "dev.personal.acta.test.fake.mic")

    private let lock = NSLock()
    /// Held for the whole of `enqueueBatch`, so `freezeEmission()` can wait out a batch that is
    /// already under way rather than only turning the next one away. `lock` is always taken *inside*
    /// it, never the other way round.
    private let emissionLock = NSLock()
    private var handler: (@Sendable (Track, CMSampleBuffer) -> Void)?
    /// Closed between `stop()` and the next `start()` — the other half of the no-delivery-after-stop
    /// guarantee, exactly as in `SCKCaptureSource`.
    private var isStopped = true
    private var streaming = false
    private var silentUntilRestart = false
    private var silencedTracks: Set<Track> = []
    /// The next frame index per track: presentation timestamps are derived from it, so the buffers
    /// of a track are contiguous and monotonic — which is what makes segment rotation happen for the
    /// reason it happens in production (elapsed media time) rather than by accident.
    private var nextFrame: [Track: Int64] = [.system: 0, .mic: 0]
    private var starts = 0
    private var stops = 0
    private var failEveryStart = false
    /// Stands in for `SCKCaptureSource`'s `currentStream`: every successful `start()` mints a new
    /// identity, and `stop()` drops it. It exists so the identity guarantee is testable — a delayed
    /// failure from a stream that a restart has already replaced must not take the replacement down
    /// with it.
    private var currentStream = 0
    private var format: FixtureAudioFormat = .stereo48k
    private var emitOnStart = true
    /// Whether the emitted buffers carry `PositionEncodedAudio` rather than silence.
    private var positionEncoded = false
    /// Set by `freezeEmission()`: nothing is enqueued again, so `emittedFrames` stops moving.
    private var frozen = false
    /// Audio to lose on purpose, and how many buffers each track has produced so far — the counter
    /// exists only to locate the fault.
    private var fault: Harness.Fault?
    private var emittedBuffers: [Track: Int] = [.system: 0, .mic: 0]

    /// One second of 48 kHz audio per buffer, so a buffer's presentation timestamp advances by a
    /// second — enough for a handful of them to cross a segment boundary without a test having to
    /// fabricate a gap in the media timeline. Three per batch per track.
    private let framesPerBuffer: AVAudioFrameCount = 48_000
    private let batchSize = 3

    // MARK: Script

    /// Every `start()` fails with `.streamNotStarted`.
    func failAllStarts() { withLock { failEveryStart = true } }
    /// Whether `start()` emits a batch of its own.
    func setEmitOnStart(_ emit: Bool) { withLock { emitOnStart = emit } }
    /// The audio format of the emitted buffers.
    func setFormat(_ newFormat: FixtureAudioFormat) { withLock { format = newFormat } }
    /// Fill the emitted buffers with `PositionEncodedAudio` instead of silence, so that a frame lost
    /// anywhere below can be named afterwards. Off by default: every existing scenario counts
    /// buffers rather than reading them, and silence is the cheaper fixture.
    func encodePositions() { withLock { positionEncoded = true } }

    /// Lose `fault.frames` frames of audio on both tracks, just before the buffer at
    /// `fault.bufferIndex` — the fault the negative control exists to have the oracle catch.
    ///
    /// A *real* loss, not a mislabelled one: the buffer at that index is delivered short and starting
    /// late, in content and in presentation timestamp alike, and every buffer after it keeps the
    /// position it would have had anyway. So the hole is exactly `frames` wide, it sits at a frame
    /// index the caller can predict, and `emittedFrames` still bounds the track from above.
    ///
    /// Off unless asked for, like `encodePositions()`: a source that could silently drop audio in
    /// every scenario would make every other suite's counts a matter of trust.
    func drop(_ fault: Harness.Fault) { withLock { self.fault = fault } }

    /// Stop producing audio for good — no `start()`, batch or restart enqueues anything again — and
    /// do not return until any batch already in flight has finished.
    ///
    /// What makes `emittedFrames` an *upper bound* rather than a moving target. A harness that means
    /// to crash this process has to know exactly how much audio existed at the moment it did, and
    /// while anything can still emit, the number it reads is already stale.
    ///
    /// ⚠️ **Waiting out the batch in flight is the whole of the guarantee, and leaving it out looked
    /// fine for a long time.** Emission is driven from several tasks — the child's own loop, `start()`
    /// and the startup probe's clock handler — so a flag that only turns *new* batches away still lets
    /// one that is already past the check advance `nextFrame` afterwards. The count then goes out
    /// stale, and frames reach the disk that it never covered: a recovered track legitimately longer
    /// than its own ceiling, roughly one run in ten. Only the frame-level oracle could see it — a
    /// buffer count would have agreed with itself either way.
    func freezeEmission() {
        emissionLock.lock()
        defer { emissionLock.unlock() }
        withLock { frozen = true }
    }

    /// The absolute frame index the next buffer of each track would start at — that is, how many
    /// frames this source has produced per track. Read it after `freezeEmission()`; before that it
    /// is a number that was true a moment ago.
    var emittedFrames: [Track: Int] {
        withLock { nextFrame.mapValues { Int($0) } }
    }

    /// This track stops producing audio; the other one carries on. A restart does not heal it — a
    /// dead capture device stays dead, which is what tells this apart from `goSilentUntilRestart()`.
    func silence(_ track: Track) { withLock { _ = silencedTracks.insert(track) } }

    /// The stream dies: nothing is delivered until it is brought back up. A restart is exactly what
    /// heals it, so `start()` clears the flag — which is what makes the watchdog test deterministic
    /// instead of a race against the next tick.
    func goSilentUntilRestart() { withLock { silentUntilRestart = true } }

    /// The identity of the stream `start()` most recently brought up (0 when there is none).
    var currentStreamToken: Int { withLock { currentStream } }

    /// A failure arriving asynchronously from the stream identified by `token`, after `start()` has
    /// long returned — the real source's `didStopWithError`. It kills that stream and only that one:
    /// a straggler from a stream a restart already replaced must leave the replacement alone,
    /// exactly as `clearStream(ifIdentical:)` guarantees.
    /// The gate is deliberately left open, exactly as `SCKCaptureSource.stream(_:didStopWithError:)`
    /// leaves it: an asynchronous failure drops the stream so `isStreaming` stops lying, and nothing
    /// more. Closing it here would make the fake promise a guarantee the shipped source does not.
    func failStream(_ token: Int) {
        withLock {
            guard currentStream == token else { return }
            currentStream = 0
            streaming = false
        }
    }

    /// The current stream fails asynchronously. `isStreaming` must tell the truth about it.
    func failStreamAsynchronously() { failStream(currentStreamToken) }

    // MARK: Observations

    var startCount: Int { withLock { starts } }
    var stopCount: Int { withLock { stops } }

    // MARK: CaptureSource

    var isStreaming: Bool { withLock { streaming } }

    func setBufferHandler(_ handler: @escaping @Sendable (Track, CMSampleBuffer) -> Void) {
        withLock { self.handler = handler }
    }

    func start() async throws {
        // The gate stays shut on a failed start, which is what `SCKCaptureSource` guarantees too —
        // it opens its own gate before `startCapture()` and closes it again if that throws.
        let shouldFail: Bool = withLock {
            starts += 1
            return failEveryStart
        }
        if shouldFail {
            withLock { isStopped = true }
            throw StartupFailure.streamNotStarted
        }
        let emit: Bool = withLock {
            isStopped = false
            streaming = true
            silentUntilRestart = false
            currentStream = starts
            return emitOnStart
        }
        if emit { emitBatch() }
    }

    func stop() async {
        withLock {
            stops += 1
            streaming = false
            isStopped = true
            currentStream = 0
        }
        drain()
    }

    // MARK: Emission

    /// Enqueue a batch on both live tracks and wait until it has been delivered. The waiting is what
    /// makes a test able to say "the source has produced this much" without polling.
    func emitBatch() {
        enqueueBatch()
        drain()
    }

    /// Enqueue a batch without waiting for it — for the tests that need a delivery in flight while
    /// `stop()` is called.
    func enqueueBatch(count: Int? = nil) {
        // Held across the whole batch, not just the decision to emit one: `freezeEmission()` waits on
        // exactly this, and a batch that could still be enqueuing after it returned would put frames
        // on disk that the published count does not know about.
        emissionLock.lock()
        defer { emissionLock.unlock() }
        let (size, live, fmt, frames, encoded) = withLock {
            (count ?? batchSize,
             (silentUntilRestart || frozen) ? [] : Track.allCases.filter { !silencedTracks.contains($0) },
             format,
             framesPerBuffer,
             positionEncoded)
        }
        guard size > 0 else { return }
        for track in live {
            for _ in 0..<size {
                let (start, length) = nextBuffer(for: track, frames: frames)
                let pts = CMTime(value: Int64(start), timescale: CMTimeScale(fmt.sampleRate))
                // The frame index and the presentation timestamp are the same number: the buffers of
                // a track are contiguous from zero, so where a sample sits in the track is where the
                // encoding says it sits.
                let buffer = encoded
                    ? makePositionEncodedSampleBuffer(track: track, startFrame: start, pts: pts,
                                                      frames: length, format: fmt)
                    : makeAudioSampleBuffer(pts: pts, frames: length, format: fmt)
                guard let buffer else { continue }
                let box = BufferBox(buffer: buffer)
                queue(for: track).async { [weak self] in self?.deliver(track, box.buffer) }
            }
        }
    }

    /// Wait until everything already enqueued on both tracks has run.
    func drain() {
        systemQueue.sync {}
        micQueue.sync {}
    }

    // MARK: - Private

    /// Where this track's next buffer starts and how long it is, and the bookkeeping that goes with
    /// it. Without a fault the answer is always "where the last one ended, a full buffer long".
    ///
    /// With one, the buffer at the fault's index starts `frames` later and is `frames` shorter, while
    /// `nextFrame` advances as if nothing had happened — so the audio in between exists nowhere, and
    /// the buffers after it are still at the positions they were always going to be at. That is what
    /// makes the hole's location something the test can name in advance.
    private func nextBuffer(for track: Track,
                            frames: AVAudioFrameCount) -> (start: Int, length: AVAudioFrameCount) {
        withLock {
            let index = emittedBuffers[track] ?? 0
            emittedBuffers[track] = index + 1
            let frame = Int(nextFrame[track] ?? 0)
            nextFrame[track] = Int64(frame) + Int64(frames)
            guard let fault, fault.bufferIndex == index, fault.frames < Int(frames) else {
                return (frame, frames)
            }
            return (frame + fault.frames, frames - AVAudioFrameCount(fault.frames))
        }
    }

    private func queue(for track: Track) -> DispatchQueue {
        track == .system ? systemQueue : micQueue
    }

    /// Forward on the track's own queue, gated exactly the way the real source gates: the flag and
    /// the handler are read in one acquisition, and the handler runs outside the lock so the two
    /// tracks are not serialized against each other.
    private func deliver(_ track: Track, _ buffer: CMSampleBuffer) {
        let handler: (@Sendable (Track, CMSampleBuffer) -> Void)? = withLock {
            isStopped ? nil : self.handler
        }
        handler?(track, buffer)
    }

    /// `NSLock` is unavailable from an asynchronous context, so every acquisition goes through a
    /// synchronous helper — the same shape `SCKCaptureSource` uses for the same reason.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Shared helpers

/// A scratch directory that removes itself.
func makeTemporaryDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acta-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The largest a WAV file can be while holding **no audio**: `AVAssetWriter` writes a
/// WAVE_FORMAT_EXTENSIBLE header, which is bigger than the 44-byte canonical one. This exists so
/// "the segment is valid" cannot be satisfied by `fileSize > 0` — a header-only stub passes that,
/// and a header-only stub is exactly what a broken recording leaves behind.
let wavHeaderOnlyMaxBytes = 512

/// Whether a file is really audio: it must expose an audio track, have a positive duration, and be
/// bigger than a bare header. All three, because each alone is satisfied by something broken — an
/// empty preamble has a track and a header, and a zero-duration file has both as well.
func isRealAudioFile(_ url: URL) async -> Bool {
    guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
          size > wavHeaderOnlyMaxBytes else { return false }
    let asset = AVURLAsset(url: url)
    guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
          let duration = try? await asset.load(.duration), duration.seconds > 0 else { return false }
    return true
}

/// Poll `condition` until it holds or `timeout` elapses; returns whether it held.
///
/// Real time, deliberately: this waits on the *test's* own progress (a background watchdog task
/// getting round to its next tick), not on anything the injected clock controls. The timeout is a
/// deadlock guard, not a duration the tests are expected to spend.
func waitUntil(timeout: Double = 5.0, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}
