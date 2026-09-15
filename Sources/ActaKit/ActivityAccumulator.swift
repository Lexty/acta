import Foundation

/// Turns per-buffer power readings into the coarse summaries `AudioActivityRule` consumes.
///
/// ⚠️ **The arithmetic lives here, away from `CMSampleBuffer`**, so every rule below is decided by a
/// test rather than by listening to a recording: power is summed, never averaged as amplitude;
/// unmeasurable buffers poison a window rather than being silently skipped; and digital zero converts
/// to a finite floor.
public struct ActivityAccumulator: Equatable, Sendable {
    /// How much audio one summary covers. Coarse on purpose — this is what crosses a queue boundary.
    public let interval: TimeInterval
    /// What stands in for a window with no energy at all.
    public let digitalSilenceFloor: Double

    private var energy: Double = 0
    private var frames: Double = 0
    private var span: TimeInterval = 0
    /// Whether anything in this window could not be measured.
    ///
    /// ⚠️ **One bad buffer spoils the window, deliberately.** A format the meter cannot read is not a
    /// quiet stretch, and averaging the half it understood would report a confident number about audio
    /// it never saw.
    private var isSpoiled = false

    public init(interval: TimeInterval = 0.5, digitalSilenceFloor: Double = -100) {
        self.interval = interval
        self.digitalSilenceFloor = digitalSilenceFloor
    }

    /// Take one buffer's worth of measured energy.
    ///
    /// - Parameters:
    ///   - meanSquare: mean of the squared samples, already averaged **across channels as powers** —
    ///     never as signed amplitudes, which cancel on out-of-phase stereo and report silence.
    ///   - frameCount: how many frames that covers.
    ///   - duration: how long, in seconds.
    public mutating func add(meanSquare: Double, frameCount: Int, duration: TimeInterval) {
        guard meanSquare.isFinite, meanSquare >= 0, frameCount > 0, duration > 0 else {
            spoil(duration: max(duration, 0))
            return
        }
        energy += meanSquare * Double(frameCount)
        frames += Double(frameCount)
        span += duration
    }

    /// Record a buffer that could not be measured at all.
    public mutating func spoil(duration: TimeInterval) {
        isSpoiled = true
        span += max(duration, 0)
    }

    /// A summary, if enough audio has accumulated. `power` is `nil` when the window was spoiled.
    public mutating func emit() -> (power: Double?, duration: TimeInterval)? {
        guard span >= interval else { return nil }
        let duration = span
        let result: Double?
        if isSpoiled {
            result = nil
        } else if frames > 0 {
            let mean = energy / frames
            // ⚠️ Digital zero is a finite value: `log10(0)` is −infinity, and an infinity poisons every
            // percentile, average and comparison it reaches.
            result = mean > 0 ? max(10 * log10(mean), digitalSilenceFloor) : digitalSilenceFloor
        } else {
            result = nil
        }
        reset()
        return (result, duration)
    }

    /// Throw away the partial window — a capture restart, a format change, the reminder switched off.
    public mutating func reset() {
        energy = 0
        frames = 0
        span = 0
        isSpoiled = false
    }

    /// Whether anything is pending.
    public var isEmpty: Bool { span == 0 }
}
