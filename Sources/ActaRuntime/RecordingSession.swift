import ActaKit
import Foundation
import os

/// The lifecycle of a single recording: create the folder + `session.json` (`recording`), drive the
/// capture through `AudioRecorder`, and on a clean stop finalize (`done`) and assemble the segments
/// into the final files.
///
/// Splits responsibility with `AudioRecorder` (which only knows about `SCStream` and segments):
/// here live the session marker and the assembly, that is, the fault-tolerant part.
///
/// `@unchecked Sendable`, and the reason is *not* "the methods run on the main actor" — they do not.
/// `start`/`stop` are `nonisolated async`, so under SE-0338 they hop to the cooperative pool rather
/// than inherit `RecordingController`'s actor. What actually orders them is the controller's phase
/// gate: it drives a session through start → stop from the main actor and never overlaps two calls
/// on one instance, and its main-actor suspension points give the happens-before that `watchdogTask`
/// and `startedAt` rely on. Everything shared beyond those synchronizes itself — `AudioRecorder` and
/// `SelfCheck` internally, `lastWrittenSegmentCount` behind `manifestQueue`, `wakeLock` behind its
/// own lock. Anything added here must bring its own synchronization; there is no ambient actor to
/// inherit.
@available(macOS 15.0, *)
public final class RecordingSession: @unchecked Sendable {
    /// The recording folder.
    public let directory: URL

    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "RecordingSession")
    private let settings: RecordingSettings
    private let segmentSeconds: Int
    private let recorder: AudioRecorder
    private let selfCheck: SelfCheck
    private let store = SessionManifestStore()
    private var watchdogTask: Task<Void, Never>?
    /// Held for exactly the span of a recording: the display going idle takes ScreenCaptureKit's
    /// display away and kills the capture (Task 10). Taken in `start`, released on every exit path —
    /// a failed start, a clean stop, and the watchdog's give-up, which reaches `stop()` too.
    ///
    /// Injectable so that the call sites are provable: while this was hardcoded, deleting either
    /// `acquire()` or `release()` left the whole suite green — the lock's own tests exercise it
    /// standalone and cannot see the session. Both halves are driven from `DisplayWakeLockTests`
    /// today: `stop()` directly, and `start()` via a directory it cannot create, which throws below
    /// before any capture and so needs neither TCC nor an audio session.
    private let wakeLock: DisplayWakeLock

    /// `segment_count` updates arrive here from the queues of both tracks: a dedicated serial queue
    /// serializes the read-modify-write of the marker and moves the disk write off the hot audio
    /// path.
    private let manifestQueue = DispatchQueue(label: "dev.personal.acta.manifest")
    /// The last written counter value (only from `manifestQueue`).
    private var lastWrittenSegmentCount = 0
    /// When the recording started — kept so that a `session.json` lost mid-recording can be rebuilt
    /// on stop with the real start time instead of an invented one.
    private var startedAt = Date()

    public init(directory: URL,
                settings: RecordingSettings = .default,
                wakeLock: DisplayWakeLock = DisplayWakeLock()) {
        self.directory = directory
        self.wakeLock = wakeLock
        let settings = settings.normalized()
        self.settings = settings
        self.segmentSeconds = settings.segmentSeconds
        let recorder = AudioRecorder(directory: directory, segmentSeconds: Double(settings.segmentSeconds))
        self.recorder = recorder
        self.selfCheck = SelfCheck(recorder: recorder)
    }

    /// Start: create the folder, write `session.json` (`recording`), launch the capture and the
    /// self-diagnosis. If the data really did not start flowing — stop and throw a clear error: we
    /// never show a "mute" recording status (Task 4).
    /// - Parameter onStall: called if the watchdog exhausted its restart attempts during the
    ///   recording (the buffer stream is gone for good). The controller must show an error and stop
    ///   the recording — a "mute" recording status is unacceptable. Not called on the main actor.
    public func start(startedAt: Date = Date(),
                      onStall: @escaping @Sendable (StartupFailure) -> Void = { _ in }) async throws {
        // Every `throw` below is a start that never became a recording, and the assertion must not
        // outlive it: a recorder that keeps the display awake after it stopped recording is the worst
        // kind of bug — the machine never sleeps and nobody knows why. `confirmed` flips only once
        // the self-diagnosis has confirmed the stream, and from then on `stop()` owns the release.
        var confirmed = false
        wakeLock.acquire()
        defer { if !confirmed { wakeLock.release() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.startedAt = startedAt
        let manifest = SessionManifest(status: .recording, startedAt: startedAt,
                                       segmentSeconds: segmentSeconds, segmentCount: 0)
        try store.write(manifest, to: directory)
        recorder.setSegmentCountObserver { [weak self] count in
            // Bind `self` once, strongly: loading the weak reference separately on each queue is a
            // data race (the second load races with deallocation), and the session must stay alive
            // until the counter it just accepted has been written anyway.
            guard let self else { return }
            manifestQueue.async { self.persistSegmentCount(count) }
        }
        do {
            try await recorder.start()
        } catch StartupFailure.streamNotStarted {
            // The stream did not come up — we do not abort the start: the self-diagnosis below will
            // see `streamStarted == false` and go through the same 2–3 restart attempts as it does
            // for a stalled stream (Task 4). Other causes (missing permissions) are not healed by a
            // restart and fly upwards.
            log.error("Stream did not come up on start — handing it to self-diagnosis for a restart")
        }

        if let failure = await selfCheck.verifyStartAndHeal() {
            log.error("Start not confirmed by self-diagnosis: \(failure.userMessage, privacy: .public)")
            await recorder.stop()
            throw failure
        }

        confirmed = true
        watchdogTask = Task { [selfCheck] in
            await selfCheck.runWatchdog(onStall: onStall)
        }
        // `.notice`, not `.info`: `os_log` does not persist `.info`, so the lifecycle events were
        // gone by the time anyone came to investigate a failure — which is how the display-sleep bug
        // stayed invisible for as long as it did.
        log.notice("Recording session started: \(self.directory.lastPathComponent, privacy: .public)")
    }

    /// Clean stop: stop the capture, assemble the segments (per the track selection from the
    /// settings), mark the marker as `done`. Deleting the segments after the assembly also comes
    /// from the settings (`deleteSegmentsAfterAssembly`).
    @discardableResult
    public func stop() async -> SegmentAssembler.Result? {
        // Wait for the watchdog to finish before stopping the recorder: otherwise its `restart()`
        // could run after `recorder.stop()` and bring up a new `SCStream` that would write segments
        // after the assembly (a race over `stream`). Cancel + await serializes the transitions.
        watchdogTask?.cancel()
        await watchdogTask?.value
        watchdogTask = nil
        await recorder.stop()
        // Released here, and not at the top of `stop()`: the two awaits above are not instant —
        // cancellation does not interrupt an `SCStream` bring-up already in flight inside the
        // watchdog's `restart()` — and an assertion suppresses the idle timer without resetting it,
        // so after a long meeting the display can go dark the moment it drops. Releasing before the
        // capture is finalized would therefore risk killing the tail of the very recording this
        // assertion exists to protect. From here on nothing is captured, and the assembly that
        // follows — tens of seconds of `ffmpeg` for an hour-long meeting — has no business holding
        // the display on. This is also the watchdog's give-up path (`handleFatalStall` → `stop()`),
        // which is the exact path the 2026-07-15 failure took.
        wakeLock.release()
        // Wait for the counter updates already sitting in the queue: otherwise a late one would land
        // on top of the final marker, turning `done` back into `recording`.
        manifestQueue.sync {}

        var manifest = store.read(from: directory)
            ?? SessionManifest(status: .recording, startedAt: startedAt,
                               segmentSeconds: segmentSeconds, segmentCount: 0)
        manifest.segmentCount = recorder.finalizedSegmentCount

        var result: SegmentAssembler.Result?
        do {
            // The assembly waits for `ffmpeg` synchronously (`waitUntilExit`) — for an hour-long
            // meeting that is tens of seconds. From an `async` method this would occupy a thread of
            // the cooperative pool (whose size equals the core count) for all that time, so we move
            // the blocking work off it — exactly as recovery already does in
            // `RecordingController.runRecovery`.
            let directory = directory
            let settings = settings
            result = try await Task.detached(priority: .utility) {
                try SegmentAssembler().assemble(in: directory,
                                                deleteSegments: settings.deleteSegmentsAfterAssembly,
                                                tracks: settings.trackSelection)
            }.value
            manifest.status = .done
        } catch {
            // The assembly failed (no ffmpeg / no segments). We leave the marker as is so that
            // recovery on the next start tries again — no data is lost.
            log.error("Assembly on stop failed: \(error.localizedDescription, privacy: .public)")
        }
        try? store.write(manifest, to: directory)
        log.notice("Recording session stopped: \(self.directory.lastPathComponent, privacy: .public)")
        return result
    }

    /// Write the number of closed segments into `session.json`. Called only from `manifestQueue`.
    ///
    /// The counter is informational: recovery reads the file system and does not look at it (Task
    /// 8.2). But keeping it forever at zero, as it has been so far, is not acceptable — anyone
    /// looking into the marker would be told there is nothing recorded while a dozen segments sit
    /// next to it on disk.
    ///
    /// The counter only grows, and we do not touch the marker's status: an update could have raced
    /// past the stop, and turning `done` back into `recording` would mean sending a finished
    /// recording off to recovery.
    private func persistSegmentCount(_ count: Int) {
        guard count > lastWrittenSegmentCount else { return }
        lastWrittenSegmentCount = count
        guard var manifest = store.read(from: directory), manifest.status == .recording else { return }
        manifest.segmentCount = count
        do {
            try store.write(manifest, to: directory)
        } catch {
            // Not fatal: the segments on disk are intact, and recovery goes off the FS anyway.
            log.error("Failed to update segment_count: \(error.localizedDescription, privacy: .public)")
        }
    }
}
