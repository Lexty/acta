import Foundation

/// Has the application a recording belongs to let the microphone go — for long enough, and observed
/// closely enough, to be worth asking about?
///
/// Pure and clock-injected, like `MicrophoneActivityRule`, and deliberately **not** built on it. That
/// rule's phases encode prompt consumption, a launch baseline and re-arm history; none of those is
/// continuous evidence, and this rule's answer is what a countdown will eventually be allowed to act
/// on. ⚠️ **Never infer a release from `!isEpisodeActionable`**: that predicate also goes false for
/// reasons that say nothing about the owner. What the two rules *do* share is how a snapshot is read —
/// key derivation, own-process dropping, held-wins and the partial-list rule all live in
/// `AudioProcessReadings`, and this rule consumes its `Evidence` rather than a snapshot so it cannot grow
/// a second copy.
///
/// The rules it is made of:
///
/// - **A release is a sequence, not a sample.** `releasedQualified` needs released observations spanning
///   `Configuration.releaseQualification`, with no two consecutive observations further apart than
///   `Configuration.maxSampleGap`. Measured on a live huddle: every join was followed within 1.4–2.4 s by
///   a release and re-acquisition, so an offer on the first `false` would stop a recording two seconds
///   into its call.
/// - **Unknown revokes.** An unreadable reading discards whatever release had accumulated; the next
///   released observation starts a fresh interval. The rule may only act on time it actually observed.
/// - **A gap revokes too.** Two observations further apart than `maxSampleGap` are not a continuous
///   release, whatever both of them said: the owner may have held the input in between, and a Mac that
///   slept through a countdown never gave the user the interval it promised.
/// - **A return starts over.** A positive observation of the owner, at 4.9 s or at 4 minutes, returns to
///   `held`, and the next release needs the full interval again.
/// - **Only the owner counts.** Another application's evidence never reaches this rule's reading;
///   `com.apple.CoreSpeech` holds the input persistently on the measured machine, and a rule that looked
///   at it would never release anything.
///
/// ⚠️ **Completeness is carried by `Evidence.reading(of:)`, not re-derived here.** The owner absent from
/// a *complete* enumeration is a release — that is what quitting looks like — and absent from an
/// incomplete one is unknown. ⚠️ **An unresolved identity reaches this rule as unknown only because the
/// reader makes it so**: `AudioProcessProjection` turns a failed bundle-identifier read for a process it
/// never identified into an incomplete snapshot carrying no input evidence. A reader that instead
/// reported such a process under a pid key in a *complete* list would make the owner look absent here,
/// which is a release. That contract lives in the reader and its tests; this rule trusts it.
public struct MicrophoneOwnershipRule: Sendable {
    /// The two durations the rule is made of.
    public struct Configuration: Equatable, Sendable {
        /// How long the owner must be **observed** released before a stop may be offered.
        ///
        /// ⚠️ A judgement, not a measurement. The gaps observed inside calls (266 ms to 834 ms) are
        /// intervals between observed states and bound no physical duration in either direction, so
        /// this number was not tuned to them and must not be.
        public var releaseQualification: TimeInterval
        /// The largest interval between two consecutive observations that still counts as continuous.
        ///
        /// Production samples at 1 Hz; 2.5 s tolerates one late or skipped tick and nothing more.
        public var maxSampleGap: TimeInterval

        public init(releaseQualification: TimeInterval = 5, maxSampleGap: TimeInterval = 2.5) {
            self.releaseQualification = releaseQualification
            self.maxSampleGap = maxSampleGap
        }

        public static let `default` = Configuration()
    }

    /// How the owner is currently seen.
    public enum Phase: Equatable, Sendable {
        /// Observed holding the input, continuously observed since.
        case held(since: Date)
        /// Observed released since, not yet for long enough.
        case releaseCandidate(since: Date)
        /// Released for the full interval, and still observed released.
        case releasedQualified
        /// The last observation could not answer for the owner. Nothing accumulated survives it.
        case unknown(since: Date)
    }

    /// What one observation produced.
    public enum Outcome: Equatable, Sendable {
        /// Nothing to act on.
        case none
        /// The release has just qualified. Emitted once per qualification, on the transition.
        case releaseQualified
        /// The owner was observed holding again after a release had begun, qualified or not.
        ///
        /// ⚠️ **Not emitted when leaving `unknown`.** Nothing was cancelled there: whatever release had
        /// accumulated was already revoked, and a qualified one already reported `evidenceLost`.
        case ownerReturned
        /// A qualified release lost the evidence behind it — an unreadable observation or a gap.
        ///
        /// ⚠️ **Only for a qualified release.** An unqualified candidate is revoked silently: nothing
        /// could have been shown for it, so there is nothing to withdraw.
        case evidenceLost
    }

    /// The application this rule watches, fixed for its lifetime.
    public let owner: OwnerBinding
    public private(set) var phase: Phase

    private let configuration: Configuration
    /// When the rule last had an observation, readable or not — the far end of the next gap check.
    private var lastObservedAt: Date

    /// Start watching a bound owner.
    ///
    /// ⚠️ **Starts `held`, at the binding's own evidence.** A binding is only ever minted from a
    /// positive observation of that key (`OwnerBinding.bind`), so this is what was last seen, not an
    /// assumption; the first gap is measured from that observation too.
    public init(owner: OwnerBinding, configuration: Configuration = .default) {
        self.owner = owner
        self.configuration = configuration
        self.phase = .held(since: owner.observedAt)
        self.lastObservedAt = owner.observedAt
    }

    /// Feed one folded observation. `now` is its timestamp; the rule has no clock of its own.
    public mutating func observe(_ evidence: AudioProcessReadings.Evidence, at now: Date) -> Outcome {
        let interval = now.timeIntervalSince(lastObservedAt)
        // ⚠️ A timestamp earlier than the last one is a gap as well: the rule cannot reason about an
        // interval it cannot measure, and treating it as continuous is the direction that stops a call.
        let isGap = interval < 0 || interval > configuration.maxSampleGap
        lastObservedAt = now

        switch evidence.reading(of: owner.key) {
        case .held:
            switch phase {
            case .held(let since):
                phase = .held(since: isGap ? now : since)
                return .none
            case .releaseCandidate, .releasedQualified:
                phase = .held(since: now)
                return .ownerReturned
            case .unknown:
                phase = .held(since: now)
                return .none
            }

        case .unreadable:
            switch phase {
            case .unknown:
                return .none
            case .releasedQualified:
                phase = .unknown(since: now)
                return .evidenceLost
            case .held, .releaseCandidate:
                phase = .unknown(since: now)
                return .none
            }

        case .released:
            switch phase {
            case .held, .unknown:
                phase = .releaseCandidate(since: now)
            case .releaseCandidate(let since):
                // ⚠️ The gap is unobserved, so the interval restarts at this observation rather than
                // spanning it.
                phase = .releaseCandidate(since: isGap ? now : since)
            case .releasedQualified:
                guard isGap else { return .none }
                phase = .releaseCandidate(since: now)
                return .evidenceLost
            }
            if case .releaseCandidate(let since) = phase,
               now.timeIntervalSince(since) >= configuration.releaseQualification {
                phase = .releasedQualified
                return .releaseQualified
            }
            return .none
        }
    }
}
