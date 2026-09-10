import ActaKit
import ActaRuntime
import Foundation

/// A scripted `AudioDeviceDirectory`.
///
/// **What it must and must not promise.** The fake is only worth something if it behaves like
/// `CoreAudioDeviceDirectory`, so it honours the same contract: every operation reports failure
/// explicitly, observation is broadcast and independent per subscriber, and `cancel()` is idempotent.
/// A guarantee this fake makes and the real adapter does not is a bug **in the fake**.
///
/// What it deliberately does not model: the HAL itself. It never validates a uid against real hardware,
/// never rejects a device the OS would reject, and accepts any write the script allows. That is the
/// limit stated plainly rather than discovered later — `SCKCaptureSource`'s acceptance of a device id is
/// unverified in-process for exactly the same reason.
final class FakeAudioDeviceDirectory: AudioDeviceDirectory, @unchecked Sendable {
    private let lock = NSLock()

    private var enumeration: DeviceEnumeration
    private var defaultRead: DefaultInputRead
    /// Queued write outcomes, consumed in order; when empty, `writeFallback` answers. A queue rather
    /// than a single value so a test can script "the first write fails, the retry succeeds".
    private var writeOutcomes: [DefaultInputWrite] = []
    private var writeFallback: DefaultInputWrite = .written
    /// When set, `observe` reports this instead of subscribing — the third outcome that otherwise hides.
    private var observationFailure: String?

    private var subscribers: [UInt64: Gate] = [:]
    private var nextToken: UInt64 = 1

    /// The subscriber registry and every delivery live on this one serial queue, mirroring
    /// `CoreAudioDeviceDirectory`'s single execution domain. Being inside a block on it is the proof
    /// that no handler is running concurrently, which is what makes cancellation's guarantee hold
    /// without a separate drain step.
    ///
    /// ⚠️ **The key is per instance.** A shared static key answers "am I on my own queue?" with *yes*
    /// while standing on a different directory's queue, quietly skipping this one's serialization.
    private let coordinatorQueue = DispatchQueue(label: "fake.audio.devices.coordinator")
    private let coordinatorKey = DispatchSpecificKey<ObjectIdentifier>()

    /// A handler behind a gate — the same shape `CoreAudioDeviceDirectory.Subscriber` has, because a
    /// guarantee the fake makes and the real source does not is a bug in the fake, and so is the
    /// reverse. No lock: the coordinator queue is the lock.
    private final class Gate {
        var handler: (@Sendable (DeviceChange) -> Void)?
        init(_ handler: @escaping @Sendable (DeviceChange) -> Void) { self.handler = handler }
    }

