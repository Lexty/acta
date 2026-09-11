import Foundation

// MARK: - The measurement contract

/// One coarse summary of how loud a stretch of one track was.
///
/// ⚠️ **Coarse on purpose.** This is what leaves the capture queue, and nothing else does: no audio, no
/// history, no per-buffer work anywhere but the measurement itself. A recording must never wait on
/// analysis.
///
/// ⚠️ **`power` is optional because measurement fails.** An unsupported buffer layout, a format the
/// meter does not understand, a buffer with no samples — all of those are *unknown*, and unknown is not
/// silence. A rule that treats them as silence offers to stop a recording because its meter broke.
public struct AudioActivitySummary: Equatable, Sendable {
    public enum Track: Equatable, Hashable, Sendable {
        /// What the microphone heard — the person at this machine.
        case microphone
        /// What the machine played — everyone else on the call.
        case system
    }

    public var track: Track
    /// Which capture this belongs to. A restart, a device change or a format change mints a new one.
    ///
    /// ⚠️ **The rule refuses summaries from an older generation.** A callback in flight when capture
    /// restarted would otherwise warm the new recording's estimate with the old one's audio, or worse,
    /// keep a stale quiet interval running across the discontinuity.
    public var generation: UInt64
    /// How much audio this summary covers, seconds.
    public var duration: TimeInterval
    /// Mean power over that audio in dBFS, or `nil` when it could not be measured.
    ///
    /// ⚠️ Digital silence is a **finite** value, not `-infinity`: exact zeroes are ordinary in a stream
    /// that has not started yet, and an infinity poisons every average it touches.
    public var power: Double?

    public init(track: Track, generation: UInt64, duration: TimeInterval, power: Double?) {
        self.track = track
        self.generation = generation
        self.duration = duration
        self.power = power
    }
}

// MARK: - The rule

