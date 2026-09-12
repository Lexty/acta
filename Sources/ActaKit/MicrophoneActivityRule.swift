import Foundation

// MARK: - The observation contract

/// One process as the audio HAL reports it, for the purpose of "is anybody recording right now".
///
/// ⚠️ **Three fields, and the third is three-valued on purpose.** `isRunningInput == nil` means the
/// property could not be read — not that the process is idle. Collapsing that into `false` is the
/// defect this whole type exists to prevent: an unreadable sample would close an episode, and the next
/// readable one would look like a fresh rising edge and raise a second prompt for one conversation.
public struct AudioProcessObservation: Equatable, Hashable, Sendable {
    /// The process id. Stable for the life of the process and the only identity a helper without a
    /// bundle identifier has.
    public var pid: Int32
    /// The bundle identifier, when the process has one. `nil` is common and normal.
    public var bundleID: String?
    /// The name a **prompt** may show, and only when it describes something the user recognises.
    ///
    /// ⚠️ **Measured, not assumed.** On this machine a call in a Safari tab is held by
    /// `com.apple.WebKit.GPU`, whose name resolves to "Safari Graphics and Media", and Chrome's audio
    /// runs in `com.google.Chrome.helper`, "Google Chrome Helper". Those are real names, and putting
    /// either in "… is using the microphone" describes the meeting worse than saying nothing. So this
    /// field is filled only for a regular, user-facing application; a helper leaves it `nil` and the
    /// prompt names nobody.
    public var displayName: String?

    /// The name of the process itself, helper or not.
    ///
    /// ⚠️ For a **list**, never a sentence. "Google Chrome Helper" is the right label for a row in the
    /// exclusion list, because that is precisely what was excluded, and the wrong subject for a prompt
    /// about a meeting.
    public var processName: String?
    /// Whether the process is running IO with at least one active input stream. `nil` = unread.
    public var isRunningInput: Bool?

    public init(pid: Int32, bundleID: String? = nil, displayName: String? = nil,
                processName: String? = nil, isRunningInput: Bool?) {
        self.pid = pid
        self.bundleID = bundleID
        self.displayName = displayName
        self.processName = processName
        self.isRunningInput = isRunningInput
    }
}

/// One reading of every audio process on the machine.
///
/// ⚠️ **`isComplete` is not decoration.** The process list is itself a property read that can fail or
/// return a partial answer, and a process missing from a *partial* list has not been observed to stop —
/// it has not been observed at all. The rule treats the two cases differently, so the reader has to say
/// which one it is holding.
public struct AudioProcessSnapshot: Equatable, Sendable {
    public var processes: [AudioProcessObservation]
    /// Whether the enumeration itself succeeded. `false` → absence proves nothing.
    public var isComplete: Bool

    public init(processes: [AudioProcessObservation], isComplete: Bool) {
        self.processes = processes
        self.isComplete = isComplete
    }

    /// The reading a failed enumeration produces.
    public static let unreadable = AudioProcessSnapshot(processes: [], isComplete: false)
}

// MARK: - Episode identity

/// One continuous stretch of one application holding microphone input.
///
/// ⚠️ **Identity exists so a click can be refused.** A prompt is a message about *this* episode; by the
/// time it is answered the call may be over and another may have begun. Every action carries the id it
/// was minted for, and the far end re-checks it.
public struct MicrophoneActivityEpisode: Equatable, Sendable, Identifiable {
    public var id: UInt64
    /// The bundle identifier the episode is attributed to, when there is one.
    public var bundleID: String?
    /// The name to show, when the system supplied one for a regular application. `nil` → the prompt
    /// must not name an app.
    public var displayName: String?
    /// The process's own name, for labelling what an exclusion would actually cover.
    public var processName: String?

    public init(id: UInt64, bundleID: String?, displayName: String?, processName: String? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.displayName = displayName
        self.processName = processName
    }

    /// Whether this episode can be attributed to a named application at all.
    public var isAttributed: Bool { displayName != nil }
}

// MARK: - The rule

