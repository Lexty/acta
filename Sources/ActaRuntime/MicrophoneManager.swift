import ActaKit
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

    public init(makeDirectory: @escaping @Sendable () -> any AudioDeviceDirectory,
                makeClock: @escaping @Sendable () -> any SelfCheckClock) {
        self.makeDirectory = makeDirectory
        self.makeClock = makeClock
    }

    /// The production wiring: the real HAL, real time.
    public static let live = MicrophoneWiring(
        makeDirectory: { CoreAudioDeviceDirectory() },
        makeClock: { SystemClock() }
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
/// Putting it in `RecordingDependencies` would mint one enforcer per recording session — several of
/// them alive at once during a watchdog restart, each writing the same HAL property. The honest move
/// is to widen the rule with the lifetime distinction, which `CLAUDE.md` now records; it is **not** to
/// argue that the existing wording anticipated this.
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

    /// The reconciler, created once with the manager. It is *created* eagerly and *enabled* only on
    /// request: feature (B) is opt-in, and an object that exists is not an object that is writing.
    public let reconciler: MicrophoneReconciler

    /// The read-only half of the directory, for a recording's device selection and for the menu.
    ///
    /// ⚠️ A recording receives **this**, never the directory itself, and never constructs a reconciler.
    /// The type is what enforces it: `AudioDeviceReading` has no `setDefaultInput`.
    public var deviceReader: any AudioDeviceReading { directory }

    public private(set) var inventory: MicrophoneInventory = .unknown
    public private(set) var enforcement: MicrophoneEnforcementState = .disabled

    private var observation: (any AudioDeviceObservation)?
    private var observationDegraded: String?
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
    }

    /// Release the HAL listeners. Not a `deinit`: this is a `@MainActor` singleton in production and
    /// its lifetime is the process, so the only honest teardown is an explicit one.
    public func shutdown() {
        started = false
        observationDegraded = nil
        observation?.cancel()
        observation = nil
        enforcementMirror?.cancel()
        enforcementMirror = nil
        let reconciler = reconciler
        Task { await reconciler.disable() }
        for continuation in inventoryContinuations.values { continuation.finish() }
        inventoryContinuations.removeAll()
        for continuation in enforcementContinuations.values { continuation.finish() }
        enforcementContinuations.removeAll()
    }

    private func subscribe() {
        guard started, observation == nil else { return }
        switch directory.observe({ [weak self] _ in
            Task { @MainActor in self?.refreshInventory() }
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
        enforcementMirror = Task { @MainActor [weak self] in
            for await state in await reconciler.states() {
                guard let self else { return }
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
