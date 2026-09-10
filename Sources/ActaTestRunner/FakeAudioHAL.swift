@testable import ActaRuntime
import Foundation

/// A scripted `AudioHALListening`, so the **production** coordinator's registration bookkeeping can be
/// driven through outcomes a working Mac will never produce on demand.
///
/// It models only what bookkeeping needs: which registrations are live, which were removed, and whether
/// a given watch is allowed to register at all.
final class FakeAudioHAL: AudioHALListening, @unchecked Sendable {
    final class Registration: HALRegistration, @unchecked Sendable {
        let watch: HALWatch
        let queue: DispatchQueue
        let fire: @Sendable () -> Void
        init(watch: HALWatch, queue: DispatchQueue, fire: @escaping @Sendable () -> Void) {
            self.watch = watch
            self.queue = queue
            self.fire = fire
        }
    }

    private let lock = NSLock()
    private var live: [ObjectIdentifier: Registration] = [:]
    /// Every registration ever made, **including removed ones**. A real HAL callback can already be in
    /// flight when its registration is removed, so a test has to be able to invoke one afterwards; a
    /// fake that forgot removed registrations could only ever fire into a live directory, which makes
    /// the "callback outlives its owner" case unreachable and its test a tautology.
    private var everRegistered: [Registration] = []
    private var refusals: [HALWatch: String] = [:]
    private var devices: [(id: UInt32, uid: String?)] = []
    private var listFailure: String?
    private var removalRefusals: [HALWatch: String] = [:]

    private var addedWatches: [HALWatch] = []
    private var removedWatches: [HALWatch] = []

    // MARK: - Scripting

    func refuse(_ watch: HALWatch, reason: String = "scripted refusal") {
        lock.lock(); refusals[watch] = reason; lock.unlock()
    }

    func setDevices(_ devices: [(id: UInt32, uid: String?)]) {
        lock.lock(); self.devices = devices; lock.unlock()
    }

    func failDeviceList(reason: String) { lock.lock(); listFailure = reason; lock.unlock() }

    /// Every watch ever registered, and every one ever removed — in order. Bookkeeping is the subject
    /// here, so both halves are recorded: "it registered and cleaned up" and "it never registered" are
    /// different outcomes and must not look alike.
    var added: [HALWatch] { lock.lock(); defer { lock.unlock() }; return addedWatches }
    var removed: [HALWatch] { lock.lock(); defer { lock.unlock() }; return removedWatches }
    var liveWatches: [HALWatch] { lock.lock(); defer { lock.unlock() }; return live.values.map(\.watch) }

    /// A delivery closure and the queue it belongs on, retained past removal — see `everRegistered`.
    func savedDelivery(for watch: HALWatch) -> (queue: DispatchQueue, fire: @Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        guard let registration = everRegistered.last(where: { $0.watch == watch }) else { return nil }
        return (queue: registration.queue, fire: registration.fire)
    }

    /// Deliver a callback exactly as the HAL would: on the queue the coordinator asked for.
    func fire(_ watch: HALWatch) {
        lock.lock()
        let targets = live.values.filter { $0.watch == watch }
        lock.unlock()
        for target in targets { target.queue.sync { target.fire() } }
    }

    // MARK: - AudioHALListening

    func add(_ watch: HALWatch,
             on queue: DispatchQueue,
             fire: @escaping @Sendable () -> Void) -> Result<any HALRegistration, HALRegistrationFailure> {
        lock.lock()
        addedWatches.append(watch)
        if let reason = refusals[watch] {
            lock.unlock()
            return .failure(HALRegistrationFailure(reason: reason))
        }
        let registration = Registration(watch: watch, queue: queue, fire: fire)
        live[ObjectIdentifier(registration)] = registration
        everRegistered.append(registration)
        lock.unlock()
        return .success(registration)
    }

    /// Scripted removal refusals, so the "the HAL declined to unregister" branch is reachable at all.
    /// A fake whose removals always succeed cannot exercise that boundary.
    func refuseRemoval(of watch: HALWatch, reason: String = "scripted removal refusal") {
        lock.lock(); removalRefusals[watch] = reason; lock.unlock()
    }

    @discardableResult
    func remove(_ registration: any HALRegistration) -> Result<Void, HALRegistrationFailure> {
        guard let registration = registration as? Registration else { return .success(()) }
        lock.lock()
        if let reason = removalRefusals[registration.watch] {
            lock.unlock()
            return .failure(HALRegistrationFailure(reason: reason))
        }
        live.removeValue(forKey: ObjectIdentifier(registration))
        removedWatches.append(registration.watch)
        lock.unlock()
        return .success(())
    }

    func listDevices() -> Result<[(id: UInt32, uid: String?)], HALRegistrationFailure> {
        lock.lock(); defer { lock.unlock() }
        if let listFailure { return .failure(HALRegistrationFailure(reason: listFailure)) }
        return .success(devices)
    }
}
