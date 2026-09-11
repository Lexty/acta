import ActaControlProtocol
import ActaKit
import ActaRuntime
import Foundation
import Testing

// The fake and the fixtures the `ControlDispatcher` suites are driven with — a fake `ControlServing`,
// so no socket, no controller, no TCC and no wall clock are involved. That is the entire point of the
// narrow protocol: the policy that can be wrong (a busy `start`, honest immediate-vs-completion
// answers, `stopAndWait`'s ownership model, `watch`'s coalescing) is exercised before any descriptor
// code exists.
//
// Never `ControlAPI.shared`: it wraps `RecordingController.shared`, which reaches for the real `~/Acta`,
// real TCC and real time.
//
// Split out of the suites the way `ControllerTestSupport` is: the fixtures are shared by
// `ControlDispatcherTests` (the command mappings) and `ControlDispatcherStreamTests` (stopAndWait's
// ownership model and `watch`).

/// A scripted `ControlServing`: it records every access, lets a test set the state outright, and gates
/// `stopAndWait` on an explicit release so the in-flight window is a fact rather than a sleep.
@MainActor
@available(macOS 15.0, *)
final class FakeControlServing: ControlServing {
    /// What the dispatcher asked for, in order.
    private(set) var calls: [String] = []

    var currentState = ControlState()
    /// How many times `stopAndWait()` was actually entered — the count that distinguishes "shared one
    /// stop" from "started two".
    private(set) var stopAndWaitEntries = 0
    /// The URL `openInFinder(_:)` was handed, if any.
    private(set) var revealed: URL?

    private var storedTitle = ""
    private var storedSettings = RecordingSettings.default
    private var continuations: [UUID: AsyncStream<ControlState>.Continuation] = [:]
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    /// Hold `settleMicrophoneSettings()` open, so a test proves the dispatcher **waits** rather than
    /// merely getting lucky about scheduling. With this false the barrier returns at once, which is what
    /// every suite that is not about the barrier wants.
    var parksMicrophoneSettlement = false
    private var settlementWaiters: [CheckedContinuation<Void, Never>] = []
    /// How many callers are parked in the barrier right now — the evidence that it was entered, without
    /// which "nothing happened" is also what deleting the call looks like.
    var parkedInSettlement: Int { settlementWaiters.count }

    /// Let every parked caller out of the barrier.
    func releaseMicrophoneSettlement() {
        let waiting = settlementWaiters
        settlementWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    /// A scripted `states()` (see `scriptStates`) and how many times its consumer has pulled from it.
    private var scriptQueue: [ControlState]?
    private(set) var pulls = 0

    /// Subscriptions `states()` handed out that are still live — how the cancellation test observes that
    /// the pump let go of the upstream.
    var subscriberCount: Int { continuations.count }
    /// Whether a `stopAndWait()` is parked inside the fake right now.
    var stopIsInFlight: Bool { !stopWaiters.isEmpty }
    /// How many times `state` has been read. Every `handle` reads it exactly once before it can suspend,
    /// so this is how a test knows N concurrent requests have all *arrived* — without which "they shared
    /// one stop" could pass while two of them had simply not run yet.
    var stateReads: Int { calls.filter { $0 == "state" }.count }

    // `ControlServing` is `@MainActor`, so an off-actor access does not compile. There was a
    // `sawOffMainActorAccess` flag here, checked with `Thread.isMainThread`; it could only ever have
    // fired if the compiler were broken, and a test that cannot fail reads as a guarantee while
    // guaranteeing nothing.
    private func record(_ name: String) {
        calls.append(name)
    }

    // MARK: - ControlServing

    var state: ControlState {
        record("state")
        return currentState
    }

    /// Make `states()` hand out a **pull-driven** stream over `states`, ending once they run out.
    ///
    /// ⚠️ Why this exists: a coalescing assertion has to know the pump has actually consumed everything
    /// upstream, and a push stream cannot say. Counting `Task.yield()`s instead is scheduling luck — it
    /// reads whichever event the pump happened to have reached, which is exactly how this test first
    /// failed (it asserted the newest and got the one before it). `AsyncStream(unfolding:)` produces on
    /// demand, so `pulls` is the pump's own progress, observed rather than assumed.
    func scriptStates(_ states: [ControlState]) { scriptQueue = states }

    func states() -> AsyncStream<ControlState> {
        record("states")
        if scriptQueue != nil {
            return AsyncStream(unfolding: { @MainActor [weak self] in
                guard let self else { return nil }
                self.pulls += 1
                guard var queue = self.scriptQueue, !queue.isEmpty else { return nil }
                let next = queue.removeFirst()
                self.scriptQueue = queue
                self.currentState = next
                return next
            })
        }
        return AsyncStream { continuation in
            let id = UUID()
            MainActor.assumeIsolated {
                continuations[id] = continuation
                // Replays the current state as element one, as `ControlAPI.states()` does — which is
                // what the dispatcher consumes as its initial `watch` event.
                continuation.yield(currentState)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.continuations[id] = nil }
            }
        }
    }

