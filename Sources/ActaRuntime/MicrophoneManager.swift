import ActaKit
import AppKit
import Foundation

/// The shipped wiring for microphone management, as a value a test can call.
///
/// **Why factories that are called exactly once, when `RecordingDependencies`' factories are called
/// once *per recording*.** The reason for a factory there is that a `CaptureSource` is stateful and
/// belongs to one recording, so handing the same instance round would be a bug. Here the opposite is
/// true and just as load-bearing: there must be **one** directory for the whole process, because two
/// would mean two sets of HAL listeners, two reconcilers racing each other for
/// `kAudioHardwarePropertyDefaultInputDevice`, and a fight Acta was having with itself. The factory
/// exists only so `live` can be a value rather than a hard-coded `CoreAudioDeviceDirectory()` inside
/// an initializer — a test can ask what production *would* build, which is exactly what a default
/// argument makes unaskable. `MicrophoneManager` calls each of these once, in `init`, and holds the
/// result for the life of the app.
public struct MicrophoneWiring: Sendable {
    /// The one directory the whole process shares.
    public var makeDirectory: @Sendable () -> any AudioDeviceDirectory
    /// What the reconciler measures its verification deadline and conflict window against.
    public var makeClock: @Sendable () -> any SelfCheckClock
    /// Where `NSWorkspace.didWakeNotification` is posted.
    ///
    /// ⚠️ **Injected because the handler is testable and I claimed it was not.** A synthetic post
    /// exercises it perfectly well — what a synthetic post must not do is reach a *different* manager
    /// running in a parallel test, which is what posting into the real workspace centre would allow.
    /// Only real OS sleep/wake stays manual.
    public var makeWakeCenter: @Sendable () -> NotificationCenter

    public init(makeDirectory: @escaping @Sendable () -> any AudioDeviceDirectory,
                makeClock: @escaping @Sendable () -> any SelfCheckClock,
                makeWakeCenter: @escaping @Sendable () -> NotificationCenter) {
        self.makeDirectory = makeDirectory
        self.makeClock = makeClock
        self.makeWakeCenter = makeWakeCenter
    }

    /// The production wiring: the real HAL, real time, the real workspace notification centre.
    public static let live = MicrophoneWiring(
        makeDirectory: { CoreAudioDeviceDirectory() },
        makeClock: { SystemClock() },
        makeWakeCenter: { NSWorkspace.shared.notificationCenter }
    )
}

/// What the manager knows about the machine's input devices right now, and how well it knows it.
public struct MicrophoneInventory: Equatable, Sendable {
    public var devices: [AudioInputDevice]
    /// Devices the directory could not describe. ⚠️ Carried, never dropped: a snapshot that omits a
    /// driver silently is indistinguishable from one where the device genuinely left, and consumers
    /// above act destructively on a departure.
    public var uninspectable: [String]
    /// Set when the last enumeration **failed**, which is not the same as finding nothing.
    public var failure: String?
    /// Set while the manager has no change subscription.
    ///
    /// ⚠️ **A separate field from `failure`, because they are separate facts and one hides.** A failed
    /// enumeration announces itself the next time anyone looks; a failed *registration* announces
    /// nothing ever again — the inventory simply stops changing, which is indistinguishable from a
    /// machine where nobody plugs anything in.
    public var observationDegraded: String?
    /// The system default input as last read.
    public var observedDefault: ObservedDefaultInput

    public init(devices: [AudioInputDevice] = [],
                uninspectable: [String] = [],
                failure: String? = nil,
                observationDegraded: String? = nil,
                observedDefault: ObservedDefaultInput = .unread) {
        self.devices = devices
        self.uninspectable = uninspectable
        self.failure = failure
        self.observationDegraded = observationDegraded
        self.observedDefault = observedDefault
    }

    public static let unknown = MicrophoneInventory()
}