/// When another application takes the microphone, should Acta offer to record?
///
/// Pure and total: it is fed snapshots and a clock reading and answers with an outcome. Every rule
/// below exists because the obvious version of this feature is a prompt generator.
///
/// - **A rising edge, never a level.** An application that holds the input permanently would otherwise
///   raise a prompt every time Acta launches.
/// - **Qualified by a hold.** Applications open the input for a fraction of a second to check a
///   permission or draw a level meter. `Configuration.hold` filters those and nothing else — a Sound
///   Settings meter or another recorder holds input for minutes and is an expected false positive,
///   answered by the exclusion list.
/// - **One offer per episode.** Shown, ignored or expired, the episode is spent. The user asked for
///   "once".
/// - **Re-armed only by *observed* inactivity.** A device handoff or a helper being replaced must not
///   look like the end of a conversation.
/// - **Unknown is not idle.** An unreadable sample freezes every clock rather than advancing one.
/// - **A baseline at startup.** Input already held when Acta launches establishes state without
///   prompting. That deliberately misses a meeting already under way; the alternative is a prompt on
///   every launch.
public struct MicrophoneActivityRule: Sendable {
    /// The two durations the rule is made of.
    public struct Configuration: Equatable, Sendable {
        /// How long input must be **observed** held before an offer may be made.
        public var hold: TimeInterval
        /// How long input must be **observed** released before a new episode may begin.
        ///
        /// ⚠️ Longer than the hold on purpose: leaving an episode is the direction in which a mistake
        /// produces a second prompt for one conversation.
        public var rearm: TimeInterval

        public init(hold: TimeInterval = RecordingSettings.microphoneActivityHold,
                    rearm: TimeInterval = 30) {
            self.hold = hold
            self.rearm = rearm
        }

        public static let `default` = Configuration()
    }

    /// Everything outside the HAL that decides whether a prompt is appropriate right now.
    public struct Context: Equatable, Sendable {
        /// The preference. `false` → the rule still tracks episodes, and never offers.
        public var isEnabled: Bool
        /// A recording is already running, or starting, or saving.
        public var isBusy: Bool
        /// The menu is open — the offer's own content is already on screen.
        public var isMenuOpen: Bool
        /// Bundle identifiers the user excluded.
        public var excludedBundleIDs: Set<String>
        /// Acta's own bundle identifiers — every flavor, plus any helper.
        ///
        /// ⚠️ **A set, not one string.** The dev and stable builds coexist on this machine by design,
        /// and each must ignore the other's capture as well as its own: a prompt offering to record the
        /// recording next to it is the most embarrassing possible false positive.
        public var ownBundleIDs: Set<String>
        /// Acta's own process ids — the identity a helper without a bundle id still has.
        public var ownPIDs: Set<Int32>

        public init(isEnabled: Bool = true,
                    isBusy: Bool = false,
                    isMenuOpen: Bool = false,
                    excludedBundleIDs: Set<String> = [],
                    ownBundleIDs: Set<String> = [],
                    ownPIDs: Set<Int32> = []) {
            self.isEnabled = isEnabled
            self.isBusy = isBusy
            self.isMenuOpen = isMenuOpen
            self.excludedBundleIDs = excludedBundleIDs
            self.ownBundleIDs = ownBundleIDs
            self.ownPIDs = ownPIDs
        }
    }

    /// What one observation produced.
    public enum Outcome: Equatable, Sendable {
        /// Nothing to do.
        case none
        /// Offer to record. Carries the episode the offer belongs to.
        case offer(MicrophoneActivityEpisode)
        /// The episode behind a standing offer has ended; a prompt still on screen is now false.
        ///
        /// ⚠️ **Emitted whether or not anything is showing.** The rule does not know what the UI is
        /// doing, and a withdraw for a prompt that already expired is free. The reverse — a prompt left
        /// standing for a call that ended — is the failure worth spending an event on.
        case withdraw(episodeID: UInt64)
    }

