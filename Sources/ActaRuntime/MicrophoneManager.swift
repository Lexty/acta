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

    /// Whether recordings follow the priority list or start from the system default.
    ///
    /// ⚠️ **Independent of feature (B).** Pausing or disabling enforcement of the *system* default must
    /// not change what Acta records from: they are different promises and the plan forbids sharing a
    /// switch between them.
    public func setCaptureChoice(_ choice: CaptureMicrophoneChoice) {
        capturePreference.choice = choice
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
        await reconciler.disable()
    }

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
            Task { @MainActor in
                guard let self, self.lifetimeEpoch == epoch, self.started else { return }
                // ⚠️ **`observationDegraded` is not just another reason to re-read.** It says the
                // subscription is live but *incomplete* — a per-device readiness listener could not be
                // installed — so the transition that listener existed to catch will never arrive.
                // Treating it as a plain refresh request republishes a clean inventory and the one
                // failure that announces itself in no other way disappears.
                if case .observationDegraded(let reason) = change { self.observationDegraded = reason }
                self.refreshInventory()
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
    public func refreshInventory() {
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
                capturePreference.priority = await reconciler.priority
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
    public func enableEnforcement() async { await reconciler.enable() }
    public func disableEnforcement() async { await reconciler.disable() }

    /// ⚠️ Pause suspends **global enforcement only**. Acta's own capture selection is a different
    /// promise and must not share this switch.
    public func pauseEnforcement() async { await reconciler.pause() }
    public func resumeEnforcement() async { await reconciler.resume() }

    public func setPriorityOrder(_ order: [String]) async { await reconciler.setOrder(order) }
    public func useNow(uid: String) async { await reconciler.useNow(uid: uid) }
    public func resumeAutomaticSelection() async { await reconciler.resumeAutomaticSelection() }
    public func wake() async { await reconciler.wake() }
}