/// The **composition root for microphone management**, and the one object that lives as long as the
/// app does.
///
/// It plays the part `RecordingSession` plays for permissions: it builds the single dependency its
/// consumers must share and hands it to each of them, rather than letting each construct its own.
/// Here that dependency is the `AudioDeviceDirectory` — one per process, handed to the reconciler
/// whole and to everything else as `AudioDeviceReading`.
///
/// **Why this is not in `RecordingDependencies`, stated as an amendment and not as a reading of the
/// existing rule.** `CLAUDE.md` says new seams go into `RecordingDependencies` and never into a
/// default argument. That rule is written for **per-recording** seams — its members are factories
/// precisely because "a source is stateful and belongs to exactly one recording" — and it says nothing
/// about lifetime because until now every seam had the same one. Enforcement is the first seam that
/// must run **while nothing is recording** and **survive a recording ending**, which is the whole
/// promise of feature (B): the Mac's default input stays on your list while Acta is merely running.
/// A per-recording factory gives it neither: it would exist only between `start()` and `stop()`, which
/// is exactly the interval the feature is *not* about. ⚠️ An earlier draft of this comment also blamed
/// watchdog restarts for producing several enforcers at once. That was **invented** —
/// `AudioRecorder.restart()` reuses the same source, writers and session — and it is removed rather
/// than softened; the lifetime argument needs no such mechanism. The honest move is to widen the rule
/// with the lifetime distinction, which `CLAUDE.md` now records; it is **not** to argue that the
/// existing wording anticipated this.
///
/// **Two consumers, one subscription each, neither owning the other:**
/// - the **reconciler** (feature B) — opt-in, holds the writable directory, and is the only thing in
///   the process that may write the system default;
/// - the **inventory** — always on, read-only, and what the menu and a recording's device selection
///   read. It exists independently of enforcement because the chooser and Acta's own capture pin have
///   to work with feature (B) switched off.
@MainActor
public final class MicrophoneManager {
    /// The production owner. ⚠️ Reaches the real HAL, so **no test may touch it** — the same rule
    /// `ControlAPI.shared` carries, for the same reason. Tests construct their own with a fake wiring.
    public static let shared = MicrophoneManager(wiring: .live)

    private let directory: any AudioDeviceDirectory
    private let clock: any SelfCheckClock
    private let wakeCenter: NotificationCenter

    /// The reconciler, created once with the manager. It is *created* eagerly and *enabled* only on
    /// request: feature (B) is opt-in, and an object that exists is not an object that is writing.
    public let reconciler: MicrophoneReconciler

    /// The read-only half of the directory, for a recording's device selection and for the menu.
    ///
    /// ⚠️ A recording receives **this**, never the directory itself, and never constructs a reconciler.
    /// The type narrows what is reachable *by accident* — `AudioDeviceReading` has no
    /// `setDefaultInput` — but it is **not** a capability guarantee: both protocols are public in this
    /// target and the object returned still conforms to `AudioDeviceDirectory`, so a caller determined
    /// to cast it back can. The rule is a composition rule, kept by review; the type keeps the mistake
    /// out of reach, not the intent.
    public var deviceReader: any AudioDeviceReading { directory }

    /// What Acta's **own recording** resolves against, readable without an actor hop.
    ///
    /// ⚠️ **Kept in step with the reconciler's priority, and separate from it.** The list is the same
    /// list — a user has one order of preference — but the two selections differ in eligibility
    /// (`canBeSystemDefault` filters the system default and not capture) and in lifetime (a recording
    /// pins at start, the system default is held continuously). Sharing the *value* and separating the
    /// *decision* is what keeps a menu that shows one order from lying about the other.
    public let capturePreference = CaptureMicrophonePreference()

    /// A resolver over the app's one reader. Handed to each recording by `liveSessionFactory`.
    public var captureResolver: any CaptureMicrophoneResolving {
        LiveCaptureMicrophoneResolver(reader: directory, preference: capturePreference)
    }

