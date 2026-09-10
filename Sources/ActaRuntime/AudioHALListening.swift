import Foundation

/// What the directory watches, named without a single HAL type so the coordinator's lifecycle can be
/// driven from a test.
///
/// The device cases carry the HAL's own ephemeral object id, and that is the one place it is allowed
/// above the adapter — as an opaque token for "the device this registration is about", never as
/// identity. Identity is the UID; see `AudioInputDevice.uid`.
enum HALWatch: Hashable, Sendable {
    case deviceList
    case defaultInput
    case deviceAlive(UInt32)
    case deviceStreams(UInt32)
}

/// One live registration. The implementation stores whatever removal needs; the coordinator only ever
/// hands it back.
protocol HALRegistration: AnyObject, Sendable {}

/// Why a registration could not be made.
struct HALRegistrationFailure: Error, Equatable, Sendable {
    let reason: String
}

/// The seam under `CoreAudioDeviceDirectory`'s **lifecycle** — listener registration and the device
/// identities the readiness refresh works from. Property reading stays in the adapter: it has no
/// bookkeeping to get wrong.
///
/// ⚠️ **This exists because serialization is not correctness.** Collapsing the directory onto one queue
/// removed a whole matrix of possible schedules, but it proved nothing about what happens when the HAL
/// *refuses* a registration — whether the successful half of a partial install is removed, whether a
/// degraded subscription still reports itself, whether every retained registration is released when the
/// directory dies. Those are bookkeeping questions, and against the real HAL they are unreachable:
/// a working Mac does not refuse to register a listener on demand.
protocol AudioHALListening: AnyObject, Sendable {
    /// Register `fire` for `watch`. `fire` is called on `queue`.
    func add(_ watch: HALWatch,
             on queue: DispatchQueue,
             fire: @escaping @Sendable () -> Void) -> Result<any HALRegistration, HALRegistrationFailure>

    /// Remove a registration. Idempotent, and never fails: there is nothing a caller could do about it,
    /// and a teardown that can refuse is a teardown that leaks.
    func remove(_ registration: any HALRegistration)

    /// The devices the OS currently lists, with their UIDs where readable.
    ///
    /// ⚠️ `uid == nil` means the identity query failed for that device — **not** that it has no
    /// identity. The readiness refresh keeps such a device's listener rather than treating it as
    /// departed, because "I could not identify it" is not "it is gone".
    func listDevices() -> Result<[(id: UInt32, uid: String?)], HALRegistrationFailure>
}
