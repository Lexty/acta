import ActaKit
import Foundation
import os

/// The lifecycle of a single recording: create the folder + `session.json` (`recording`), drive the
/// capture through `AudioRecorder`, and on a clean stop finalize (`done`) and assemble the segments
/// into the final files.
///
/// Splits responsibility with `AudioRecorder` (which only knows about the capture and the segments):
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

    /// The recording's **own** view of the audio devices — read-only, and owned by this session for
    /// exactly its lifetime.
    ///
    /// ⚠️ **Owned here rather than registered with `MicrophoneManager`, and that was settled
    /// deliberately.** The lifetime is the recording, including its capture restarts; the session owns
    /// the token *and* the work its handler queues, and a manager-side registry could not acquire the
    /// stronger guarantee — cancelling a token fences the directory callback, it does not cancel Tasks
    /// that callback already started.
    ///
    /// ⚠️ **The state behind it lives in an actor, not in this class.** This type is `@unchecked
    /// Sendable` and its own documentation says so in as many words: there is no ambient actor to
    /// inherit and anything added must bring its own synchronization. My first version put the epoch and
    /// an in-flight flag in plain properties, mutated by `stop()` on the cooperative pool and read from
    /// a main-actor Task — a data race, and a flag that dropped intervening observations rather than
    /// coalescing them.
    private let deviceReader: (any AudioDeviceReading)?
    private var deviceObservation: (any AudioDeviceObservation)?
    private let lossWatch: MicrophoneLossWatch

    /// Called when the recording's microphone changed, or when it cannot be watched. Not called on the
    /// main actor.
    ///
    /// ⚠️ **A notice channel, and only for things that are not recording failures.** When nothing is
    /// recording the report goes to `fatalStall` instead — see there.
    public var onMicrophoneChanged: (@Sendable (ControllerMessage) -> Void)?

    /// The watchdog's give-up route, kept so the loss path can reach it too.
    ///
    /// ⚠️ **A notice is the wrong channel when nothing is recording.** Reporting a failed failover as
    /// `microphoneSwitchFailed` — whose text says "The previous microphone is still recording" — while
    /// the capture is down leaves `phase` at `recording` and tells the user the opposite of the truth.
    /// Notices are for a failover that *succeeded*; a total failure is the failure policy's.
    private var fatalStall: (@Sendable (StartupFailure) -> Void)?
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
    /// Whether `start()` ever confirmed a capture. Gates `stop()`: without it, stopping a session
    /// that never started would *write* a marker rather than find one — see `stop()`.
    private var didStart = false

    /// - Parameter dependencies: capture, permissions and time. This is the **composition root**: the
    ///   same `PermissionChecking` instance goes to both consumers below — `AudioRecorder`, which
    ///   rejects a start without a permission, and `SelfCheck`, which diagnoses one that is missing or
    ///   was revoked mid-recording. The session itself asks no permission questions.
    /// - Parameter microphone: which device this recording is pinned to, re-asked at every start and
    ///   restart. It is **not** in `RecordingDependencies`: the reader behind it belongs to the app,
    ///   not to one recording, and is handed down by `liveSessionFactory` from `MicrophoneManager` —
    ///   the app-lifetime owner. See the seam amendment in `CLAUDE.md`.
    public init(directory: URL,
                settings: RecordingSettings = .default,
                wakeLock: DisplayWakeLock = DisplayWakeLock(),
                microphone: any CaptureMicrophoneResolving,
                deviceReader: (any AudioDeviceReading)? = nil,
                dependencies: RecordingDependencies = .live) {
        self.directory = directory
        self.deviceReader = deviceReader
        self.wakeLock = wakeLock
        let settings = settings.normalized()
        self.settings = settings
        self.segmentSeconds = settings.segmentSeconds
        let permissions = dependencies.makePermissions()
        let recorder = AudioRecorder(directory: directory,
                                     segmentSeconds: Double(settings.segmentSeconds),
                                     source: dependencies.makeSource(),
                                     permissions: permissions,
                                     microphone: microphone)
        self.recorder = recorder
        lossWatch = MicrophoneLossWatch(recorder: recorder)
        self.selfCheck = SelfCheck(recorder: recorder, permissions: permissions,
                                   clock: dependencies.makeClock())
    }

    /// Start: create the folder, write `session.json` (`recording`), launch the capture and the
    /// self-diagnosis. If the data really did not start flowing — stop and throw a clear error: we
    /// never show a "mute" recording status (Task 4).
    /// - Parameter onStall: called if the watchdog exhausted its restart attempts during the
    ///   recording (the buffer stream is gone for good). The controller must show an error and stop
    ///   the recording — a "mute" recording status is unacceptable. Not called on the main actor.
    public func start(startedAt: Date = Date(),
                      onStall: @escaping @Sendable (StartupFailure) -> Void = { _ in }) async throws {
        fatalStall = onStall
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
        // ⚠️ **Installed before the capture comes up, not after verification.** A device lost during
        // the startup probe is otherwise missed for want of a listener, permanently — and an earlier
        // comment of mine claimed the controller's callback assignment covered that window, which it
        // never did: assigning a callback installs nothing.
        await lossWatch.install(report: { [weak self] in self?.onMicrophoneChanged?($0) },
                                fatal: { [weak self] in self?.fatalStall?($0) })
        observeDeviceLoss()
        // A watchdog recovery that lands on a different microphone is a device change the user must be
        // able to explain — the plan's "reported, not silent".
        recorder.onDeviceAdopted = { [weak self] previous, adopted in
            self?.onMicrophoneChanged?(.microphoneSwitched(device: adopted.name,
                                                           reason: "\(previous.name) stopped working"))
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
        didStart = true
        // Reconcile once now that a device is actually pinned: the observer was installed before the
        // capture came up, so anything that happened during the probe has to be looked at rather than
        // waited for.
        if let deviceReader {
            let snapshot = deviceReader.enumerateInputDevices()
            await lossWatch.observe(snapshot)
        }
        watchdogTask = Task { [selfCheck] in
            await selfCheck.runWatchdog(onStall: onStall)
        }
        // `.notice`, not `.info`: `os_log` does not persist `.info`, so the lifecycle events were
        // gone by the time anyone came to investigate a failure — which is how the display-sleep bug
        // stayed invisible for as long as it did.
        log.notice("Recording session started: \(self.directory.lastPathComponent, privacy: .public)")
    }

    /// Clean stop: stop the capture, assemble the segments, mark the marker as `done`. Deleting the
    /// segments after the assembly comes from the settings (`deleteSegmentsAfterAssembly`).
    @discardableResult
    /// Deliver observations to the loss watch without going through the directory — test-facing, and
    /// the only way to pin an ordering the scheduler would otherwise choose.
    func deliverForTesting(_ snapshots: [DeviceEnumeration]) async {
        await lossWatch.observe(snapshots)
    }

    /// Watch for the pinned microphone becoming unusable.
    ///
    /// ⚠️ **The watchdog is not a substitute, and assuming it was is what left this missing.**
    /// `TrackWatchdog` deliberately reads a track's count not increasing as ordinary source silence,
    /// and the system track keeps advancing when only the microphone goes — so a lost headset produced
    /// no stall at all. Even where the whole stream dies, the watchdog answers after its six-second
    /// window, and the requirement is that the loss is surfaced **immediately**.
    ///
    /// ⚠️ **Installed before `recorder.start()`**, so a device lost during the startup probe is not
    /// missed for want of a listener. An earlier comment claimed the controller's callback assignment
    /// covered that window; it did not — assigning a callback installs nothing.
    private func observeDeviceLoss() {
        guard let deviceReader, deviceObservation == nil else { return }
        switch deviceReader.observe({ [weak self] change in
            switch change {
            case .deviceListChanged, .readinessChanged:
                // ⚠️ **Readiness counts.** A device can stay listed and stop being usable — not alive,
                // or no input channels — and an observer that only watches the list never learns.
                break
            case .defaultInputChanged:
                return
            case .observationDegraded(let reason):
                self?.onMicrophoneChanged?(.microphoneObservationDegraded(reason: reason))
                return
            }
            // Read where the change was delivered: by the time the hop lands the device may be back.
            let snapshot = deviceReader.enumerateInputDevices()
            let watch = self?.lossWatch
            Task { await watch?.observe(snapshot) }
        }) {
        case .observing(let subscription):
            deviceObservation = subscription
        case .failed(let reason):
            // ⚠️ Not swallowed: a recording watching nothing looks exactly like a recording whose
            // microphone never goes away.
            deviceObservation = nil
            onMicrophoneChanged?(.microphoneObservationDegraded(reason: reason))
        }
    }

    /// Re-resolve the microphone and bring the capture back up on it — a *Use now* landing on a
    /// recording that is already running, or a priority edit the user wants applied now.
    ///
    /// ⚠️ **It goes through `AudioRecorder.restart()` and nowhere else.** That is the one owner of
    /// `stop() → finishAndAdvance() → start()`, whose order its own doc calls "the whole point"; a
    /// second path would race the watchdog and Stop. `restart()` re-resolves, so the restore after a
    /// failed switch is the *same* call — the alternatives it falls through to are the user's list,
    /// which is where the previous device still is.
    ///
    /// ⚠️ **The result is read from what actually came up**, never from what was asked for: the menu
    /// must not show a device as active before capture succeeded on it.
    public func switchMicrophone(to requested: String) async -> MicrophoneSwitchResult {
        do {
            try await recorder.restart(reason: .userSwitch)
        } catch {
            log.error("Microphone switch failed: \(error.localizedDescription, privacy: .public)")
            // ⚠️ Same rule as a lost device: an explicit switch that leaves **nothing** recording is a
            // recording failure, not a note about a switch.
            let failure = (error as? StartupFailure) ?? .streamNotStarted
            fatalStall?(failure)
            return .failed(requested: requested)
        }
        guard let pinned = recorder.pinnedMicrophone else {
            fatalStall?(.streamNotStarted)
            return .failed(requested: requested)
        }
        return pinned.uid == requested ? .switched(to: pinned) : .fellBack(to: pinned)
    }

    /// What a microphone switch actually did.
    public enum MicrophoneSwitchResult: Equatable, Sendable {
        /// Capture came up on the requested device.
        case switched(to: AudioInputDevice)
        /// The requested device did not come up and a configured alternative did — the recording never
        /// stopped, and the user is told which microphone they are on now.
        case fellBack(to: AudioInputDevice)
        /// Nothing came up. ⚠️ The recording's failure policy owns what happens next; this only reports
        /// that the switch did not happen.
        case failed(requested: String)
    }

    public func stop() async -> SegmentAssembler.Result? {
        // Wait for the watchdog to finish before stopping the recorder: otherwise its `restart()`
        // could run after `recorder.stop()` and bring up a new `SCStream` that would write segments
        // after the assembly (a race over `stream`). Cancel + await serializes the transitions.
        // Stop scheduling before anything else, then **join** what is already running: cancelling the
        // token fences the directory callback and does nothing about a restart already in flight.
        deviceObservation?.cancel()
        deviceObservation = nil
        await lossWatch.stop()
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

        // A session that never started has no marker to finalize, and must not gain one. The
        // `store.read` fallback below exists to rebuild a `session.json` lost *mid-recording*; on a
        // session that never ran there is nothing to rebuild, so it would invent a `recording`
        // marker instead, assembly would fail on the empty folder leaving that status untouched, and
        // the write at the end would hand recovery a phantom interrupted recording to retry on every
        // launch, forever (`Recovery` treats any `status=recording` folder as interrupted).
        // `RecordingController` cannot reach this — both call sites gate on `phase == .recording`,
        // which only a confirmed `start()` sets — but `stop()` is public, so the invariant is
        // enforced here rather than left to the caller. Placed *below* the release above, not at the
        // top of `stop()`: an early return would skip that release, and the test that proves `stop()`
        // gives the assertion back drives exactly this path.
        guard didStart else { return nil }

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
                                                deleteSegments: settings.deleteSegmentsAfterAssembly)
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

/// The execution domain for one recording's microphone-loss handling.
///
/// ⚠️ **An actor because `RecordingSession` is not one.** That type is `@unchecked Sendable` and its own
/// documentation says there is no ambient actor to inherit and that anything added must bring its own
/// synchronization. The first version of this code kept an epoch and an in-flight flag as plain
/// properties, written by `stop()` on the cooperative pool and read from a main-actor Task.
@available(macOS 15.0, *)
actor MicrophoneLossWatch {
    private let recorder: AudioRecorder
    private var report: (@Sendable (ControllerMessage) -> Void)?
    private var fatal: (@Sendable (StartupFailure) -> Void)?
    private var stopped = false
    /// A loss **proved by some observation**, whether or not the newest one still shows it.
    ///
    /// ⚠️ **The fact is kept, not the snapshot, and my previous comment here overstated what keeping
    /// the newest snapshot achieved.** Deliver "built-in only" and then "AirPods back" before the
    /// driver runs, and the healthy snapshot replaces the other: the proved departure is gone, no
    /// restart is issued, and the capture goes on pointing at a device that left. A device returning is
    /// not evidence that the *existing* capture recovered — the stream was torn down when it left.
    private var lossProved = false
    private var driver: Task<Void, Never>?

    init(recorder: AudioRecorder) { self.recorder = recorder }

    func install(report: @escaping @Sendable (ControllerMessage) -> Void,
                 fatal: @escaping @Sendable (StartupFailure) -> Void) {
        self.report = report
        self.fatal = fatal
    }

    /// Deliver several observations **in one actor entry**, so the driver cannot run between them.
    ///
    /// ⚠️ Test-facing. It exists because the property under test is precisely what happens when two
    /// deliveries are queued ahead of the driver: calling `observe` twice from a test gives the driver a
    /// chance to run in between, and the test then passes against the bug it was written for.
    func observe(_ snapshots: [DeviceEnumeration]) {
        for snapshot in snapshots { observe(snapshot) }
    }

    func observe(_ snapshot: DeviceEnumeration) {
        guard !stopped else { return }
        // ⚠️ Evaluated **here**, against the snapshot that was delivered, rather than later against
        // whichever one happens to be newest.
        if let pinned = recorder.pinnedMicrophone, Self.isProvedUnusable(pinned, in: snapshot) {
            lossProved = true
        }
        guard lossProved, driver == nil else { return }
        driver = Task { await self.drain() }
    }

    /// Whether this snapshot **proves** the device cannot be recorded from.
    ///
    /// Unusable is not only absent: a device can stay listed and stop being alive, or lose its input
    /// channels. And absence is proved, never inferred — missing from a snapshot that could not
    /// describe every driver is `.unknown`, and acting on an unknown is acting on a guess.
    private static func isProvedUnusable(_ pinned: AudioInputDevice, in snapshot: DeviceEnumeration) -> Bool {
        guard case .devices(let devices, let uninspectable) = snapshot else { return false }
        if let listed = devices.first(where: { $0.uid == pinned.uid }) { return !listed.isCaptureCandidate }
        return uninspectable.isEmpty
    }

    /// Latch, then **join**. A recording that has stopped owns nothing still running.
    func stop() async {
        stopped = true
        lossProved = false
        let running = driver
        await running?.value
        driver = nil
    }

    private func drain() async {
        while !stopped, lossProved {
            lossProved = false
            await handle()
        }
        driver = nil
    }

    private func handle() async {
        guard let pinned = recorder.pinnedMicrophone else { return }

        do {
            try await recorder.restart(reason: .deviceLoss)
        } catch {
            // ⚠️ Checked **after** the await: the recording may have stopped while this was running, and
            // a stopped recording must not be handed a fatal failure it did not experience.
            guard !stopped else { return }
            fatal?((error as? StartupFailure) ?? .streamNotStarted)
            return
        }
        guard !stopped else { return }
        if let now = recorder.pinnedMicrophone, now.uid != pinned.uid {
            report?(.microphoneSwitched(device: now.name, reason: "\(pinned.name) is no longer usable"))
        }
    }
}