    /// Switch on management of the Mac's default input, **seeding the list if it is empty**.
    ///
    /// ⚠️ Seeding goes through `MicrophoneSeeding.seeded`, which refuses to overwrite an existing list,
    /// so a disable/re-enable cycle cannot cost a user their hand-made order.
    public func enableManagement() async -> [String] {
        // ⚠️ Only the *proposal* is computed here. Whether it is used at all is decided by the
        // reconciler against its own list, in one turn — see `MicrophoneReconciler.enable(seedingWith:)`.
        // Seeding from `capturePreference` and writing the result back lost an explicit priority edit
        // that arrived in between.
        let proposal = MicrophoneSeeding.proposal(from: inventory.devices,
                                                  systemDefault: inventory.observedDefault.uid)
        guard enforcementAdmitted else {
            await reconciler.configure(order: await reconciler.priority.order, enabled: false)
            managementEnabled = await reconciler.isEnabled
            await syncCapturePreference()
            return await reconciler.priority.order
        }
        let seeded = await reconciler.enable(seedingWith: proposal)
        managementEnabled = await reconciler.isEnabled
        await syncCapturePreference()
        return seeded
    }

    /// Whether feature (B) is in force, readable **synchronously on the main actor**.
    ///
    /// ⚠️ **A mirror, and named as one.** It is assigned from the reconciler at the end of every
    /// operation here that can change enablement — and the honest caveat is that "every" is a claim
    /// about this file that only review keeps true. An earlier version left it `true` after
    /// `stopEnforcement()` had disabled the reconciler; the paths are enumerated rather than derived, so
    /// a new one that forgets is a silent lie. It is **not** a substitute for `reconciler.isEnabled`
    /// where the answer must be authoritative rather than synchronous.
    ///
    /// ⚠️ **Synchronous is the requirement, not a convenience.** Its one consumer writes it into a
    /// `RecordingSettings` value that it has just read and is about to write back; an `await` in the
    /// middle of that read-modify-write is a window in which another main-actor edit lands and is then
    /// overwritten. A measured 15 runs in 20 lost a capture-choice change that way. So the value is
    /// mirrored here, updated from the reconciler at the end of every operation that can change it,
    /// rather than being fetched at the moment it is needed.
    ///
    /// ⚠️ Not the same as `enforcement.status != .disabled`: that is a *published* mirror driven by a
    /// deduplicated stream and lags the `configure` that has just returned. This one is assigned after
    /// the await, from the reconciler itself.
    public private(set) var managementEnabled = false

    public func disableManagement() async {
        // ⚠️ **No order is supplied, and that is the fix.** Passing `capturePreference.priority.order`
        // made switching the feature off a *writer* of the list: a priority edit that reached the
        // reconciler while this copy was in hand was replaced by the stale one, losing the user's
        // microphone 20 times out of 20. Switching enforcement off has no business replacing the list,
        // and the reconciler already owns it — the same lesson as `enable(seedingWith:)`, from the other
        // direction.
        await reconciler.disable()
        managementEnabled = await reconciler.isEnabled
        await syncCapturePreference()
    }

    /// Whether recordings follow the priority list or start from the system default.
    ///
    /// ⚠️ **Independent of feature (B).** Pausing or disabling enforcement of the *system* default must
    /// not change what Acta records from: they are different promises and the plan forbids sharing a
    /// switch between them.
    public func setCaptureChoice(_ choice: CaptureMicrophoneChoice) {
        capturePreference.set(.init(priority: capturePreference.priority, choice: choice))
    }