    var title: String {
        get {
            record("title.get")
            return storedTitle
        }
        set {
            record("title.set")
            storedTitle = newValue
        }
    }

    var settings: RecordingSettings {
        get {
            record("settings.get")
            return storedSettings
        }
        set {
            record("settings.set")
            storedSettings = newValue
        }
    }

    func saveSettings() { record("saveSettings") }

    func settleMicrophoneSettings() async {
        record("settleMicrophoneSettings")
        guard parksMicrophoneSettlement else { return }
        await withCheckedContinuation { settlementWaiters.append($0) }
    }
    func start(title: String?) {
        record("start")
        if let title { storedTitle = title }
    }
    func stop() { record("stop") }

    func stopAndWait() async {
        record("stopAndWait")
        stopAndWaitEntries += 1
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    func recover() { record("recover") }
    func refresh() { record("refresh") }
    func openArchive() { record("openArchive") }
    func openInFinder(_ url: URL) {
        record("openInFinder")
        revealed = url
    }
    func dismissRecoveryNotice() { record("dismissRecoveryNotice") }

    // MARK: - Driving

    /// Let every parked `stopAndWait()` finish, settling the state the way a real stop does.
    func finishStop() {
        currentState.operation = .idle
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Push a new state to every `states()` subscriber.
    func emit(_ state: ControlState) {
        currentState = state
        for continuation in continuations.values { continuation.yield(state) }
    }

    /// The title without recording an access — so an assertion about the title cannot itself pollute
    /// `calls`.
    var titleWithoutRecording: String { storedTitle }
}

// MARK: - Helpers

@MainActor
@available(macOS 15.0, *)
func makeDispatcher(_ state: ControlState = ControlState()) -> (ControlDispatcher, FakeControlServing) {
    let fake = FakeControlServing()
    fake.currentState = state
    return (ControlDispatcher(service: fake), fake)
}

func fixtureRecording(_ name: String) -> MeetingStore.Recording {
    MeetingStore.Recording(directory: URL(fileURLWithPath: "/tmp/Acta-test/\(name)", isDirectory: true))
}

@available(macOS 15.0, *)
extension ControlResponse {
    var result: CommandResult? {
        if case .result(let result) = self { return result }
        return nil
    }

    var wireError: WireError? {
        if case .error(let error) = self { return error }
        return nil
    }

    var events: AsyncStream<WatchEvent>? {
        if case .events(let stream) = self { return stream }
        return nil
    }

    var state: WireControlState? {
        if case .state(let state) = result { return state }
        return nil
    }
}

/// Yield until `condition` holds, bounded — the bound is a deadlock guard, never a timing assertion.
/// Exhausting it means the thing under test never happened, which is a failure and not a flake.
///
/// ⚠️ **Every wait here is a condition, never a yield count.** A fixed number of `Task.yield()`s reads
/// whatever the scheduler happened to have reached by then: that is how the coalescing test first
/// failed, asserting the newest state and getting the one before it, on a runner whose other suites
/// were contending for the same main actor. Not a sleep either — every actor here is the main one and
/// every hand-off is a turn, so yielding *is* the wait.
@MainActor
func waitUntil(_ what: String,
               turns: Int = 10_000,
               sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: () -> Bool) async {
    for _ in 0..<turns {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
}
