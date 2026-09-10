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
    private var refusals: [HALWatch: String] = [:]
    private var devices: [(id: UInt32, uid: String?)] = []
    private var listFailure: String?

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
        lock.unlock()
        return .success(registration)
    }

    func remove(_ registration: any HALRegistration) {
        guard let registration = registration as? Registration else { return }
        lock.lock()
        live.removeValue(forKey: ObjectIdentifier(registration))
        removedWatches.append(registration.watch)
        lock.unlock()
    }

    func listDevices() -> Result<[(id: UInt32, uid: String?)], HALRegistrationFailure> {
        lock.lock(); defer { lock.unlock() }
        if let listFailure { return .failure(HALRegistrationFailure(reason: listFailure)) }
        return .success(devices)
    }
}