    /// Apply the persisted settings: the priority list, the capture choice, and whether feature (B) is
    /// on.
    ///
    /// ⚠️ **Both halves move together and neither is derived from the other.** The list is shared; the
    /// enable flag governs only the *system default*, so a user with (B) off still gets their recording
    /// pinned to their preferred microphone. Applying one without the other is how the two promises
    /// start sharing a switch, which the plan forbids.
    public func apply(_ settings: RecordingSettings) async {
        settingsRevision &+= 1
        let revision = settingsRevision
        let epoch = lifetimeEpoch

        // ⚠️ **Admission, before any side effect.** Checking only *after* `configure` meant a queued
        // application could still reach the OS: shut the manager down, let a queued `saveSettings` land,
        // and it wrote the system default and only then disabled. Disabling afterwards does not make
        // that write acceptable — the point of shutting down is that nothing further is written.
        guard started else { return }

        // ⚠️ **One coherent operation, not "set the list, then flip the switch".** Applying a
        // configuration in which feature (B) is *off* used to set the order while the reconciler was
        // still enabled — so switching the feature off wrote the Mac's default input on its way out.
        // It also gave a stale application a second step to run late and re-enable enforcement after a
        // newer one had settled.
        // ⚠️ Enforcement is admitted, not merely current. A queued save that starts after the quit
        // sequence began applies its list and leaves the feature off.
        await reconciler.configure(order: settings.microphonePriority,
                                   enabled: settings.managesSystemDefaultInput && enforcementAdmitted)

        // ⚠️ **Checked after the await, not only before it.** A newer application may have settled while
        // this one was suspended, and an older one must not have the last word.
        guard revision == settingsRevision, epoch == lifetimeEpoch, started else {
            // If this stale application turned enforcement on after its owner stopped, turn it back
            // off. That issues no OS write — an already-issued write cannot be undone by pretending it
            // did not happen — it only stops any *further* one.
            if epoch != lifetimeEpoch || !started, await reconciler.isEnabled {
                await reconciler.disable()
            }
            return
        }

        // Read back, and as one value: the reconciler owns the priority (it expires a stale override),
        // and a per-field write is how the list and the choice come from different revisions.
        //
        // ⚠️ **This read is a second suspension**, and the check above does not cover it: a newer
        // application can settle while it is in flight, and this one would then publish its older
        // `choice` on top. Rechecked below, after the value is in hand and before anything is published.
        let priority = await reconciler.priority
        let enabled = await reconciler.isEnabled
        guard revision == settingsRevision, epoch == lifetimeEpoch, started else { return }
        managementEnabled = enabled
        capturePreference.set(.init(priority: priority, choice: settings.captureMicrophoneChoice))
    }

