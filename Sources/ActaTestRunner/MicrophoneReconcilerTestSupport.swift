import ActaKit
import ActaRuntime
import Foundation

/// A `@Sendable` counter for `TestClock.onSleep`, which cannot capture a mutable local.
final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A directory that **wins every race**: it accepts each write and restores its own choice before the
/// call returns, then reports the change.
///
/// ⚠️ **This is the competitor a verification read can never catch in the act**, and it is the reason
/// bounding candidates inside one reconciliation pass is not bounding enforcement. Acta's write is
/// accepted, so no write failure is visible; the default is already back before the first verification
/// read, so the write never visibly wins and no *reversal* is ever provable; and the notification that
/// restoration provokes starts the next pass. A reconciler that only counts reversals writes forever
/// against this.
///
/// It models a fast competing utility, not a human — a human is slower than the deadline. What both
/// have in common is the only thing that matters here: the OS says yes and the default ends up
/// somewhere else.
final class FightingAudioDeviceDirectory: AudioDeviceDirectory, @unchecked Sendable {
    private let inner: FakeAudioDeviceDirectory
    private let restoringTo: String
    private let reversalCap: Int

    private let lock = NSLock()
    private var reversals = 0
    private var capReached = false

    /// ⚠️ **Reaching the cap is itself a failure**, not a passing condition. It exists so a regression
    /// fails the test instead of hanging the suite: without it, an unbounded reconciler and this
    /// directory drive each other forever.
    var reversalCapReached: Bool { lock.lock(); defer { lock.unlock() }; return capReached }

    var attemptedWrites: [String] { inner.attemptedWrites }

    init(devices: [AudioInputDevice], restoringTo: String, reversalCap: Int) {
        inner = FakeAudioDeviceDirectory(devices: devices, defaultInput: restoringTo)
        self.restoringTo = restoringTo
        self.reversalCap = reversalCap
    }

    func enumerateInputDevices() -> DeviceEnumeration { inner.enumerateInputDevices() }

    func currentDefaultInput() -> DefaultInputRead { inner.currentDefaultInput() }

    func setDefaultInput(uid: String) -> DefaultInputWrite {
        let outcome = inner.setDefaultInput(uid: uid)
        guard case .written = outcome else { return outcome }

        lock.lock()
        let allowed = reversals < reversalCap
        if allowed { reversals += 1 } else { capReached = true }
        lock.unlock()
        guard allowed else { return outcome }

        // The whole point: restored before the caller can read anything back.
        inner.setDefaultInput(.device(uid: restoringTo))
        inner.emit(.defaultInputChanged)
        return outcome
    }

    func observe(_ handler: @escaping @Sendable (DeviceChange) -> Void) -> ObservationOutcome {
        inner.observe(handler)
    }
}

/// A `MicrophoneManager` over a scripted directory and a test clock — everything the real one is
/// except the HAL.
///
/// ⚠️ It exists so that no test ever touches `MicrophoneManager.shared`, which reaches the real
/// CoreAudio: the same rule `ControlAPI.shared` carries, and for the same reason.
@MainActor
func makeTestMicrophoneManager(
    devices: [AudioInputDevice] = [],
    defaultInput: String? = nil
) -> (FakeAudioDeviceDirectory, TestClock, MicrophoneManager) {
    let directory = FakeAudioDeviceDirectory(devices: devices, defaultInput: defaultInput)
    let clock = TestClock()
    let manager = MicrophoneManager(wiring: MicrophoneWiring(makeDirectory: { directory },
                                                             makeClock: { clock }))
    return (directory, clock, manager)
}
