import AVFoundation
import ActaKit
import ActaRuntime
import CoreMedia
import Foundation

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
        let (size, live, fmt, frames) = withLock {
            (count ?? batchSize,
             silentUntilRestart ? [] : Track.allCases.filter { !silencedTracks.contains($0) },
             format,
             framesPerBuffer)
        }
        guard size > 0 else { return }
        for track in live {
            for _ in 0..<size {
                let start: Int64 = withLock {
                    let frame = nextFrame[track] ?? 0
                    nextFrame[track] = frame + Int64(frames)
                    return frame
                }
                let pts = CMTime(value: start, timescale: CMTimeScale(fmt.sampleRate))
                guard let buffer = makeAudioSampleBuffer(pts: pts, frames: frames, format: fmt) else { continue }
                queue(for: track).async { [weak self] in self?.deliver(track, buffer) }
            }
        }
    }

    /// Wait until everything already enqueued on both tracks has run.
    func drain() {
        systemQueue.sync {}
        micQueue.sync {}
    }

    // MARK: - Private

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

// MARK: - Fake permissions

/// `PermissionChecking` with no system dialog behind it: it answers granted/denied per permission
/// and counts what was asked of it.
final class FakePermissions: PermissionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var screenGranted: Bool
    private var micStatus: AVAuthorizationStatus
    /// What a `requestScreenRecording()` / `requestMicrophone()` turns the answer into — the user
    /// agreeing in the dialog, or refusing.
    private var grantsOnRequest: Bool
    private var screenRequests = 0
    private var micRequests = 0

    init(screenGranted: Bool = true,
         micStatus: AVAuthorizationStatus = .authorized,
         grantsOnRequest: Bool = false) {
        self.screenGranted = screenGranted
        self.micStatus = micStatus
        self.grantsOnRequest = grantsOnRequest
    }

    /// How many times the code asked the system to prompt, per permission. Requesting when nothing
    /// needs requesting is a real bug — it is a dialog in the user's face on every restart.
    var screenRequestCount: Int { withLock { screenRequests } }
    var micRequestCount: Int { withLock { micRequests } }

    var hasScreenRecording: Bool { withLock { screenGranted } }

    @discardableResult
    func requestScreenRecording() -> Bool {
        withLock {
            screenRequests += 1
            if grantsOnRequest { screenGranted = true }
            return screenGranted
        }
    }

    var microphoneStatus: AVAuthorizationStatus { withLock { micStatus } }

    func requestMicrophone() async -> Bool {
        withLock {
            micRequests += 1
            if grantsOnRequest { micStatus = .authorized }
            return micStatus == .authorized
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Test clock

/// A clock that hands back the time asked of it almost immediately **and moves `now` by the full
/// amount anyway** — the two halves have to travel together. With `now` frozen, the stall threshold
/// never elapses, the watchdog's restart path silently becomes unreachable, and the tests keep
/// passing while proving nothing. That is the trap this type exists to avoid.
///
/// "Almost immediately" and not "instantly", which is the one non-obvious decision here. The
/// watchdog is a `while` loop whose only suspension is this sleep, so a truly instant one turns it
/// into a busy loop: it would burn its entire restart budget and flood the disk with buffers in the
/// microseconds between `start()` returning and a test calling `stop()`. A token real wait keeps the
/// loop's *shape* honest while compressing an hour of watchdog time into milliseconds. It is not a
/// virtual scheduler — nothing here queues, advances or drains on demand.
///
/// `onSleep` is what lets a test put data into the window the code is observing: the startup probe
/// and every watchdog tick call it, which is where the fake source's next batch comes from.
final class TestClock: SelfCheckClock, @unchecked Sendable {
    /// The real time a sleep of any virtual length costs. Small enough that a whole watchdog stall
    /// (six ticks) is milliseconds, large enough not to spin a core.
    private static let realWaitNanos: UInt64 = 200_000

    private let lock = NSLock()
    private var seconds = 0.0
    private var sleeps = 0
    private var handler: (@Sendable (Double) -> Void)?

    /// Called on every sleep, with the requested duration, after `now` has advanced.
    func onSleep(_ body: @escaping @Sendable (Double) -> Void) { withLock { handler = body } }

    /// How many waits the code under test has performed.
    var sleepCount: Int { withLock { sleeps } }

    var now: Double { withLock { seconds } }

    func sleep(for duration: Double) async {
        let body: (@Sendable (Double) -> Void)? = withLock {
            seconds += duration
            sleeps += 1
            return handler
        }
        body?(duration)
        // The suspension the watchdog's cancellation depends on: a loop that never suspends would
        // never observe `Task.isCancelled`, and `stop()` — which cancels and then awaits it — would
        // hang forever.
        try? await Task.sleep(nanoseconds: Self.realWaitNanos)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Wake lock counting

/// A `DisplayWakeLock` whose activity calls are counted rather than made — the only way to prove a
/// failed start gave the assertion back, since a dropped token ends its activity by itself and the
/// OS therefore cannot tell a correct release from a leak.
final class CountingWakeLock: @unchecked Sendable {
    private let lock = NSLock()
    private var begun = 0
    private var ended = 0

    var beginCount: Int { lock.withLock { begun } }
    var endCount: Int { lock.withLock { ended } }

    func makeWakeLock() -> DisplayWakeLock {
        DisplayWakeLock(
            begin: { _ in
                self.lock.withLock { self.begun += 1 }
                return NSObject()
            },
            end: { _ in self.lock.withLock { self.ended += 1 } })
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
