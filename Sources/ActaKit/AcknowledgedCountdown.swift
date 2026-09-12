import Foundation

/// A countdown that runs only from the moment its prompt was acknowledged as on screen.
///
/// The pure half of the reminder presenter contract, and clock-injected like the rules beside it. It is
/// what a timer that *acts* is allowed to rest on, so it is deliberately small and says no more than it
/// observed:
///
/// - ⚠️ **Publication is not presentation.** A prompt handed to a presenter may never reach the screen —
///   the presenter can stall, be absent, or be refused a window. The countdown therefore sits in
///   `awaitingAcknowledgement` for as long as that takes, and **no amount of elapsed time moves it**.
///   Only `acknowledge(presentation:at:)` starts it, and the deadline is measured from that instant.
/// - **The deadline is set once, here, and never re-derived.** A second acknowledgement is refused, and
///   nothing a rendering update carries can move it; a presenter that redraws the countdown is showing
///   this number, not deciding it.
/// - **A gap revokes, even past the deadline.** Two evaluations further apart than
///   `Configuration.maxEvaluationGap` mean the countdown was not watched in between — the Mac slept, the
///   screen locked, the main thread stalled. The user was promised the whole interval in which to
///   cancel, and a countdown that completed on the far side of a wake would have taken it from them. It
///   never catches up; a new countdown needs a new presentation.
/// - **Terminal states stay terminal.** `completed` is reported once; `revoked` cannot be acknowledged
///   back into life.
public struct AcknowledgedCountdown: Equatable, Sendable {
    public struct Configuration: Equatable, Sendable {
        /// How long the countdown runs once acknowledged.
        ///
        /// ⚠️ A judgement, not a measurement: twenty seconds is the start prompt's lifetime, kept because
        /// it has proven long enough to notice and answer a panel over a call.
        public var duration: TimeInterval
        /// The largest interval between two evaluations that still counts as watched.
        ///
        /// The reminder tick runs at 1 Hz; 2.5 s tolerates one late or skipped tick and nothing more.
        public var maxEvaluationGap: TimeInterval

        public init(duration: TimeInterval = 20, maxEvaluationGap: TimeInterval = 2.5) {
            self.duration = duration
            self.maxEvaluationGap = maxEvaluationGap
        }

        public static let `default` = Configuration()
    }

    /// Why a countdown ended without completing.
    public enum Revocation: Equatable, Sendable {
        /// The user dismissed the prompt, or answered it.
        case dismissed
        /// Another prompt took its place.
        case replaced
        /// The preference that governs it was switched off.
        case preferenceOff
        /// Quit began.
        case closing
        /// The presenter reported the prompt is no longer on screen — a lock, a display sleep.
        case presentationLost
        /// The countdown was not watched continuously — a sleep, a stall, a rebaseline.
        case observationLapsed
        /// The prompt was taken down for any other reason.
        case withdrawn
    }

    public enum Phase: Equatable, Sendable {
        /// Published, not yet acknowledged as on screen. Time does not run.
        case awaitingAcknowledgement
        /// Acknowledged; ends at `deadline` if nothing revokes it first.
        case running(deadline: Date)
        /// Ran its full acknowledged duration.
        case completed
        /// Ended early. Nothing brings it back.
        case revoked(Revocation)
    }

    public enum Outcome: Equatable, Sendable {
        /// Not running: still awaiting acknowledgement, or already over.
        case none
        /// Running, with this many whole seconds left, rounded up.
        case remaining(seconds: Int)
        /// The full duration has just elapsed. Reported once.
        case completed
        /// This evaluation found a gap and revoked the countdown.
        case revoked(Revocation)
    }

    /// The presentation this countdown belongs to. An acknowledgement for any other one is refused.
    public let presentation: UInt64
    public let configuration: Configuration
    public private(set) var phase: Phase = .awaitingAcknowledgement

    /// The far end of the next gap check: the acknowledgement, then each evaluation.
    private var lastEvaluatedAt: Date?

    public init(presentation: UInt64, configuration: Configuration = .default) {
        self.presentation = presentation
        self.configuration = configuration
    }

    /// Whether the countdown can still complete — awaiting acknowledgement, or running.
    public var isLive: Bool {
        switch phase {
        case .awaitingAcknowledgement, .running: return true
        case .completed, .revoked: return false
        }
    }

    /// Whole seconds a presenter should show before the countdown is acknowledged.
    public var fullSeconds: Int { Int(configuration.duration.rounded(.up)) }

    /// The presenter says `presentation` is on screen. Starts the countdown if it is this one's and it
    /// has not started; returns whether it did.
    @discardableResult
    public mutating func acknowledge(presentation acknowledged: UInt64, at now: Date) -> Bool {
        guard acknowledged == presentation, case .awaitingAcknowledgement = phase else { return false }
        phase = .running(deadline: now.addingTimeInterval(configuration.duration))
        lastEvaluatedAt = now
        return true
    }

    /// One evaluation. `now` is the caller's clock; the countdown has none of its own.
    public mutating func evaluate(at now: Date) -> Outcome {
        guard case .running(let deadline) = phase else { return .none }
        if let lastEvaluatedAt {
            let interval = now.timeIntervalSince(lastEvaluatedAt)
            // ⚠️ Checked **before** the deadline, so a wake past the deadline revokes rather than completes.
            // An interval that runs backwards cannot be measured, and treating it as watched is the
            // direction that acts.
            if interval < 0 || interval > configuration.maxEvaluationGap {
                phase = .revoked(.observationLapsed)
                return .revoked(.observationLapsed)
            }
        }
        lastEvaluatedAt = now
        guard now < deadline else {
            phase = .completed
            return .completed
        }
        return .remaining(seconds: Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// End the countdown early. Returns whether it was live.
    @discardableResult
    public mutating func revoke(_ reason: Revocation) -> Bool {
        guard isLive else { return false }
        phase = .revoked(reason)
        return true
    }
}
