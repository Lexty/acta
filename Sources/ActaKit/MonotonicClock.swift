import Foundation

/// A `Date`-shaped timeline that cannot jump.
///
/// ⚠️ **Both reminder rules measure *observed* intervals**, and `Date` is not one. A clock corrected by
/// NTP, a time zone change, or a machine waking with a different notion of the hour all move wall time
/// without anything having been watched — and an hour appearing between two ordinary samples qualifies a
/// three-second hold instantly, or completes a five-minute quiet interval that nobody observed.
///
/// ⚠️ **It is still a `Date`, on purpose.** The rules take timestamps, the summaries carry them, and the
/// tests fabricate them; a second time type would have to be threaded through all of that for no gain.
/// What this gives is a `Date` whose differences are real elapsed time: a fixed origin plus a monotonic
/// measurement from it. The absolute value is meaningless and nothing formats it.
public enum MonotonicClock {
    private struct Origin: Sendable {
        let wall: Date
        let instant: ContinuousClock.Instant
    }

    private static let origin = Origin(wall: Date(), instant: ContinuousClock.now)

    /// The current instant on the monotonic timeline.
    public static func now() -> Date {
        let elapsed = ContinuousClock.now - origin.instant
        return origin.wall.addingTimeInterval(TimeInterval(elapsed.components.seconds)
                                              + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
