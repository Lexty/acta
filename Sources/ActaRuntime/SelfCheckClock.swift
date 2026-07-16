import Foundation

/// The time seam for `SelfCheck`: **both halves of it**, and that is the whole point.
///
/// `SelfCheck` does two different things with time — it waits (the startup probe window, the
/// watchdog tick) and it *reads* the clock to decide whether the stall threshold has elapsed. A seam
/// that only replaced the waiting would look like it worked and would be worthless: with an instant
/// sleeper the stall threshold is measured against a `now` that never moves, so it never elapses,
/// the restart path becomes unreachable, and the tests still pass — the failure mode is silent.
///
/// A test clock therefore advances `now` when it sleeps. It is **not** a virtual scheduler: there is
/// no `advance(by:)`, no queue of pending work, no drain-to-quiescence. Wall-clock time keeps its
/// own job — `startedAt` and the recording's metadata are `Date()` exactly as before, because they
/// mean "when did this meeting happen", not "how long since the last buffer".
public protocol SelfCheckClock: Sendable {
    /// Monotonic seconds — unaffected by system clock changes. Only differences between two reads
    /// are meaningful; the origin is arbitrary.
    var now: Double { get }

    /// Wait for `seconds`. Cancellation is not an error here: the watchdog checks
    /// `Task.isCancelled` itself after every wait.
    func sleep(for seconds: Double) async
}

/// The real clock: monotonic uptime and `Task.sleep`.
public struct SystemClock: SelfCheckClock {
    public init() {}

    public var now: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public func sleep(for seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