/// Has this recording been quiet long enough to be worth asking about?
///
/// ⚠️ **It measures activity, not speech.** There is no voice detector here and this type must never be
/// described as one: speech can be quiet and a chair scrape can be loud. What it decides is whether the
/// sound in a recording has stayed at the level of the room's own background for long enough that the
/// meeting is probably over.
///
/// The rules, and each of them exists because the obvious version is wrong:
///
/// - **A floor learned from the room, not a constant in decibels.** A fridge, a fan and a street are
///   different in every flat and at every hour, and digital amplitude has no fixed relation to loudness
///   across microphones and gains.
/// - **Warm-up before anything is offered.** A rolling low percentile learns whatever it hears the most
///   of, so a recording that begins mid-sentence would otherwise learn continuous speech as its floor.
/// - **Bounded upward adaptation.** A floor allowed to climb without limit eventually reaches speech and
///   declares it background.
/// - **Hysteresis and a hold.** Two different thresholds to enter and leave activity, and a short hold
///   afterwards, so the gap between two sentences is not the beginning of silence.
/// - **Both tracks, each with its own estimate.** A person listening to a presentation without speaking
///   is not an idle recording. The system track keeps the clock at zero on its own, and the cost of that
///   is accepted: unrelated music will prevent a stop offer, which is better than declaring a meeting
///   over while someone is talking.
/// - **Unknown is not quiet.** Missing summaries, a stalled track, a failed measurement, a generation
///   change: the quiet interval requires fresh evidence from **both** tracks, and anything else resets
///   it.
/// - **Withheld when it cannot tell.** If the level never varies, a constantly-talking room and a
///   constant hum are indistinguishable to this estimator, and it says so by offering nothing.
public struct AudioActivityRule: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// How long both tracks must be inactive before an offer.
        public var quiet: TimeInterval
        /// How much audio must be measured on a track before its floor is trusted at all.
        public var warmUp: TimeInterval
        /// Decibels above the floor at which a track becomes active.
        public var activationMargin: Double
        /// Decibels above the floor below which it stops being active. Lower than activation: the gap is
        /// the hysteresis.
        public var releaseMargin: Double
        /// How long a track stays active after its last loud measurement.
        public var activityHold: TimeInterval
        /// How much history the floor estimate looks at.
        public var floorWindow: TimeInterval
        /// The most the floor may rise, decibels per minute.
        public var maxFloorRisePerMinute: Double
        /// The value that stands in for digital silence.
        public var digitalSilenceFloor: Double
        /// With no summary for this long, a track is unknown rather than quiet.
        public var staleAfter: TimeInterval
        /// The smallest spread between the quiet and loud ends of the window that still lets the
        /// estimator claim it can tell them apart.
        public var minimumDynamicRange: Double

        public init(quiet: TimeInterval = 300,
                    warmUp: TimeInterval = 60,
                    activationMargin: Double = 12,
                    releaseMargin: Double = 8,
                    activityHold: TimeInterval = 2,
                    floorWindow: TimeInterval = 600,
                    maxFloorRisePerMinute: Double = 3,
                    digitalSilenceFloor: Double = -100,
                    staleAfter: TimeInterval = 5,
                    minimumDynamicRange: Double = 6) {
            self.quiet = quiet
            self.warmUp = warmUp
            self.activationMargin = activationMargin
            self.releaseMargin = releaseMargin
            self.activityHold = activityHold
            self.floorWindow = floorWindow
            self.maxFloorRisePerMinute = maxFloorRisePerMinute
            self.digitalSilenceFloor = digitalSilenceFloor
            self.staleAfter = staleAfter
            self.minimumDynamicRange = minimumDynamicRange
        }

        public static let `default` = Configuration()
    }

    /// Everything outside the audio that decides whether an offer is appropriate.
    public struct Context: Equatable, Sendable {
        /// The preference.
        public var isEnabled: Bool
        /// The recording this evaluation is about. An offer carries it, and a click re-checks it.
        public var recordingID: UInt64

        public init(isEnabled: Bool = true, recordingID: UInt64 = 1) {
            self.isEnabled = isEnabled
            self.recordingID = recordingID
        }
    }

    public enum Outcome: Equatable, Sendable {
        case none
        /// Offer to stop. Carries the recording it is about.
        case offerStop(recordingID: UInt64)
        /// A standing offer is no longer true: sound came back.
        case withdraw(recordingID: UInt64)
    }

    /// What the rule believes about one track right now — exposed so the UI can explain itself and a
    /// test can assert the intermediate state rather than only the outcome.
    public enum TrackState: Equatable, Sendable {
        /// No fresh measurement.
        case unknown
        /// Measured, but not for long enough to trust a floor.
        case warmingUp
        /// Measured and above the floor.
        case active
        /// Measured and at the level of the room.
        case quiet
        /// Measured, but the level never varies enough to tell background from speech.
        case indistinguishable
    }

    /// A bounded histogram of recent levels, in one-decibel bins.
    ///
    /// ⚠️ **Not a sorted array, and the reason is the audio path.** Percentiles over a growing window
    /// recomputed on every summary is O(n log n) per measurement; at 2 Hz over a ten-minute window that
    /// is a sort of 1200 samples twice a second, for a hint. A histogram makes insertion O(1) and a
    /// percentile a walk over a hundred bins, and it is exactly as accurate as a decibel is meaningful.
    struct PowerHistogram {
        private static let lowest = -120
        private static let highest = 0
        private var bins = [Int](repeating: 0, count: highest - lowest + 1)
        private var entries: [(at: Date, bin: Int)] = []
        private(set) var count = 0

        private static func bin(for power: Double) -> Int {
            // ⚠️ **Clamped as a Double first.** `Int(_:)` traps on a finite value too large for `Int`,
            // and "the meter reported something absurd" must degrade a hint, never crash a recording.
            guard power.isFinite else { return 0 }
            let bounded = min(max(power, Double(lowest)), Double(highest))
            return Int(bounded.rounded()) - lowest
        }

        mutating func insert(_ power: Double, at now: Date) {
            let index = Self.bin(for: power)
            bins[index] += 1
            entries.append((now, index))
            count += 1
        }

        mutating func expire(before cutoff: Date) {
            var removed = 0
            while removed < entries.count, entries[removed].at < cutoff {
                bins[entries[removed].bin] -= 1
                count -= 1
                removed += 1
            }
            if removed > 0 { entries.removeFirst(removed) }
        }

        /// The level below which `fraction` of the window sits.
        func percentile(_ fraction: Double) -> Double? {
            guard count > 0 else { return nil }
            let target = max(1, Int((Double(count) * fraction).rounded()))
            var seen = 0
            for (index, bucket) in bins.enumerated() where bucket > 0 {
                seen += bucket
                if seen >= target { return Double(index + Self.lowest) }
            }
            return nil
        }
    }

    private struct TrackEstimate {
        var levels = PowerHistogram()
        var measuredDuration: TimeInterval = 0
        /// When a summary last arrived at all — the meter is running.
        var lastSummaryAt: Date?
        /// When a summary last carried a usable measurement.
        ///
        /// ⚠️ **The one the state depends on.** A meter that keeps reporting "I could not measure that"
        /// is alive and blind, and a blind meter must not be able to call a recording quiet.
        var lastMeasuredAt: Date?
        var lastActiveAt: Date?
        var floor: Double?
        var floorUpdatedAt: Date?
        var isActive = false
    }

    private var configuration: Configuration
    private var tracks: [AudioActivitySummary.Track: TrackEstimate] = [:]
    private var generation: UInt64 = 0
    private var quietSince: Date?
    /// The recording an offer has already been made for. One per recording, as decided.
    private var offeredFor: UInt64?
    private var standingOffer: UInt64?
    /// An explicit "ask me again", bound to its recording.
    private var snooze: (until: Date, recordingID: UInt64)?

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// The quiet interval, which the user can change while a recording runs.
    public mutating func setQuietInterval(_ quiet: TimeInterval) {
        configuration.quiet = quiet
    }

    // MARK: - Lifecycle

    /// A new capture: a different recording, a restart, a device or format change.
    ///
    /// ⚠️ **Everything is discarded, not merely the clock.** A floor learned before a format change
    /// describes audio that no longer exists, and carrying it over is how a recalibration turns into a
    /// wrong answer that looks calibrated.
    public mutating func beginGeneration(_ generation: UInt64) {
        self.generation = generation
        tracks = [:]
        quietSince = nil
    }

    /// The reminder was switched off, or the recording ended. Pending evidence is dropped and the quiet
    /// history with it, so re-enabling starts from a fresh warm-up rather than from a stale estimate.
    public mutating func invalidate() {
        tracks = [:]
        quietSince = nil
        standingOffer = nil
        snooze = nil
    }

    /// A new recording starts with no offer spent and no snooze.
    public mutating func beginRecording(_ recordingID: UInt64, generation: UInt64) {
        offeredFor = nil
        standingOffer = nil
        snooze = nil
        beginGeneration(generation)
    }

    /// The user asked to be reminded later, about this recording.
    public mutating func armSnooze(until: Date, recordingID: UInt64) {
        snooze = (until, recordingID)
        standingOffer = nil
    }

    /// A standing offer was answered, dismissed or expired.
    public mutating func offerResolved() {
        standingOffer = nil
    }

    // MARK: - Measurement

    /// Take one summary. Summaries from an older generation are dropped.
    public mutating func ingest(_ summary: AudioActivitySummary, at now: Date) {
        guard summary.generation == generation else { return }
        var estimate = tracks[summary.track] ?? TrackEstimate()
        estimate.lastSummaryAt = now

        guard let power = summary.power, power.isFinite else {
            // ⚠️ A failed measurement is *not* a quiet measurement. The track keeps its freshness — the
            // meter is running — but contributes no evidence, so the estimate cannot warm on it and the
            // quiet interval cannot advance on it either.
            // ⚠️ **Invalidated now, not when the last good sample ages out.** Keeping the previous
            // valid reading "fresh" for `staleAfter` means the first failed measurement — which can land
            // exactly as the quiet threshold is crossed — still produces a confident offer.
            estimate.isActive = false
            estimate.lastMeasuredAt = nil
            tracks[summary.track] = estimate
            refreshQuiet(at: now)
            return
        }

        estimate.lastMeasuredAt = now
        let clamped = max(power, configuration.digitalSilenceFloor)
        estimate.levels.expire(before: now.addingTimeInterval(-configuration.floorWindow))
        estimate.levels.insert(clamped, at: now)
        estimate.measuredDuration += summary.duration

        updateFloor(&estimate, at: now)

        if let floor = estimate.floor, isWarm(estimate) {
            let activation = floor + configuration.activationMargin
            let release = floor + configuration.releaseMargin
            if clamped >= activation {
                estimate.isActive = true
                estimate.lastActiveAt = now
            } else if clamped < release {
                estimate.isActive = false
            } else if estimate.isActive {
                // Inside the hysteresis band: whatever it was, it stays.
                estimate.lastActiveAt = now
            }
        }
        tracks[summary.track] = estimate
        refreshQuiet(at: now)
    }

    /// ⚠️ **The floor may rise slowly and fall freely.** Falling is always safe — a quieter room is a
    /// quieter room. Rising is the dangerous direction, because a floor that climbs without limit walks
    /// up into speech and declares it background, which is exactly what a recording that starts
    /// mid-sentence would teach it.
    private func updateFloor(_ estimate: inout TrackEstimate, at now: Date) {
        guard let candidate = estimate.levels.percentile(0.10) else { return }
        guard let current = estimate.floor, let updatedAt = estimate.floorUpdatedAt else {
            estimate.floor = candidate
            estimate.floorUpdatedAt = now
            return
        }
        if candidate <= current {
            estimate.floor = candidate
        } else {
            let minutes = max(now.timeIntervalSince(updatedAt), 0) / 60
            let allowed = current + configuration.maxFloorRisePerMinute * minutes
            estimate.floor = min(candidate, allowed)
        }
        estimate.floorUpdatedAt = now
    }

    private func isWarm(_ estimate: TrackEstimate) -> Bool {
        estimate.measuredDuration >= configuration.warmUp
    }

    /// ⚠️ **The quiet clock advances on measurement, not on being asked.** Keeping it inside
    /// `evaluate` made the answer depend on how often the caller happened to poll: a coordinator that
    /// evaluated once every ten minutes would need ten more minutes of quiet before it could offer.
    private mutating func refreshQuiet(at now: Date) {
        let microphone = state(of: .microphone, at: now)
        let system = state(of: .system, at: now)
        // ⚠️ **Positive activity cancels a snooze; uncertainty does not.** "Remind me in thirty minutes"
        // is a request about a recording that had gone quiet. If the conversation resumed, the request
        // no longer describes anything, and firing it later would be a prompt to stop a live meeting. A
        // meter hiccup is not a resumed conversation, so only `.active` clears it.
        if microphone == .active || system == .active {
            snooze = nil
        }
        if microphone == .quiet && system == .quiet {
            if quietSince == nil { quietSince = now }
        } else {
            quietSince = nil
        }
    }

    // MARK: - Deciding

    /// How one track reads right now.
    public func state(of track: AudioActivitySummary.Track, at now: Date) -> TrackState {
        guard let estimate = tracks[track], let last = estimate.lastMeasuredAt,
              now.timeIntervalSince(last) <= configuration.staleAfter else {
            return .unknown
        }
        guard isWarm(estimate), estimate.floor != nil else { return .warmingUp }

        // ⚠️ **Current activity is decided before any historical shortcut.** A long silent history keeps
        // the ninetieth percentile at the digital floor for many minutes, so a run of digital silence
        // could mask speech that has *just* arrived — and the offer would appear while somebody was
        // talking. What is happening now outranks what the window remembers.
        if estimate.isActive { return .active }
        if let lastActive = estimate.lastActiveAt,
           now.timeIntervalSince(lastActive) <= configuration.activityHold {
            return .active
        }

        guard let low = estimate.levels.percentile(0.10),
              let high = estimate.levels.percentile(0.90) else { return .warmingUp }
        // ⚠️ **Measured digital silence is quiet, not ambiguous.** The spread test exists to refuse a
        // constant *audible* signal, where a hum and a room full of talking look alike. A track sitting
        // at the digital floor is not ambiguous at all: nothing is there. Without this, a microphone-only
        // recording could never be offered, because its system track is exactly this and its spread is
        // zero for ever.
        if high <= configuration.digitalSilenceFloor { return .quiet }
        if high - low < configuration.minimumDynamicRange { return .indistinguishable }
        return .quiet
    }

    /// Ask the rule what to do, given the clock.
    public mutating func evaluate(at now: Date, context: Context) -> Outcome {
        // ⚠️ Quiet requires *both* tracks to be positively quiet. Unknown, warming up and
        // indistinguishable are all reasons to hold the clock at zero rather than to let it run.
        let wasQuiet = quietSince != nil
        refreshQuiet(at: now)
        if quietSince == nil, wasQuiet || standingOffer != nil, let standing = standingOffer {
            standingOffer = nil
            return .withdraw(recordingID: standing)
        }

        guard context.isEnabled else { return .none }
        guard let since = quietSince, now.timeIntervalSince(since) >= configuration.quiet else {
            return .none
        }

        if let snooze {
            guard snooze.recordingID == context.recordingID else { return .none }
            guard now >= snooze.until else { return .none }
            // ⚠️ Re-checked when it comes due, never fired blind: if the conversation resumed and went
            // quiet again, the interval above has been re-earned, and if it never did we are not here.
            self.snooze = nil
            standingOffer = context.recordingID
            return .offerStop(recordingID: context.recordingID)
        }

        guard offeredFor != context.recordingID else { return .none }
        offeredFor = context.recordingID
        standingOffer = context.recordingID
        return .offerStop(recordingID: context.recordingID)
    }
}
