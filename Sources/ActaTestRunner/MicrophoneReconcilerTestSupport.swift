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
/// ⚠️ **A private notification centre per manager, never the real workspace one.** The wake handler is
/// perfectly testable with a synthetic post — the claim that it needed a sleeping Mac was wrong — but a
/// post into `NSWorkspace.shared.notificationCenter` would reach every manager alive in the process,
/// including other tests running in parallel.
@MainActor
func makeTestMicrophoneManager(
    devices: [AudioInputDevice] = [],
    defaultInput: String? = nil
) -> (FakeAudioDeviceDirectory, TestClock, NotificationCenter, MicrophoneManager) {
    let directory = FakeAudioDeviceDirectory(devices: devices, defaultInput: defaultInput)
    let clock = TestClock()
    let center = NotificationCenter()
    let manager = MicrophoneManager(wiring: MicrophoneWiring(makeDirectory: { directory },
                                                             makeClock: { clock },
                                                             makeWakeCenter: { center }))
    return (directory, clock, center, manager)
}

/// Wait for the manager's **own notification path** to produce an inventory satisfying `predicate`.
///
/// ⚠️ **The bounded failure path is the point.** A test that pulls `refreshInventory()` itself and then
/// asserts on the result proves the enumeration works and says nothing about whether the subscription
/// delivered anything — replace the whole notification body with a no-op and it still passes. This
/// waits for the delivery instead, and returns `nil` rather than hanging when it never comes.
@MainActor
func awaitInventory(_ manager: MicrophoneManager,
                    timeout: Duration = .seconds(2),
                    until predicate: @escaping @Sendable (MicrophoneInventory) -> Bool) async
    -> MicrophoneInventory? {
    // The stream is taken here, on the main actor; iterating it needs no isolation.
    let stream = manager.inventories()
    return await withTaskGroup(of: MicrophoneInventory?.self) { group in
        group.addTask {
            for await inventory in stream where predicate(inventory) { return inventory }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// The enforcement equivalent of `awaitInventory`, with the same bounded failure path.
@MainActor
func awaitEnforcement(_ manager: MicrophoneManager,
                      timeout: Duration = .seconds(2),
                      until predicate: @escaping @Sendable (MicrophoneEnforcementState) -> Bool) async
    -> MicrophoneEnforcementState? {
    let stream = manager.enforcementStates()
    return await withTaskGroup(of: MicrophoneEnforcementState?.self) { group in
        group.addTask {
            for await state in stream where predicate(state) { return state }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Occupy the main actor synchronously for `milliseconds`, so no queued task can start.
///
/// ⚠️ **A busy wait, deliberately, and the only thing that makes an "it finished before returning"
/// assertion mean anything.** An unstructured `Task { ... }` created inside a `@MainActor` method
/// inherits the main actor, so it runs at the *next* suspension — and any incidental `await` in the
/// code under test, or in the test itself, hands it that suspension and rescues the bug. Blocking the
/// main actor removes the rescue: whatever has not happened by the time this returns genuinely had not
/// happened when the awaited call returned. `Task.sleep` would do the opposite of what is needed here.
@MainActor
func holdMainActor(milliseconds: Int = 40) {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds) * 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline { /* deliberately spinning */ }
}

/// A `@Sendable` slot for a number a closure has to hand back to its test.
final class IntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    func set(_ value: Int) { lock.lock(); stored = value; lock.unlock() }
    var value: Int? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// A clock whose sleeps can be **held**, so a test can stand a consumer still inside one.
///
/// ⚠️ **`TestClock` cannot express this and that is why the drain looked untestable.** Its sleep costs
/// a fixed 200 µs of real time, so "is the owned pass still suspended right now?" is a race there — and
/// with only that clock, removing `shutdown()`'s drain fails nothing: the guard inside `verify()`
/// already prevents the *read*, which is all the read-count tests can see. Holding the sleep separates
/// the two properties: the guard stops the next read, the drain waits for the pass to actually finish.
final class GatedClock: SelfCheckClock, @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0
    private var held = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    var now: Double { lock.lock(); defer { lock.unlock() }; return seconds }

    /// Park every sleep from now on instead of returning from it.
    func hold() { lock.lock(); held = true; lock.unlock() }

    /// Let everything parked go, and stop parking.
    func release() {
        lock.lock()
        held = false
        let waiting = parked
        parked.removeAll()
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    /// Whether a sleeper is parked right now.
    var isHoldingSleeper: Bool { lock.lock(); defer { lock.unlock() }; return !parked.isEmpty }

    func sleep(for duration: Double) async {
        let shouldPark: Bool = {
            lock.lock()
            defer { lock.unlock() }
            seconds += duration
            return held
        }()
        guard shouldPark else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            if held {
                parked.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }
}

/// Wait until `condition` holds, or give up. Bounded so a regression fails instead of hanging.
@MainActor
/// ⚠️ **The default stays short on purpose.** Several callers use this bound to assert an *absence* —
/// "the forbidden thing did not happen within it" — and raising it globally makes every one of those
/// wait longer for nothing. A caller waiting for something that must arrive raises its own bound.
/// ⚠️ **The default bound is five seconds, and the number was measured rather than chosen.** At two
/// seconds the suite was 2 failing runs in 12 as soon as twenty more tests joined the parallel pool —
/// not because anything they test is slow (the work in them benchmarks under 50 ms in total) but
/// because swift-testing runs suites concurrently, and a main-actor hop chain waiting on a pool that
/// twenty more tasks are sharing does not always complete inside two seconds. The control that
/// established it: the same production changes with those twenty tests removed failed 0 runs in 12.
///
/// A bound exists so a broken test **fails instead of hanging**; it is not a performance assertion,
/// and five seconds still fails fast. Anything that genuinely needs longer says so at the call site.
func awaitCondition(timeoutMilliseconds: Int = 5000,
                    _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() { return true }
        // ⚠️ **A short sleep, not `Task.yield()`.** Yielding keeps this task on a cooperative thread and
        // re-queues it immediately, so a waiter spins hot — and on a loaded machine it starves the very
        // work it is waiting for, turning a correct test into an intermittent one. Sleeping hands the
        // thread back. The bound is unchanged; only the waiting is.
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

/// The same bounded wait, for a condition that must be **asked of an actor**. A sync closure cannot
/// await, and sampling an actor's state through a cached mirror is how a test ends up asserting on a
/// value that lags the thing it is checking.
func awaitAsyncCondition(timeoutMilliseconds: Int = 5000,
                         _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() { return true }
        // The same reason as above: a hot spin starves what it waits for.
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

/// Block the calling thread until `semaphore` is signalled, bounded.
///
/// ⚠️ **Deliberately blocking, and deliberately not `async`.** `DispatchSemaphore.wait` is unavailable
/// from an async context for good reasons, and this wrapper exists for the one situation where blocking
/// is the point: a test that must let an actor finish its work while **holding the main actor**, so that
/// a continuation waiting for the main actor is provably pending rather than merely unscheduled. Every
/// `await` would hand the main actor over and destroy the very state being arranged.
///
/// Only safe when the work being waited on does not itself need the main actor — check that before
/// reaching for this — and always bounded, so a mistake fails the test instead of hanging the suite.
func blockUntilSignalled(_ semaphore: DispatchSemaphore, seconds: Double = 2) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}

/// A scripted `CaptureMicrophoneResolving`.
///
/// ⚠️ **What it cannot prove, stated here rather than discovered later.** It hands back a uid and the
/// fake source accepts any string; whether ScreenCaptureKit accepts a given
/// `microphoneCaptureDeviceID` — or records from the device it names — is unverified in-process, for
/// exactly the reason `SCKCaptureSource`'s teardown is. That gap is in the plan's manual section.
final class FakeCaptureMicrophoneResolver: CaptureMicrophoneResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var resolution: CaptureMicrophoneResolution
    private var calls = 0

    init(_ resolution: CaptureMicrophoneResolution = .pinned(.builtInMic(), alternatives: [])) {
        self.resolution = resolution
    }

    /// Change what the *next* resolve answers — a priority edit, a `Use now`, a device disappearing.
    func set(_ next: CaptureMicrophoneResolution) { lock.lock(); resolution = next; lock.unlock() }

    /// How many times it was asked. A recorder that resolves once and reuses the answer across a
    /// restart is a recorder no priority change can ever reach.
    var resolveCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func resolve() -> CaptureMicrophoneResolution {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return resolution
    }
}

/// A barrier a test can park an actor on and release later.
///
/// ⚠️ It exists because two of the loss-watch properties are **orderings**, and a test that cannot pin
/// the order does not reach the branch it is about — mine passed twice against the bugs they were
/// written for before this existed.
final class TestBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Whether something is parked on it right now.
    var isEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }

    func release() {
        lock.lock()
        open = true
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    func wait() async {
        let shouldPark: Bool = { lock.lock(); defer { lock.unlock() }; entered = true; return !open }()
        guard shouldPark else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            if open { lock.unlock(); continuation.resume() } else { waiters.append(continuation); lock.unlock() }
        }
    }
}