    /// How one tracked application is currently seen.
    private enum Phase: Equatable, Sendable {
        /// Never yet observed in a trustworthy reading. **Not** the same as idle: an application we
        /// have never seen may already be in a call, and the first thing we learn about it must not be
        /// read as it starting one.
        case unseen
        /// Input observed released, and released long enough. No episode.
        case idle
        /// Input observed held since, not yet qualified.
        case holding(since: Date)
        /// An episode exists and its one offer has been spent (made, suppressed or excluded).
        case spent(episodeID: UInt64)
        /// Input observed released at, inside a live episode. Becomes `idle` after `rearm`.
        case releasing(since: Date, episodeID: UInt64)
        /// The last sample could not be read. Carries what to return to.
        ///
        /// ⚠️ Every clock in the restored phase is restarted rather than resumed — see `observe`.
        indirect case unreadable(previous: Phase)
    }

    /// What a key is: an application when we can name one, a process when we cannot.
    ///
    /// ⚠️ **Coalescing is by bundle identifier**, so the several processes an Electron application or a
    /// browser runs are one episode and raise one prompt rather than three.
    private enum Key: Hashable {
        case bundle(String)
        case process(Int32)
    }

    private var configuration: Configuration
    private var phases: [Key: Phase] = [:]
    private var nextEpisodeID: UInt64 = 1
    /// Whether a trustworthy picture of the machine has been taken yet.
    ///
    /// ⚠️ **Set by the first *complete* snapshot, never merely by the first call.** A failed first
    /// enumeration observes nothing, and letting it spend the baseline means the first successful
    /// reading of a call already in progress looks like a rising edge — a prompt about a meeting that
    /// was under way before Acta launched, which is the one thing the baseline exists to prevent.
    private var hasBaseline = false
    /// The episode a standing offer belongs to, so its end can be withdrawn exactly once.
    private var standingOffer: UInt64?

    /// The last episode an offer was actually **raised** for — never cleared when the offer is resolved
    /// or withdrawn.
    ///
    /// ⚠️ It is what separates "spent because we offered, and the application was holding when we did"
    /// from "spent at baseline, because it was already holding when Acta started and we deliberately
    /// stayed silent". Both are `.spent`, and only the first is evidence a person could act on. Without
    /// it, tolerating an unreadable moment would let a baselined episode — one nobody was ever shown —
    /// answer yes to a question about evidence.
    private var lastOfferedEpisode: UInt64?
    /// The last name the system supplied for a key.
    ///
    /// ⚠️ **Remembered rather than read at offer time, and never invented.** The snapshot that
    /// qualifies an episode may be the one where the name failed to resolve; a name seen earlier in the
    /// same episode is still a name the system gave us. Absent means absent: the prompt then says that
    /// some application is using the microphone, and names none.
    private var names: [Key: String] = [:]
    /// The last process name seen for a key — what an exclusion row would be labelled with.
    private var processNames: [Key: String] = [:]

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Feed one reading. `now` is the reading's timestamp; the rule has no clock of its own.
    public mutating func observe(_ snapshot: AudioProcessSnapshot,
                                 at now: Date,
                                 context: Context) -> Outcome {
        let readings = Self.readings(from: snapshot, context: context)
        rememberNames(from: snapshot, context: context)

        // Keys we have state for but that this snapshot did not mention. In a complete snapshot that
        // is evidence of release; in a partial one it is evidence of nothing.
        for key in phases.keys where readings[key] == nil {
            apply(snapshot.isComplete ? .released : .unreadable, to: key, at: now)
        }
        for (key, reading) in readings {
            apply(reading, to: key, at: now)
        }

        if !hasBaseline {
            guard snapshot.isComplete else { return .none }
            hasBaseline = true
            // ⚠️ Everything holding the input at this instant is an episode that is already spent, so
            // the launch of Acta during a meeting is silent. **And everything unreadable is spent too**:
            // a key whose property failed in the baseline reading cannot be ruled out as already in a
            // call, and guessing in the other direction is the prompt we must not produce. It costs one
            // re-arm window of silence for that key if it was in fact idle.
            for (key, phase) in phases {
                switch phase {
                case .holding:
                    phases[key] = .spent(episodeID: mintEpisodeID())
                case .unreadable:
                    // ⚠️ **Every unreadable key, whatever it was before, and still unreadable.** A key
                    // whose property failed in the baseline reading cannot be ruled out as already in a
                    // call — including one seen holding in an earlier *partial* list, which is how a
                    // qualification from before the baseline used to survive it. And it is wrapped
                    // rather than flattened: converting unknown straight to `.spent` would make
                    // `isEpisodeActionable` report a held input that was never positively observed.
                    phases[key] = .unreadable(previous: .spent(episodeID: mintEpisodeID()))
                default:
                    break
                }
            }
            return .none
        }

        expireFinishedRearms(at: now)

        // ⚠️ **Withdrawal asks the question acceptance asks — `isEpisodeActionable`, not a looser
        // liveness.** It used to ask `isEpisodeLive`, which also accepts `.releasing` and an
        // `.unreadable` wrapper around it. Those two predicates disagreeing opened a window as long as
        // the whole re-arm — thirty seconds by default — in which the panel kept showing "Start
        // Recording" for an episode the admission check would refuse. The user pressed it and nothing
        // happened. The reason for refusing the click is exactly the reason the offer should already
        // have come down, so there is one predicate now.
        //
        // ⚠️ The episode itself stays in `.releasing`: that is anti-duplicate bookkeeping, and it is why
        // an application that re-acquires the input inside the window returns to `.spent` rather than to
        // `.holding` and mints no second offer. Withdrawing the offer does **not** revive it on
        // re-acquisition, and that cost is accepted deliberately — a brief device handoff can take away
        // an offer nobody answered. Restoring it would mean admitting a click after the evidence that
        // justified it had gone.
        if let standing = standingOffer, !isEpisodeActionable(standing) {
            standingOffer = nil
            return .withdraw(episodeID: standing)
        }

        return offerIfQualified(at: now, context: context, readings: readings)
    }

