import ActaRuntime
import Foundation

// The injected clock, in a file of its own: `CaptureTestFixtures` had outgrown the length limit, and
// this is the piece that comes away whole — nothing above depends on it, and it is a seam
// (`SelfCheckClock`) rather than a capture fixture.

// MARK: - Test clock

/// A clock that hands back the time asked of it almost immediately **and moves `now` by the full
/// amount anyway** — the two halves have to travel together. With `now` frozen, the stall threshold
/// never elapses, the watchdog's restart path silently becomes unreachable, and the tests keep
/// passing while proving nothing. That is the trap this type exists to avoid.
///
/// "Almost immediately" and not "instantly", which is the one non-obvious decision here. The
/// watchdog is a `while` loop whose only suspension is this sleep, so a truly instant one turns it
/// into a busy loop: it would burn its entire restart budget and flood the disk with buffers in the
/// microseconds between `start()` returning and a test calling `stop()`. A token real wait keeps the
/// loop's *shape* honest while compressing an hour of watchdog time into milliseconds. It is not a
/// virtual scheduler — nothing here queues, advances or drains on demand.
///
/// `onSleep` is what lets a test put data into the window the code is observing: the startup probe
/// and every watchdog tick call it, which is where the fake source's next batch comes from.
final class TestClock: SelfCheckClock, @unchecked Sendable {
    /// The real time a sleep of any virtual length costs. Small enough that a whole watchdog stall
    /// (six ticks) is milliseconds, large enough not to spin a core.
    private static let realWaitNanos: UInt64 = 200_000

    /// The real cost of a sleep once time is frozen. Far longer than `realWaitNanos`, because a
    /// frozen clock is a clock nothing is waiting for: the watchdog goes on ticking for as long as
    /// the recording lives, and at 200 µs a tick that is a core burned to observe a number that
    /// cannot change. The loop still suspends, which is all its cancellation needs.
    private static let frozenWaitNanos: UInt64 = 20_000_000

    private let lock = NSLock()
    private var seconds = 0.0
    private var sleeps = 0
    private var frozen = false
    private var handler: (@Sendable (Double) -> Void)?

    /// Called on every sleep, with the requested duration, after `now` has advanced.
    func onSleep(_ body: @escaping @Sendable (Double) -> Void) { withLock { handler = body } }

    /// Stop time: `now` never advances again, and no `onSleep` handler runs again.
    ///
    /// The trap this type's own documentation warns about, turned into a tool — and only because
    /// what it disables is named. A frozen clock is one the watchdog can never catch stalling
    /// (`FlowWatchdog` compares `now` against the last progress, and a delta that stays zero never
    /// reaches the threshold), so a recording that has stopped receiving audio stays up instead of
    /// being restarted and eventually given up on. That is not a stall going unnoticed: it is a
    /// recording held still on purpose, by a caller that has finished feeding it and needs the state
    /// on disk to stop moving — a process about to be `SIGKILL`ed, whose audio must be countable.
    ///
    /// Dropping the handler is the same decision from the other side: `onSleep` is how the clock
    /// drives emission during the startup probe, and a caller that wants emission to stop cannot
    /// leave the watchdog holding a way to resume it.
    func freeze() { withLock { frozen = true; handler = nil } }

    /// How many waits the code under test has performed.
    var sleepCount: Int { withLock { sleeps } }

    var now: Double { withLock { seconds } }

    func sleep(for duration: Double) async {
        let (body, isFrozen): ((@Sendable (Double) -> Void)?, Bool) = withLock {
            if !frozen { seconds += duration }
            sleeps += 1
            return (handler, frozen)
        }
        body?(duration)
        // The suspension the watchdog's cancellation depends on: a loop that never suspends would
        // never observe `Task.isCancelled`, and `stop()` — which cancels and then awaits it — would
        // hang forever.
        try? await Task.sleep(nanoseconds: isFrozen ? Self.frozenWaitNanos : Self.realWaitNanos)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
