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
    private let microphone: any CaptureMicrophoneResolving
    private let lifecycle = CaptureLifecycle()
    private let lifecycleLock = NSLock()
    private var pinned: AudioInputDevice?
    private var attempting: AudioInputDevice?
    private var generation: UInt64 = 0
    private var stopped = false

    private let systemWriter: SegmentWriter
    private let micWriter: SegmentWriter

    /// The stop reminder's meter, when the reminder is wired up at all.
    ///
    /// ⚠️ **A passenger, never a dependency.** Nothing in the recording path reads its answer, waits on
    /// it, or fails because of it: `append` writes first and measures afterwards.
    private let activityMeter: (any AudioActivityMetering)?

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
    /// - Parameter microphone: who decides which device to record from, asked again at every start
    ///   and restart. ⚠️ No default, for the reason the other two have none.
    public init(directory: URL,
                segmentSeconds: Double = Double(SegmentLayout.defaultSegmentSeconds),
                source: CaptureSource,
                permissions: PermissionChecking,
                microphone: any CaptureMicrophoneResolving,
                activityMeter: (any AudioActivityMetering)? = nil) {
        self.directory = directory
        self.source = source
        self.activityMeter = activityMeter
        self.permissions = permissions
        self.microphone = microphone
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
        try await serialized { try await self.performStart() }
    }

    /// Whether this recorder has been stopped for good.
    ///
    /// ⚠️ **Stopping is terminal, and until Task 5 nothing said so.** `SegmentWriter.finish()` sets
    /// `isFinished` permanently and `append` drops everything afterwards — so a `restart()` admitted
    /// *after* a `stop()` brings the capture back up, holds the microphone, and writes nothing. That is
    /// invisible capture after a finished recording: the indicator is lit, the files never grow. The
    /// serialized queue alone does not prevent it — it orders operations, it does not refuse late ones.
    public var isStopped: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return stopped
    }

    /// Which capture attempt is current, and what it is pointing at.
    ///
    /// ⚠️ **A fact about a *capture*, not about hardware, and that distinction is a defect I had to be
    /// shown twice.** A pending "this device is gone" carries no meaning on its own: by the time it is
    /// acted on, the capture it was about may have been replaced by an explicit switch, and restarting
    /// then tears down a perfectly healthy replacement — breaking "a healthy capture is never preempted
    /// except by *Use now*". Comparing the **uid** does not fix it either: a device that disconnects and
    /// reconnects has the same uid and a different capture. Only a generation does.
    ///
    /// ⚠️ `device` is populated **when a candidate is chosen, before the source is opened**, not when
    /// the start returns. A loss delivered while the new source is up but `start()` has not yet returned
    /// would otherwise find no device to test against and vanish — which is the one window a recording
    /// most needs covered.
    public struct CaptureIdentity: Equatable, Sendable {
        public var generation: UInt64
        /// The device this attempt is opening, or has opened.
        public var device: AudioInputDevice?
        /// Whether the source actually came up.
        public var isEstablished: Bool
    }

    public var captureIdentity: CaptureIdentity {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return CaptureIdentity(generation: generation, device: attempting ?? pinned,
                               isEstablished: pinned != nil)
    }

    /// The device this recording is currently pinned to, once a start has succeeded.
    ///
    /// ⚠️ Set only **after** capture actually comes up. The menu must never show a requested device as
    /// active before it is — that is the difference between reporting a switch and promising one.
    public var pinnedMicrophone: AudioInputDevice? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return pinned
    }

    private func performStart(restoring restorable: AudioInputDevice? = nil) async throws {
        guard !isStopped else {
            log.error("Refusing to start: this recording has already stopped")
            throw StartupFailure.recordingAlreadyStopped
        }
        try await requestPermissionsIfNeeded()

        // ⚠️ **The restoration candidate is a parameter, not the live pin.** The pin is cleared the
        // moment the source goes down — it means "this is recording" — so the device worth going back to
        // has to be carried separately. It is not assumed to be on the list either: a healthy pin can
        // have been removed by the very edit that triggered this restart, or have come from
        // `.systemDefault` and never been ranked at all.
        let previous = restorable
        let candidates: [AudioInputDevice]
        switch microphone.resolve() {
        case .pinned(let device, let alternatives):
            // ⚠️ Bounded by construction: the resolver returns a finite ranked list and every candidate
            // is tried at most once, so "no candidate succeeded" terminates instead of retrying a dead
            // machine forever. The watchdog's own attempt budget sits above this.
            var ranked = [device] + alternatives
            if let previous, !ranked.contains(where: { $0.uid == previous.uid }) {
                ranked.append(previous)
            }
            candidates = ranked
        case .unavailable(let failure):
            // ⚠️ Even with nothing resolvable, a device that *was* working is worth trying: the
            // resolution failed, the hardware may not have.
            if let previous {
                candidates = [previous]
            } else {
                log.error("No microphone: \(String(describing: failure), privacy: .public)")
                throw StartupFailure(failure)
            }
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                beginAttempt(on: candidate)
                try await source.start(microphoneDeviceID: candidate.uid)
                setPinned(candidate)
                log.info("Recording from \(candidate.name, privacy: .public)")
                return
            } catch {
                // ⚠️ Enumerating is not starting. A device the OS lists happily can still refuse to
                // open, so the next configured alternative is tried rather than failing the recording.
                lastError = error
                log.error("Microphone \(candidate.name, privacy: .public) did not start: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Raw capture errors are not let out: without `.streamNotStarted` the caller cannot tell
        // "the stream did not come up" (healed by a restart) from other failures, and the
        // self-healing (`SelfCheck`) would not spend its attempts (Task 4).
        // ⚠️ Nothing is recording, so nothing may claim to be.
        clearAttempt()
        log.error("Stream did not come up: \(lastError?.localizedDescription ?? "no candidate", privacy: .public)")
        throw StartupFailure.streamNotStarted
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
    /// - Parameter reason: who asked, and therefore who reports the outcome. The default is the
    ///   watchdog, which is the caller that cannot pass one — `SelfCheck` knows nothing of this.
    /// - Parameter expecting: the capture generation this restart is **about**. Checked inside the
    ///   serialized body, immediately before the source is torn down.
    ///
    ///   ⚠️ **Not the same as checking before calling, and that gap is a real defect.** A user's
    ///   restart can already own the lifecycle while it is still stopping the old source: the
    ///   generation is unchanged when a loss watch looks, so its restart is admitted and queues behind
    ///   the user's — and by the time it runs, it tears down the healthy capture that replaced the one
    ///   it was about. An actor-side check followed by an unconditional queued operation closes
    ///   nothing.
    public func restart(reason: RestartReason = .watchdog,
                        expecting: UInt64? = nil) async throws {
        try await serialized { try await self.performRestart(reason: reason, expecting: expecting) }
    }

    /// Why a restart is happening. ⚠️ **Carried so that exactly one owner reports it, with the true
    /// reason.** Without it every device-changing restart looked identical, so an explicit *Use now*
    /// from a perfectly healthy built-in microphone to a USB one was announced as "MacBook Pro
    /// Microphone stopped working" — and then announced a second time, correctly, by the caller that
    /// had asked for it.
    public enum RestartReason: Equatable, Sendable {
        /// Self-healing: the stream stalled or did not come up. Nobody else is reporting this one.
        case watchdog
        /// The user asked for this device. The caller that took the request reports the outcome.
        case userSwitch
        /// The pinned device became unusable. The loss watch reports what it landed on.
        case deviceLoss
    }

    /// Called after a **watchdog** restart re-resolved onto a different microphone — the one case with
    /// no other owner. ⚠️ Reported, never silent: the audio changes source mid-meeting and a user who
    /// cannot tell why has been handed a mystery.
    public var onDeviceAdopted: (@Sendable (AudioInputDevice, AudioInputDevice) -> Void)?

    private func performRestart(reason: RestartReason, expecting: UInt64?) async throws {
        // ⚠️ Checked **here**, holding the lifecycle, before anything is torn down.
        if let expecting, captureIdentity.generation != expecting {
            log.info("Skipping a restart for a capture that has already been replaced")
            throw StartupFailure.captureSuperseded
        }
        // ⚠️ Checked at **admission**, before the source is torn down, so a late switch cannot even
        // interrupt a finished recording — never mind reopen one.
        guard !isStopped else {
            log.error("Refusing to restart: this recording has already stopped")
            throw StartupFailure.recordingAlreadyStopped
        }
        let before = pinnedMicrophone
        await source.stop()
        // ⚠️ **Cleared the moment the source is down, not on the way out of a failed start.** The pin
        // means "this is recording"; between the teardown and a successful start nothing is, and
        // `performStart` can throw before ever reaching its own clear — a revoked permission does
        // exactly that, leaving a torn-down capture still naming a microphone.
        setPinned(nil)
        systemWriter.finishAndAdvance()
        micWriter.finishAndAdvance()
        log.info("Restarting stream")
        // ⚠️ `performStart()`, not `start()`: the serialization is already held. It also re-resolves the
        // microphone, which is why a *Use now* and a priority edit both take effect here and why every
        // device switch is a restart rather than a second lifecycle owner.
        try await performStart(restoring: before)
        // ⚠️ Only the watchdog's own recovery is announced here; the other two have callers that report
        // the outcome themselves, and announcing both produced two notices for one event.
        if reason == .watchdog, let before, let after = pinnedMicrophone, before.uid != after.uid {
            onDeviceAdopted?(before, after)
        }
    }

    /// Stop the capture and finalize the current segments of both tracks. Safe by the same argument
    /// as `restart()`: after an awaited `stop()` the source delivers nothing more, so no buffer can
    /// land in a writer that is being finalized — which would delete the very tail being closed.
    public func stop() async {
        try? await serialized {
            await self.source.stop()
            self.systemWriter.finish()
            self.micWriter.finish()
            self.markStopped()
            self.log.info("Capture stopped")
        }
    }

    // MARK: - One serialized capture lifecycle

    /// ⚠️ **Start, restart and stop are one queue, and Task 5 is what forced it.** Until now there were
    /// two callers — the watchdog's `restart()` and the session's `stop()` — and `RecordingSession`
    /// kept them apart by cancelling the watchdog and awaiting it before stopping. A microphone switch
    /// is a third caller arriving from the menu, on the main actor, with no such arrangement: it would
    /// tear a stream down while the watchdog was building one. The `restart()` doc comment's order
    /// ("the whole point, and must not be rearranged") is only meaningful if two of them cannot be
    /// interleaved in the first place.
    private func serialized<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let box = LifecycleResult<T>()
        await lifecycle.serialize {
            do { box.store(.success(try await body())) } catch { box.store(.failure(error)) }
        }
        return try box.take()
    }

    /// ⚠️ A plain `NSLock` cannot be taken across an `await`, and the pin is written from one. The
    /// write is a whole-value swap under the lock in a non-async helper, which is all it needs.
    private func setPinned(_ device: AudioInputDevice?) {
        lifecycleLock.lock()
        pinned = device
        if device != nil { attempting = nil }
        lifecycleLock.unlock()
    }

    /// Nothing is being opened and nothing is pinned. Non-async so the lock is never held across an
    /// `await`.
    private func clearAttempt() {
        lifecycleLock.lock()
        pinned = nil
        attempting = nil
        lifecycleLock.unlock()
    }

    /// A new capture attempt begins: a fresh generation, and the device it is opening published before
    /// the source is touched.
    private func beginAttempt(on device: AudioInputDevice) {
        lifecycleLock.lock()
        generation &+= 1
        attempting = device
        lifecycleLock.unlock()
    }

    /// ⚠️ **Clears the pin as well as latching the stop.** Retaining the last uid after teardown is not
    /// evidence of active capture, and a menu reading it would show a microphone as recording when
    /// nothing is.
    private func markStopped() {
        lifecycleLock.lock()
        pinned = nil
        attempting = nil
        generation &+= 1
        stopped = true
        lifecycleLock.unlock()
    }

    private actor CaptureLifecycle {
        private var tail: Task<Void, Never>?

        /// Run `body` after everything already queued, and never beside it.
        func serialize(_ body: @escaping @Sendable () async -> Void) async {
            let previous = tail
            let task = Task {
                await previous?.value
                await body()
            }
            tail = task
            await task.value
        }
    }

    private final class LifecycleResult<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, Error>?
        func store(_ result: Result<T, Error>) { lock.lock(); value = result; lock.unlock() }
        func take() throws -> T {
            lock.lock()
            defer { lock.unlock() }
            guard let value else { throw StartupFailure.streamNotStarted }
            return try value.get()
        }
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
        // ⚠️ **After the write, and behind a gate that is read before anything else happens.** With the
        // stop reminder switched off, `isEnabled` is false and nothing below runs at all — no format
        // parsing, no sample walk, no allocation. The recording is the product; this is a hint about it,
        // and the ordering here says which is which.
        guard let activityMeter, activityMeter.isEnabled else { return }
        activityMeter.measure(buffer,
                              track: track == .system ? .system : .microphone,
                              generation: currentGeneration)
    }

    /// The capture generation a summary belongs to, so a restart cannot warm the next recording's
    /// estimate with the previous one's audio.
    private var currentGeneration: UInt64 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return generation
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