    /// Keep every name the system managed to supply, keyed the same way the readings are.
    private mutating func rememberNames(from snapshot: AudioProcessSnapshot, context: Context) {
        for process in snapshot.processes {
            if context.ownPIDs.contains(process.pid) { continue }
            if let bundleID = process.bundleID, context.ownBundleIDs.contains(bundleID) { continue }
            let key = process.bundleID.map { Key.bundle($0) } ?? .process(process.pid)
            if let name = process.displayName, !name.isEmpty { names[key] = name }
            if let name = process.processName, !name.isEmpty { processNames[key] = name }
        }
    }

    /// Told from outside that the offer for `episodeID` is no longer on screen — answered, dismissed or
    /// expired. The episode stays spent either way; this only stops a later `withdraw`.
    public mutating func offerResolved(episodeID: UInt64) {
        if standingOffer == episodeID { standingOffer = nil }
    }

    // MARK: - Transitions

    private enum Reading: Equatable {
        case held
        case released
        case unreadable
    }

    /// Fold the snapshot into one reading per key. Several processes of one application are one key, and
    /// **held wins over released**: a browser whose helper is recording while another helper is not is
    /// holding the microphone.
    ///
    /// ⚠️ Acta's own processes are dropped here rather than filtered later, so its own capture can never
    /// create, extend or re-arm an episode.
    // swiftlint:disable:next cyclomatic_complexity
    private static func readings(from snapshot: AudioProcessSnapshot,
                                 context: Context) -> [Key: Reading] {
        var readings: [Key: Reading] = [:]
        for process in snapshot.processes {
            if context.ownPIDs.contains(process.pid) { continue }
            if let bundleID = process.bundleID, context.ownBundleIDs.contains(bundleID) { continue }
            let key: Key = process.bundleID.map { Key.bundle($0) } ?? .process(process.pid)
            let reading: Reading
            switch process.isRunningInput {
            case .some(true): reading = .held
            case .some(false): reading = .released
            case .none: reading = .unreadable
            }
            readings[key] = Self.stronger(readings[key], reading)
        }
        // ⚠️ **A partial list cannot say that anything stopped**, and a visible idle sibling does not
        // make it able to. The process that actually held the input is exactly the one that can be
        // missing, so a key with no positively-held process in an incomplete snapshot is unreadable,
        // never released. Positive evidence still counts: a process seen holding is holding.
        if !snapshot.isComplete {
            for (key, reading) in readings where reading == .released {
                readings[key] = .unreadable
            }
        }
        return readings
    }