    /// Apply settings as **owned, ordered work**.
    ///
    /// ⚠️ **The callers used to fire unowned `Task`s**, so nothing sequenced two saves against each
    /// other and nothing could wait for one at shutdown. Chaining them here gives both: applications run
    /// in the order they were requested, and `shutdown()` can join the last one instead of racing it.
    public func applySettings(_ settings: RecordingSettings) {
        let previous = applyTask
        applyTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.apply(settings)
        }
    }

    /// Apply **one changed field**, on the same ordered queue.
    ///
    /// ⚠️ **This exists because replaying a whole captured `RecordingSettings` is a write of every
    /// microphone setting, by anyone who saves anything.** A queued snapshot is stale by construction:
    /// one captured while the feature was on wrote the Mac's input again *after* the user had switched
    /// it off, and the withdrawal's own save carried the pre-edit priority list and put it back — both
    /// measured by review. Changing `api.settings` synchronously cannot fix that, because the stale
    /// value was already captured.
    ///
    /// So a save from a control says what it **changed**, and nothing else is replayed. The whole-value
    /// `applySettings` stays for the two places where the whole value genuinely is the intent: the
    /// launch application, and a client setting settings over the control protocol.
    public func apply(_ field: RecordingSettings.Field) {
        let previous = applyTask
        applyTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.applyIntent(field)
        }
    }

    private func applyIntent(_ field: RecordingSettings.Field) async {
        // Admission first, as in `apply(_:)`: a save requested before Quit must not reach the OS after.
        guard started else { return }
        switch field {
        case .microphonePriority(let order):
            await reconciler.setOrder(order)
            await syncCapturePreference()
        case .managesSystemDefaultInput(let on):
            if on, enforcementAdmitted {
                await reconciler.enable()
            } else {
                await reconciler.disable()
            }
            managementEnabled = await reconciler.isEnabled
            await syncCapturePreference()
        case .captureMicrophoneChoice(let choice):
            setCaptureChoice(choice)
        case .archivePath, .segmentSeconds, .deleteSegmentsAfterAssembly:
            // Nothing here owns these. ⚠️ Enumerated rather than defaulted, so a new microphone field
            // that forgets to be handled fails to compile instead of going quiet.
            break
        }
    }

    private var applyTask: Task<Void, Never>?

    /// The revision of the most recent settings application. ⚠️ Bumped before the first await so every
    /// continuation can tell whether it is still the current intent.
    private var settingsRevision: UInt64 = 0

    /// Copy the reconciler's authoritative priority into the capture preference.
    ///
    /// ⚠️ **Called by every command that changes it, and not left to the state mirror.** The mirror is
    /// driven by a **deduplicated** enforcement-status stream: with feature (B) off, editing the list
    /// republishes the same `.disabled` state, nothing is emitted, and the capture preference never
    /// updates at all — so a user with (B) off could reorder their microphones and Acta would go on
    /// recording from the old one, permanently. That is not a slow hop; it is a hole.
    private func syncCapturePreference() async {
        capturePreference.set(.init(priority: await reconciler.priority,
                                    choice: capturePreference.choice))
    }

    public private(set) var inventory: MicrophoneInventory = .unknown
    public private(set) var enforcement: MicrophoneEnforcementState = .disabled

    private var observation: (any AudioDeviceObservation)?
    private var observationDegraded: String?
    private var wakeObserver: (any NSObjectProtocol)?

    /// Bumped by `shutdown()`.
    ///
    /// ⚠️ **Cancelling a task does not withdraw a value it has already been handed.** The mirror can be
    /// suspended holding a state it received before cancellation, resume afterwards, and publish it into
    /// a manager that has shut down — or into a restarted one's streams. Cancellation closes the tap;
    /// this fences what is already in the pipe.
    private var lifetimeEpoch: UInt64 = 0
    private var enforcementMirror: Task<Void, Never>?
    private var started = false

    private var inventoryContinuations: [UUID: AsyncStream<MicrophoneInventory>.Continuation] = [:]
    private var enforcementContinuations: [UUID: AsyncStream<MicrophoneEnforcementState>.Continuation] = [:]

    public init(wiring: MicrophoneWiring) {
        // Called once, here, and the instances are held for the life of the app — see `MicrophoneWiring`.
        let directory = wiring.makeDirectory()
        let clock = wiring.makeClock()
        self.directory = directory
        self.clock = clock
        wakeCenter = wiring.makeWakeCenter()
        reconciler = MicrophoneReconciler(directory: directory, clock: clock)
    }

    // MARK: - Lifetime

    /// Begin monitoring. Called from `applicationDidFinishLaunching`, which is the only hook that fires
    /// before the user opens the menu: `MenuBarExtra(.window)` builds its content on the first click,
    /// so anything waiting for a view has already missed every device change until then.
    ///
    /// ⚠️ **Idempotent.** The menu is built and torn down every time it opens, and a second `start()`
    /// must neither duplicate the subscription nor restart anything.
    public func start() {
        guard !started else { return }
        started = true
        enforcementAdmitted = true
        subscribe()
        refreshInventory()
        mirrorEnforcement()
        observeWake()
    }

    /// The app-lifetime wake source. ⚠️ Sleep is the one interval during which the world changes with
    /// **no HAL notification delivered**, so the reconciler's `wake` trigger is useless without
    /// something to pull it — and until now nothing did: it existed as an endpoint with no caller.
    /// This is the app-lifetime owner, so this is where it belongs.
    ///
    /// ⚠️ Not verified automatically: no test sleeps a Mac. What a test can reach is that the observer
    /// is installed while monitoring and removed on shutdown.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        let epoch = lifetimeEpoch
        wakeObserver = wakeCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // ⚠️ The same fence the inventory callback carries, and for the same reason: removing
                // the observer stops *future* notifications and does nothing about a Task this one has
                // already queued. Without it a wake delivered just before shutdown re-enumerates and
                // republishes in the middle of it.
                guard let self, self.lifetimeEpoch == epoch, self.started else { return }
                self.refreshInventory()
                await self.reconciler.wake()
            }
        }
    }

    /// Whether the wake source is installed. Test-facing: the notification itself cannot be produced.
    var isObservingWake: Bool { wakeObserver != nil }

    /// Stop writing the system default, and **wait until that is true**.
    ///
    /// ⚠️ Separate from `shutdown()` and ordered before it in the quit flow, because read-only
    /// monitoring is still wanted while a recording finishes: what must stop first is the half that
    /// changes state other applications depend on.
    public func stopEnforcement() async {
        // ⚠️ **A latch, not a revision bump, and that distinction is the defect.** Bumping the revision
        // invalidates applications that are already *running*; it says nothing about one still sitting
        // in the queue, which starts later, bumps the revision itself, sees the manager still started —
        // quitting keeps read-only monitoring alive through the assembly — and enables enforcement
        // again. Two saves requested before Quit are enough: the second one wrote the system default
        // after `stopEnforcement` had returned, with no user action after Quit at all.
        enforcementAdmitted = false
        settingsRevision &+= 1
        await reconciler.disable()
        managementEnabled = await reconciler.isEnabled
    }

    /// Whether a settings application may still turn enforcement **on**.
    ///
    /// Closed at the first quit boundary and never reopened by an application — only by `start()`.
    /// Read-only monitoring is deliberately unaffected: the recording still needs the device inventory
    /// while it finishes assembling.
    private var enforcementAdmitted = true

    /// Stop this app's consumers of the directory, and **wait until that is true**.
    ///
    /// ⚠️ **It is `async` because the old synchronous version was a lie.** It kicked off
    /// `Task { await reconciler.disable() }` and returned; the reconciler still held its subscription,
    /// and a device change arriving in that window produced a corrective write *after* shutdown had
    /// supposedly finished. An unstructured task is not a guarantee, and `waitForQuiescence()` cannot
    /// stand in for one — it waits for passes, not for a `disable` that has not begun.
    ///
    /// ⚠️ **It does not unregister the raw HAL listeners, and must not be described as if it did.**
    /// `CoreAudioDeviceDirectory` removes its `AudioObjectAddPropertyListenerBlock` registrations only
    /// in `deinit`; cancelling a subscription removes a *subscriber*. The manager and the reconciler
    /// keep the directory alive, and in production the manager is a singleton, so those registrations
    /// live until the process exits. **That is a deliberate ownership policy, not a necessity**: the
    /// manager owns the directory for the life of the app, so releasing the registrations early would
    /// mean tearing down an object that is still owned. ⚠️ An earlier version of this comment claimed a
    /// deliberate final close would amount to resurrecting teardown-on-last-subscriber. That was wrong —
    /// they are different operations, and nobody argued otherwise; the policy stands on ownership alone.
    /// What this does guarantee, awaited: nothing in Acta reads or writes through the directory
    /// afterwards.
    public func shutdown() async {
        // Fence first: everything below may be racing a value already in flight.
        lifetimeEpoch &+= 1
        started = false
        // Join the owned application work before stopping, so a queued save cannot run afterwards.
        let pending = applyTask
        applyTask = nil
        await pending?.value
        await stopEnforcement()
        // ⚠️ **Not redundant with `verify()`'s per-iteration guard — they stop different things.** The
        // guard prevents the next property *read* when verification resumes; this waits for the owned
        // pass to actually **finish**. Both leave the read count unchanged across shutdown, which is
        // why read-count assertions cannot tell them apart, and why I first recorded this line as
        // probably-redundant. `shutdownWaitsForTheOwnedPass` distinguishes them by holding the sleep:
        // without this line, shutdown returns while its own pass is still suspended. It is not free
        // either — it can wait out a remaining poll — and that is the cost of finishing what you own.
        //
        // It is legitimate at all only because `disable()` was awaited above: draining is meaningful
        // once no new work can be scheduled. The earlier mistake was reaching for it to wait on a
        // `disable` that had not begun, which is a different thing and did not work.
        await reconciler.waitForQuiescence()
        observationDegraded = nil
        observation?.cancel()
        observation = nil
        if let wakeObserver {
            wakeCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        // Cancel *and join*: a cancelled task that has not yet run its final turn is not a stopped one.
        enforcementMirror?.cancel()
        await enforcementMirror?.value
        enforcementMirror = nil
        for continuation in inventoryContinuations.values { continuation.finish() }
        inventoryContinuations.removeAll()
        for continuation in enforcementContinuations.values { continuation.finish() }
        enforcementContinuations.removeAll()
    }

    private func subscribe() {
        guard started, observation == nil else { return }
        let epoch = lifetimeEpoch
        switch directory.observe({ [weak self] change in
            // ⚠️ **Taken here, in the delivery, for the reason the reconciler's inbox is.** The main
            // actor may be busy for an arbitrary interval, and a device that leaves and returns inside
            // it is simply present again by the time this refresh runs — so a departure the OS really
            // did report becomes invisible, and a *Use now* the user is no longer wearing survives.
            // With feature (B) off the reconciler is unsubscribed by design, so this is the **only**
            // observer, and the capture promise cannot depend on permission to enforce globally.
            let observed: DeviceEnumeration? = change == .deviceListChanged
                ? self?.directory.enumerateInputDevices()
                : nil
            // Tagged where the change was delivered, so the actor can order it against a *Use now*
            // issued afterwards.
            let seq = self?.reconciler.observationSequence.mint() ?? 0
            Task { @MainActor in
                guard let self, self.lifetimeEpoch == epoch, self.started else { return }
                // ⚠️ **`observationDegraded` is not just another reason to re-read.** It says the
                // subscription is live but *incomplete* — a per-device readiness listener could not be
                // installed — so the transition that listener existed to catch will never arrive.
                // Treating it as a plain refresh request republishes a clean inventory and the one
                // failure that announces itself in no other way disappears.
                if case .observationDegraded(let reason) = change { self.observationDegraded = reason }
                await self.expireCaptureOverrideIfDeparted(observed: observed, at: seq)
                self.refreshInventory(observed: observed)
            }
        }) {
        case .observing(let subscription):
            observation = subscription
            observationDegraded = nil
        case .failed(let reason):
            // ⚠️ Recorded, not swallowed: a manager that registered nothing looks exactly like a
            // machine where no device is ever plugged in.
            observationDegraded = reason
        }
    }

    // MARK: - Inventory

    /// Re-read the world. Every change notification lands here, and so does `start()`.
    public func refreshInventory() { refreshInventory(observed: nil) }

    /// - Parameter observed: the device list as it looked when a change was **delivered**, when there
    ///   was one. Consulted for departures before the fresh read below, which may already have missed
    ///   them.
    public func refreshInventory(observed: DeviceEnumeration?) {
        // ⚠️ Retried here, not only at `start()`. A registration that failed once must not leave the
        // manager permanently blind — the reconciler retries on every pass for the same reason.
        subscribe()
        var next = MicrophoneInventory()
        next.observationDegraded = observationDegraded
        switch directory.enumerateInputDevices() {
        case .devices(let devices, let uninspectable):
            next.devices = devices
            next.uninspectable = uninspectable
        case .failed(let reason):
            // ⚠️ The previous devices are kept. "I could not look" is not "they went away", and the
            // menu must not empty itself because one query failed.
            next.devices = inventory.devices
            next.uninspectable = inventory.uninspectable
            next.failure = reason
        }
        switch directory.currentDefaultInput() {
        case .device(let uid): next.observedDefault = .device(uid: uid)
        case .none: next.observedDefault = .noDefault
        case .failed(let reason):
            next.observedDefault = inventory.observedDefault
            next.failure = next.failure ?? reason
        }
        guard next != inventory else { return }
        inventory = next
        publishInventory()
    }

    /// Retire a *Use now* whose device has been **proved** to have left.
    ///
    /// ⚠️ **Here and not only in the reconciler**, because with feature (B) off the reconciler is
    /// unsubscribed and its pass returns before expiry ever runs — so a capture override outlived its
    /// headset forever, and Acta went on trying to record from a device that had gone. Acta's own
    /// capture selection is a different promise from managing the Mac's default input, and the plan
    /// forbids it depending on that permission.
    ///
    /// ⚠️ **It clears the override on the reconciler, not just in the capture box, and clearing only
    /// one of them is a bug I wrote and the test caught.** The reconciler owns the priority; every sync
    /// copies it back. Expiring the capture copy alone meant the very next status change restored the
    /// override from the reconciler that still held it — the override came back from the dead.
    ///
    /// Absence is proved, never inferred: an incomplete snapshot leaves the override alone.
    private func expireCaptureOverrideIfDeparted(observed: DeviceEnumeration?, at seq: UInt64) async {
        guard let override = capturePreference.priority.override else { return }
        guard case .devices(let devices, let uninspectable) = observed, uninspectable.isEmpty else { return }
        guard !devices.contains(where: { $0.uid == override }) else { return }
        // ⚠️ **Ordered against *Use now*, not merely applied.** A removal delivered before the user
        // picked a device describes a world that predates their choice; retiring the choice with it is
        // the same bug the reconciler's inbox was built to prevent, and a second expiry path that
        // ignored the ordering would reintroduce it here.
        guard await reconciler.expireOverride(override, observedAt: seq) else { return }
        await syncCapturePreference()
    }

    public func inventories() -> AsyncStream<MicrophoneInventory> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            inventoryContinuations[id] = continuation
            continuation.yield(inventory)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.inventoryContinuations[id] = nil }
            }
        }
    }

    private func publishInventory() {
        for continuation in inventoryContinuations.values { continuation.yield(inventory) }
    }

    // MARK: - Enforcement, mirrored onto the main actor

    /// The reconciler is an actor and the menu is not, so its state is mirrored here rather than
    /// awaited on every read. ⚠️ The mirror is the *only* copy the UI sees; the reconciler stays the
    /// source of truth, exactly as `ControlAPI` keeps `RecordingController` as its own.
    private func mirrorEnforcement() {
        guard enforcementMirror == nil else { return }
        let reconciler = reconciler
        let epoch = lifetimeEpoch
        enforcementMirror = Task { @MainActor [weak self] in
            for await state in await reconciler.states() {
                // ⚠️ The boundary that actually fixed publishing-after-shutdown is `shutdown()`
                // **joining** this task, not this check — a joined task cannot publish afterwards
                // whatever it is holding. The check is here so an old mirror can never publish into a
                // *restarted* manager's streams, which joining alone does not prevent.
                guard let self, self.lifetimeEpoch == epoch else { return }
                // The reconciler owns the priority — it expires a stale override — so capture reads it
                // back from there rather than keeping a second copy that drifts.
                // Keeps capture in step with an expiry the reconciler made on its own (an override's
                // device disconnecting). ⚠️ Not the *only* path — see `syncCapturePreference`: this
                // stream is deduplicated, so a change that leaves the status identical emits nothing.
                await syncCapturePreference()
                enforcement = state
                for continuation in enforcementContinuations.values { continuation.yield(state) }
            }
        }
    }

    public func enforcementStates() -> AsyncStream<MicrophoneEnforcementState> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            enforcementContinuations[id] = continuation
            continuation.yield(enforcement)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.enforcementContinuations[id] = nil }
            }
        }
    }

    // MARK: - Commands

    /// Feature (B) on. ⚠️ Opt-in and off by default: it changes state every other application depends
    /// on.
    // ⚠️ These assign `managementEnabled` for the same reason `enableManagement` does: a mirror that
    // only some of the paths that change enablement update is a mirror that lies on the others. A
    // review found `stopEnforcement()` leaving it `true` while the reconciler was disabled.
    public func enableEnforcement() async {
        await reconciler.enable()
        managementEnabled = await reconciler.isEnabled
    }

    public func disableEnforcement() async {
        await reconciler.disable()
        managementEnabled = await reconciler.isEnabled
    }

    /// ⚠️ Pause suspends **global enforcement only**. Acta's own capture selection is a different
    /// promise and must not share this switch.
    public func pauseEnforcement() async { await reconciler.pause() }
    public func resumeEnforcement() async { await reconciler.resume() }

    public func setPriorityOrder(_ order: [String]) async {
        await reconciler.setOrder(order)
        await syncCapturePreference()
    }

    public func useNow(uid: String) async {
        await reconciler.useNow(uid: uid)
        await syncCapturePreference()
    }

    public func resumeAutomaticSelection() async {
        await reconciler.resumeAutomaticSelection()
        await syncCapturePreference()
    }
    public func wake() async { await reconciler.wake() }
}