    private func onCoordinator<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: coordinatorKey) == ObjectIdentifier(self) { return body() }
        return coordinatorQueue.sync(execute: body)
    }

    /// ⚠️ The diagnostics below are written under `lock` and must be **read** under it too. A
    /// synthesized getter on a `private(set) var` is an unsynchronized read, and reconciler tests drive
    /// this fake from more than one thread — the race would show up as a flaky count, which is worse
    /// than a wrong one because it is dismissed as flakiness.
    private var attemptedWritesStorage: [String] = []
    private var enumerationCountStorage = 0
    private var defaultReadCountStorage = 0

    /// Every write attempted, in order — including the ones the script failed, because "it tried and
    /// the OS refused" and "it never tried" are different bugs.
    var attemptedWrites: [String] { lock.lock(); defer { lock.unlock() }; return attemptedWritesStorage }
    /// How many times `enumerateInputDevices()` was called: a reconciler that never re-reads is a
    /// reconciler that diffs stale state.
    var enumerationCount: Int { lock.lock(); defer { lock.unlock() }; return enumerationCountStorage }
    /// How many times the default input was read. The contract says re-read immediately before writing.
    var defaultReadCount: Int { lock.lock(); defer { lock.unlock() }; return defaultReadCountStorage }

    init(devices: [AudioInputDevice] = [], defaultInput: String? = nil) {
        enumeration = .devices(devices, uninspectable: [])
        defaultRead = defaultInput.map { .device(uid: $0) } ?? DefaultInputRead.none
        coordinatorQueue.setSpecific(key: coordinatorKey, value: ObjectIdentifier(self))
    }

    // MARK: - Scripting

    func setDevices(_ devices: [AudioInputDevice], uninspectable: [String] = []) {
        lock.lock(); enumeration = .devices(devices, uninspectable: uninspectable); lock.unlock()
    }

    /// Make enumeration *fail*. Distinct from `setDevices([])`, and the pair of them is the point:
    /// "I could not look" must never be expressible as "there was nothing to find".
    func failEnumeration(reason: String) {
        lock.lock(); enumeration = .failed(reason: reason); lock.unlock()
    }

    func setDefaultInput(_ read: DefaultInputRead) {
        lock.lock(); defaultRead = read; lock.unlock()
    }

    func scriptWrites(_ outcomes: [DefaultInputWrite], thereafter fallback: DefaultInputWrite = .written) {
        lock.lock(); writeOutcomes = outcomes; writeFallback = fallback; lock.unlock()
    }

    func failObservation(reason: String) {
        lock.lock(); observationFailure = reason; lock.unlock()
    }

    /// Deliver a change to every current subscriber, exactly as the HAL listeners would.
    /// Call it twice with the same value to script a duplicate notification.
    func emit(_ change: DeviceChange) {
        onCoordinator {
            // Registration order, matching `CoreAudioDeviceDirectory.broadcast` — see the note there on
            // why an arbitrary dictionary order makes the cancellation guarantee untestable.
            let targets = subscribers.sorted { $0.key < $1.key }.map(\.value)
            for target in targets { target.handler?(change) }
        }
    }

    /// Deliver several changes in the given order — the way a test scripts "the default moved *before*
    /// the device appeared" and then the reverse, since the real ordering was measured to be
    /// unobservable at 0.4 s resolution.
    func emit(_ changes: [DeviceChange]) {
        for change in changes { emit(change) }
    }

    var subscriberCount: Int { onCoordinator { subscribers.count } }

    // MARK: - AudioDeviceDirectory

    func enumerateInputDevices() -> DeviceEnumeration {
        lock.lock(); defer { lock.unlock() }
        enumerationCountStorage += 1
        return enumeration
    }

    func currentDefaultInput() -> DefaultInputRead {
        lock.lock(); defer { lock.unlock() }
        defaultReadCountStorage += 1
        return defaultRead
    }

    func setDefaultInput(uid: String) -> DefaultInputWrite {
        lock.lock(); defer { lock.unlock() }
        attemptedWritesStorage.append(uid)
        let outcome = writeOutcomes.isEmpty ? writeFallback : writeOutcomes.removeFirst()
        // A successful write moves the fake's own default, so a verification read afterwards sees what
        // the OS would have shown. A test scripting a *fight* overrides the read explicitly.
        if case .written = outcome { defaultRead = .device(uid: uid) }
        return outcome
    }

    func observe(_ handler: @escaping @Sendable (DeviceChange) -> Void) -> ObservationOutcome {
        onCoordinator {
            lock.lock()
            let failure = observationFailure
            lock.unlock()
            if let failure { return .failed(reason: failure) }
            let token = nextToken
            nextToken += 1
            subscribers[token] = Gate(handler)
            return .observing(Subscription(token: token, owner: self))
        }
    }

    /// Cancellation, entirely on the coordinator — the same shape as the real adapter, where being
    /// inside this block is itself the proof that no handler is executing.
    fileprivate func remove(_ token: UInt64) {
        onCoordinator {
            subscribers[token]?.handler = nil
            subscribers.removeValue(forKey: token)
        }
    }

    private final class Subscription: AudioDeviceObservation, @unchecked Sendable {
        private let token: UInt64
        private weak var owner: FakeAudioDeviceDirectory?
        init(token: UInt64, owner: FakeAudioDeviceDirectory) {
            self.token = token
            self.owner = owner
        }

        /// ⚠️ **No "already cancelled" short-circuit**, matching the real adapter: an early return let a
        /// second caller leave while the first had not yet closed the gate, so `cancel()` returned
        /// without its guarantee holding.
        func cancel() { owner?.remove(token) }
    }
}

// MARK: - Fixtures

extension AudioInputDevice {
    /// The devices measured on the development machine, so the fixtures are not invented shapes.
    /// ⚠️ `blackHole` and `aggregate` are recorded with `canBeSystemDefault: .yes` **because that is
    /// what they measured** — it is tempting to assume a virtual device cannot be the default, and the
    /// machine says otherwise.
    static func builtInMic(alive: DeviceCapability = .yes) -> AudioInputDevice {
        AudioInputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                         transport: .builtIn, inputChannels: 1,
                         canBeSystemDefault: .yes, isAlive: alive, isRunningSomewhere: false)
    }

    static func airPods(alive: DeviceCapability = .yes) -> AudioInputDevice {
        AudioInputDevice(uid: "00-00-5E-00-53-01:input", name: "AirPods Pro",
                         transport: .bluetooth, inputChannels: 1,
                         canBeSystemDefault: .yes, isAlive: alive, isRunningSomewhere: false)
    }

    static func usbMic() -> AudioInputDevice {
        AudioInputDevice(uid: "USBAudioDevice_UID", name: "USB Microphone",
                         transport: .usb, inputChannels: 1,
                         canBeSystemDefault: .yes, isAlive: .yes, isRunningSomewhere: false)
    }

    static func blackHole() -> AudioInputDevice {
        AudioInputDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch",
                         transport: .virtual, inputChannels: 2,
                         canBeSystemDefault: .yes, isAlive: .yes, isRunningSomewhere: false)
    }

    static func teamsLoopback() -> AudioInputDevice {
        AudioInputDevice(uid: "MSLoopbackDriverDevice_UID", name: "Microsoft Teams Audio",
                         transport: .virtual, inputChannels: 2,
                         canBeSystemDefault: .no, isAlive: .yes, isRunningSomewhere: false)
    }

    static func aggregate() -> AudioInputDevice {
        AudioInputDevice(uid: "~:AMS2_Aggregate:0", name: "Aggregate Device",
                         transport: .aggregate, inputChannels: 2,
                         canBeSystemDefault: .yes, isAlive: .yes, isRunningSomewhere: false)
    }

    /// A device whose eligibility query failed — the shape the scope bug produced for the whole machine.
    static func unknownEligibility() -> AudioInputDevice {
        AudioInputDevice(uid: "MysteryDevice_UID", name: "Mystery Device",
                         transport: .usb, inputChannels: 1,
                         canBeSystemDefault: .unknown, isAlive: .yes, isRunningSomewhere: false)
    }
}
