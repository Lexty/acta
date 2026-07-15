import ActaKit
import Foundation
import os

/// The lifecycle of a single recording: create the folder + `session.json` (`recording`), drive the
/// capture through `AudioRecorder`, and on a clean stop finalize (`done`) and assemble the segments
/// into the final files.
///
/// Splits responsibility with `AudioRecorder` (which only knows about `SCStream` and segments):
/// here live the session marker and the assembly, that is, the fault-tolerant part. The UI wiring
/// (start/stop from the menu bar) arrives in Task 6 and will call these methods.
///
/// `@unchecked Sendable`: every method is called by `RecordingController` from the main actor
/// (serialized), while `AudioRecorder`/`SelfCheck` manage their own thread safety internally. This
/// makes it possible to call the session's `async` methods from the main actor without data-race
/// warnings.
@available(macOS 15.0, *)
final class RecordingSession: @unchecked Sendable {
    /// The recording folder.
    let directory: URL

    private let log = Logger(subsystem: AppInfo.bundleID, category: "RecordingSession")
    private let settings: RecordingSettings
    private let segmentSeconds: Int
    private let recorder: AudioRecorder
    private let selfCheck: SelfCheck
    private let store = SessionManifestStore()
    private var watchdogTask: Task<Void, Never>?

    /// `segment_count` updates arrive here from the queues of both tracks: a dedicated serial queue
    /// serializes the read-modify-write of the marker and moves the disk write off the hot audio
    /// path.
    private let manifestQueue = DispatchQueue(label: "dev.personal.acta.manifest")
    /// The last written counter value (only from `manifestQueue`).
    private var lastWrittenSegmentCount = 0
    /// When the recording started — kept so that a `session.json` lost mid-recording can be rebuilt
    /// on stop with the real start time instead of an invented one.
    private var startedAt = Date()

    init(directory: URL, settings: RecordingSettings = .default) {
        self.directory = directory
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
    func start(startedAt: Date = Date(),
               onStall: @escaping @Sendable (StartupFailure) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.startedAt = startedAt
        let manifest = SessionManifest(status: .recording, startedAt: startedAt,
                                       segmentSeconds: segmentSeconds, segmentCount: 0)
        try store.write(manifest, to: directory)
        recorder.setSegmentCountObserver { [weak self] count in
            self?.manifestQueue.async { self?.persistSegmentCount(count) }
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

        watchdogTask = Task { [selfCheck] in
            await selfCheck.runWatchdog(onStall: onStall)
        }
        log.info("Recording session started: \(self.directory.lastPathComponent, privacy: .public)")
    }

    /// Clean stop: stop the capture, assemble the segments (per the track selection from the
    /// settings), mark the marker as `done`. Deleting the segments after the assembly also comes
    /// from the settings (`deleteSegmentsAfterAssembly`).
    @discardableResult
    func stop() async -> SegmentAssembler.Result? {
        // Wait for the watchdog to finish before stopping the recorder: otherwise its `restart()`
        // could run after `recorder.stop()` and bring up a new `SCStream` that would write segments
        // after the assembly (a race over `stream`). Cancel + await serializes the transitions.
        watchdogTask?.cancel()
        await watchdogTask?.value
        watchdogTask = nil
        await recorder.stop()
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
        log.info("Recording session stopped: \(self.directory.lastPathComponent, privacy: .public)")
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