    /// `held` beats `unreadable` beats `released`: a key is idle only when every process of it was seen
    /// to be idle.
    private static func stronger(_ lhs: Reading?, _ rhs: Reading) -> Reading {
        guard let lhs else { return rhs }
        if lhs == .held || rhs == .held { return .held }
        if lhs == .unreadable || rhs == .unreadable { return .unreadable }
        return .released
    }

    private mutating func apply(_ reading: Reading, to key: Key, at now: Date) {
        let current = phases[key] ?? .unseen
        switch reading {
        case .unreadable:
            // Wrap once: an unreadable run remembers the phase it started from, not the last wrapper.
            if case .unreadable = current { return }
            phases[key] = .unreadable(previous: current)

        case .held:
            switch current {
            case .unseen, .idle:
                phases[key] = .holding(since: now)
            case .holding, .spent:
                break
            case .releasing(_, let episodeID):
                // ⚠️ Back inside the same episode. A handoff between devices, or one helper replacing
                // another, releases the input briefly; treating that as a new episode is what produces
                // a second prompt for one call.
                phases[key] = .spent(episodeID: episodeID)
            case .unreadable(let previous):
                phases[key] = Self.resuming(previous, heldAt: now)
            }

        case .released:
            switch current {
            case .unseen:
                // Seen, and seen idle: now a later hold is a genuine rising edge.
                phases[key] = .idle
            case .idle:
                break
            case .holding:
                // Never qualified: no episode was ever created, so there is nothing to re-arm.
                phases[key] = .idle
            case .spent(let episodeID):
                phases[key] = .releasing(since: now, episodeID: episodeID)
            case .releasing:
                break
            case .unreadable(let previous):
                phases[key] = Self.resuming(previous, releasedAt: now)
            }
        }
    }

    /// Whether an unreadable run started from a key we had never trustworthily observed.
    private static func isUnseen(_ phase: Phase) -> Bool {
        switch phase {
        case .unseen: return true
        case .unreadable(let inner): return isUnseen(inner)
        default: return false
        }
    }

    /// Leaving an unreadable run on a **held** sample.
    ///
    /// ⚠️ Every clock restarts. The rule may only act on time it actually observed, and the gap is by
    /// definition unobserved: a hold that "completed" across it was never seen to complete.
    private static func resuming(_ previous: Phase, heldAt now: Date) -> Phase {
        switch previous {
        case .unseen, .idle, .holding: return .holding(since: now)
        case .spent(let episodeID): return .spent(episodeID: episodeID)
        case .releasing(_, let episodeID): return .spent(episodeID: episodeID)
        case .unreadable(let inner): return resuming(inner, heldAt: now)
        }
    }

    /// Leaving an unreadable run on a **released** sample. A re-arm may not complete across a gap
    /// either, so its clock restarts too.
    private static func resuming(_ previous: Phase, releasedAt now: Date) -> Phase {
        switch previous {
        case .unseen: return .idle
        case .idle: return .idle
        case .holding: return .idle
        case .spent(let episodeID): return .releasing(since: now, episodeID: episodeID)
        case .releasing(_, let episodeID): return .releasing(since: now, episodeID: episodeID)
        case .unreadable(let inner): return resuming(inner, releasedAt: now)
        }
    }

    // MARK: - Offering

    /// A key quiet for longer than the re-arm has no episode any more.
    private mutating func expireFinishedRearms(at now: Date) {
        for (key, phase) in phases {
            if case .releasing(let since, _) = phase,
               now.timeIntervalSince(since) >= configuration.rearm {
                phases[key] = .idle
            }
        }
    }

    private mutating func offerIfQualified(at now: Date,
                                           context: Context,
                                           readings: [Key: Reading]) -> Outcome {
        // Deterministic order: a machine with two qualifying applications must not depend on dictionary
        // iteration to decide which one is offered.
        let qualified = phases.compactMap { key, phase -> (Key, Date)? in
            guard case .holding(let since) = phase,
                  now.timeIntervalSince(since) >= configuration.hold else { return nil }
            return (key, since)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? Self.ordering(lhs.0) < Self.ordering(rhs.0) : lhs.1 < rhs.1
        }

        guard !qualified.isEmpty else { return .none }

        // ⚠️ **The candidate is chosen from the eligible keys, and only then is everything spent.**
        // Picking `qualified.first` and *then* testing the exclusion made an excluded application into
        // a filter over every other one: a level meter left open in Sound Settings, whose identifier
        // happens to sort first, silently swallowed the Slack offer standing next to it.
        let eligible = qualified.first { key, _ in
            guard case .bundle(let bundleID) = key else { return true }
            return !context.excludedBundleIDs.contains(bundleID)
        }?.0

        // ⚠️ **Spent either way, eligible or not.** Suppressed by a recording in progress, by an open
        // menu, by the preference being off or by the exclusion list — the episode is over as far as
        // prompting goes. Offering later, when the suppression lifts, means asking "record this call?"
        // the moment the user has just stopped recording it, which is the one time the answer is
        // obviously no.
        var chosenEpisode: UInt64?
        for (qualifiedKey, _) in qualified {
            let episodeID = mintEpisodeID()
            phases[qualifiedKey] = .spent(episodeID: episodeID)
            if qualifiedKey == eligible { chosenEpisode = episodeID }
        }

        guard let key = eligible, let episodeID = chosenEpisode else { return .none }
        guard context.isEnabled, !context.isBusy, !context.isMenuOpen else { return .none }
        // ⚠️ **One offer owns the slot until it is resolved.** A second application qualifying while a
        // prompt is still on screen must not take the slot over: the visible prompt's identity is what
        // a click will carry, and overwriting it loses the episode that still needs withdrawing.
        guard standingOffer == nil else { return .none }

        standingOffer = episodeID
        lastOfferedEpisode = episodeID
        return .offer(MicrophoneActivityEpisode(id: episodeID,
                                                bundleID: bundleIdentifier(of: key),
                                                displayName: names[key],
                                                processName: processNames[key]))
    }

    private static func ordering(_ key: Key) -> String {
        switch key {
        case .bundle(let id): return "b:" + id
        case .process(let pid): return "p:" + String(pid)
        }
    }

    private func bundleIdentifier(of key: Key) -> String? {
        if case .bundle(let id) = key { return id }
        return nil
    }

    /// Whether `episodeID` is not merely alive but **currently holding the input**.
    ///
    /// ⚠️ **Liveness and actionability are different questions, and conflating them authorises a stale
    /// click.** An episode survives a release for the whole re-arm window, which is what stops a device
    /// handoff producing a second prompt — but that grace says nothing about whether a call is still in
    /// progress. A prompt raised at t=4 whose application dropped the input at t=5 must not start a
    /// recording when it is clicked at t=20. The coordinator asks *this* at the final admission point.
    public func isEpisodeActionable(_ episodeID: UInt64) -> Bool {
        phases.values.contains { phase in
            if case .spent(let id) = phase { return id == episodeID }
            // ⚠️ **An unreadable snapshot is not evidence that the application stopped** — it is the
            // project's oldest rule about this reader, and three tests exist to hold it. What we last
            // *observed* was this application holding the input, and a failed HAL read says nothing
            // about whether it still is. So a wrapper around `.spent` stays actionable, and a wrapper
            // around `.releasing` does not: there the last thing we saw was the release itself.
            //
            // ⚠️ This is a deliberate divergence from the review that asked for withdrawal on unknown
            // evidence. That instruction was right about the *symptom* — a visible button must never be
            // one the admission check would refuse — but the two predicates can be reconciled in either
            // direction, and refusing on unknown would take a valid offer away over a transient read
            // failure, with nothing to bring it back. Tolerating on both sides keeps the button and the
            // click agreeing without treating a blind moment as an answer.
            if case .unreadable(let previous) = phase, case .spent(let id) = previous {
                // Only for an episode a prompt was actually raised for — see `lastOfferedEpisode`.
                return id == episodeID && lastOfferedEpisode == episodeID
            }
            return false
        }
    }

    private mutating func mintEpisodeID() -> UInt64 {
        defer { nextEpisodeID += 1 }
        return nextEpisodeID
    }
}
