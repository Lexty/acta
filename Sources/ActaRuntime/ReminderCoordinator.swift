import ActaKit
import Combine
import Foundation
import os

/// What the reminder panel should be showing, if anything.
///
/// ⚠️ **Every case carries the identity it was minted for.** A prompt is a message about one episode or
/// one recording, and by the time it is answered that episode may be over and another may have begun.
/// The identity travels with the prompt so the answer can be refused.
public enum ReminderPrompt: Equatable, Sendable {
    /// Another application took the microphone. `application` is `nil` when nothing nameable holds it.
    case offerToRecord(episodeID: UInt64, application: String?, bundleID: String?,
                       suggestedTitle: String, microphone: String)
    /// The recording has been quiet.
    /// ⚠️ No segment count: `ControlState` exposes none for the recording in progress, and the archive's
    /// recording count is a different number. A prompt that answers "will I lose what is recorded" with
    /// the wrong figure is worse than one that does not answer it.
    case offerToStop(recordingID: UInt64, title: String, elapsedSeconds: Int)
    /// The application a prompt-started recording belongs to let the microphone go, and stayed released.
    ///
    /// ⚠️ **The one prompt that acts if nobody answers**: it carries a countdown, and a countdown that ran
    /// its full acknowledged duration stops the recording. See the narrow exception in `AGENTS.md`.
    /// ⚠️ **`text` is resolved before it gets here** (`OwnerReleaseOfferText`), because naming the
    /// application is a fact and the view is the one layer nothing checks.
    case offerToStopOnRelease(recordingID: UInt64, title: String, text: OwnerReleaseOfferText)
    /// A click has been taken and the answer is not known yet.
    ///
    /// ⚠️ **It exists because the click used to produce nothing at all.** The acceptance path takes the
    /// prompt down, then awaits the microphone-settings barrier, then re-checks identity — and if any
    /// check refuses, the panel had already gone and the user was left looking at a button that had
    /// vanished without recording anything. A press must always produce something to look at.
    case checkingStart(attempt: UInt64, title: String)
    /// The click arrived after its offer had gone stale.
    ///
    /// ⚠️ **It does not say the call ended.** Losing sight of an application's input proves nothing
    /// about whether people are still talking — it is the absence of evidence, not evidence of absence —
    /// so the words point at the offer, not at the meeting.
    case startNoLongerAvailable(attempt: UInt64)
    /// A start was accepted from a prompt and capture has not confirmed yet.
    ///
    /// ⚠️ **Acta never reports recording before data is being written** — that is the app's oldest rule,
    /// and a confirmation shown the instant `start` returns breaks it: the start is asynchronous and can
    /// still fail on a permission, a device or a self-check.
    case startingRecording(title: String)
    /// Capture confirmed. Shown briefly, then gone.
    case startedRecording(title: String)
}

/// One prompt as handed to the screen, with the identity its acknowledgement must name.
public struct ReminderPresentation: Equatable, Sendable {
    /// Stable for the life of this prompt on screen; a new prompt, even an equal one, gets a new id.
    public let id: UInt64
    public let prompt: ReminderPrompt
    /// Whole seconds left on the countdown this prompt carries, or `nil` when it carries none.
    ///
    /// ⚠️ **A rendering of the coordinator's deadline, never a source of it.** Nothing a presenter does
    /// with this number reaches back into the countdown.
    public let secondsRemaining: Int?

    public init(id: UInt64, prompt: ReminderPrompt, secondsRemaining: Int?) {
        self.id = id
        self.prompt = prompt
        self.secondsRemaining = secondsRemaining
    }
}

/// What the coordinator talks to in order to put a prompt in front of the user.
///
/// ⚠️ **The contract exists because `prompt != nil` is not proof of presentation.** The coordinator
/// cannot observe a screen: a published prompt may be drawn late, drawn on a display that is asleep, or
/// not drawn at all. A countdown that may *act* therefore starts only when the presenter says, by id,
/// that the prompt is on screen — `ReminderCoordinator.acknowledgePresentation(_:)` — and a presenter
/// that stops being able to show it says that too — `ReminderCoordinator.presentationLost(_:)`. A
/// presenter that never calls back authorises nothing.
///
/// ⚠️ **Showing and updating are different calls, on purpose.** `show` is a new prompt: it may place the
/// panel, arm its dismissal and watch for clicks. `updateCountdown` is the same prompt with a new number,
/// and must do none of those — a panel that re-placed itself every second would walk across the screen
/// under the pointer and never let its own dismissal fire.
@MainActor
public protocol ReminderPresenting: AnyObject {
    /// Put this presentation on screen, replacing whatever was there. Acknowledge it once it is visible.
    func show(_ presentation: ReminderPresentation)
    /// Redraw the countdown of the presentation already on screen, in place. Ignore any other id.
    func updateCountdown(_ presentation: ReminderPresentation)
    /// Take this presentation off the screen, if it is the one showing.
    func withdraw(_ presentationID: UInt64)
}

/// One line of proof that the reminder tick is still running.
///
/// ⚠️ **It does not fix the silence, it makes it observable.** On 2026-09-12 an instance that had been
/// up since 09:57 did not react to two real Slack huddles, while a fresh one reacted immediately — and
/// nothing in the log could separate "the tick stopped" from "nothing was holding the microphone",
/// because the only diagnostic there logs on *change*. A beat emitted on a schedule rather than on a
/// change tells those two apart: a beat proves a tick completed, and an idle machine beats as loudly as
/// a busy one.
///
/// ⚠️ **No beats is a question, not an answer.** It says only that no completed tick was retained in the
/// interval looked at — which sleep, a deliberate quit, a tick wedged inside a synchronous read, and the
/// store's own retention limit all produce as readily as a dead poll task. Codex corrected an earlier
/// version of this comment that called it a diagnosis.
///
/// ⚠️ **`tick` against `uptime` is not polling utilisation either.** `ContinuousClock` keeps counting
/// while the Mac is asleep — which is the whole reason `lastTick` below rebaselines on a gap — so an
/// overnight sleep leaves a low ratio with nothing wrong. A ratio far below one is an observation gap
/// that has to be explained, not starvation.
public struct ReminderHeartbeat: Equatable, Sendable {
    /// How many times `tick()` has run on this instance, counting the one that emitted this.
    public let tick: UInt64
    /// How long this instance has been alive, on a clock that cannot jump.
    public let uptime: Duration
    /// What this tick saw, or that it deliberately looked at nothing.
    public let observation: Observation
    /// The two reminder preferences as *this tick* read them.
    ///
    /// ⚠️ **A preference that is off is the other way a silent instance is explained**, and it was ruled
    /// out by hand last time — by decoding the stored settings blob after the fact. Carrying them costs
    /// nothing and settles it in the same line.
    public let offersRecordingWhenMicrophoneBusy: Bool
    public let offersStopWhenQuiet: Bool
    public let offersStopWhenOwnerReleases: Bool

    public enum Observation: Equatable, Sendable {
        /// The process list was read on this tick.
        case observed(processes: Int, isComplete: Bool, holders: Int)
        /// **No snapshot was read on this tick.** Literally that, and nothing more: the ordinary
        /// cause is both process-consuming reminders — the start offer and the release stop offer —
        /// being off, but a tick that returned early before reaching the read reports the same thing.
        ///
        /// ⚠️ **Deliberately not repaired by the diagnostic.** A heartbeat that walked the process list
        /// to have something to report would add exactly the per-second cost the design refuses when
        /// the feature is off.
        case notObserved
    }
}

/// One fold of a process snapshot, as the release side of the reminders last saw it.
///
/// ⚠️ **The time and the epoch travel with the evidence**, because a binding admitted from it has to be
/// re-checked against the observation it claims to come from, not against whatever "now" is when the
/// check runs.
public struct ObservedProcessEvidence: Equatable, Sendable {
    public let evidence: AudioProcessReadings.Evidence
    /// When the snapshot behind it was read, on the coordinator's clock.
    public let observedAt: Date
    /// The observation epoch current when it was read.
    ///
    /// ⚠️ **The start reminder's epoch**, the one a prompt's token and an `OwnerBinding` carry. It
    /// advances on every tick while the start reminder is off, because the activity rule is replaced
    /// each time; that is harmless only because no prompt — and so no binding — exists then.
    public let epoch: UInt64
}

/// Joins the reminder rules — start offer, quiet stop, owner-release stop — to the recorder.
///
/// ⚠️ **Nothing here acts on its own — with one narrow exception.** Every path that starts a recording
/// begins with a click, and a timer may *withdraw* the start offer or the quiet stop offer but never answer
/// either. The exception is the owner-release stop offer: its countdown may stop a recording, and only
/// after that prompt was acknowledged on screen and ran its full duration with nobody keeping the
/// recording. Automatic start, automatic deletion and any timer answering the quiet offer stay forbidden.
///
/// ⚠️ **Identity is re-checked at the admission point, not only when the prompt was raised.** The panel
/// hands back the id it was given, and the check happens in the same main-actor turn as the command —
/// there is no suspension between deciding and acting, because a suspension is exactly where a
/// conversation ends and another begins.
@available(macOS 15.0, *)
@MainActor
public final class ReminderCoordinator: ObservableObject {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "ReminderCoordinator")

    /// What the panel should show. `nil` means nothing.
    ///
    /// ⚠️ **Every route that takes a prompt down passes through here**, so this is where the presenter
    /// is told and where a countdown still attached to it is revoked. A call site that names a more
    /// specific reason revokes first; this catches the ones that do not, including any added later.
    @Published public private(set) var prompt: ReminderPrompt? {
        didSet {
            guard prompt == nil, oldValue != nil else { return }
            revokeCountdown(.withdrawn)
            presenter?.withdraw(presentation)
        }
    }

    /// Who puts prompts on screen. `nil` shows nothing, and so acknowledges nothing.
    ///
    /// ⚠️ Weak: the app owns the panel, and a coordinator must not keep a window alive past it.
    public weak var presenter: (any ReminderPresenting)?

    /// The countdown attached to the prompt on screen, if it carries one — **the authoritative
    /// deadline**. See `AcknowledgedCountdown`.
    private(set) var countdown: AcknowledgedCountdown?
    /// The last number handed to the presenter, so an unchanged second is not redrawn.
    private var lastRenderedSeconds: Int?
    /// The presentation whose countdown last ran its full acknowledged duration.
    ///
    /// ⚠️ **Authorisation, recorded for every countdown; only the release offer acts on it.** A completed
    /// countdown on any other prompt takes that prompt down and does nothing else.
    private(set) var authorisedCountdown: UInt64?

    /// The release side of the recording in progress, when that recording is bound to an owner.
    ///
    /// ⚠️ **Rebuilt whenever the admitted binding changes**, and discarded when there is none: a watch
    /// never outlives the recording whose binding it was built from, so a release observed for one
    /// recording can never offer to stop another.
    private(set) var ownerWatch: OwnerWatch?

    /// What the release side knows about one bound recording.
    struct OwnerWatch {
        var rule: MicrophoneOwnershipRule
        /// The name the start offer showed for this owner, or `nil` when it showed none.
        let application: String?
        /// The user kept recording, or let the offer be dismissed. Nothing more is offered until the owner
        /// is observed holding the input again.
        var isDeclined = false
        /// The presentation of the release offer standing for this watch, until its countdown ends.
        ///
        /// ⚠️ **Cleared only by the countdown reporting its end**, so a route that took the offer down
        /// without revoking its countdown leaves this set — and no second offer is raised. That is the
        /// direction that keeps recording.
        var offer: UInt64?
    }

    /// The name a prompt start was admitted with, tied to the binding it named, for the offer's sentence.
    ///
    /// ⚠️ **Tied to the binding, not to the bundle.** Two recordings of one application are two bindings;
    /// a name remembered by bundle would outlive the recording it was shown for.
    private var admittedApplication: (binding: OwnerBinding, name: String?)?

    private let service: ControlAPI
    private let reader: any AudioProcessReading
    private var activityRule = MicrophoneActivityRule()
    /// How many times the activity rule has been replaced.
    ///
    /// ⚠️ **Episode ids restart at 1 in a fresh rule, and that is a collision waiting to be exploited by
    /// an ordinary sequence of events.** An acceptance parked at the microphone barrier holds episode 1;
    /// a preference toggle or a wake rebaseline replaces the rule; a different application already
    /// holding the input is minted spent episode 1 at the new baseline; the parked acceptance resumes
    /// and its actionability check passes — against the wrong call. The token a prompt carries is
    /// therefore this epoch *and* the id, and both are re-checked.
    private var observationEpoch: UInt64 = 1
    private var quietRule = AudioActivityRule()
    /// What the release side saw on the last tick that read the process list for it.
    ///
    /// ⚠️ **`nil` whenever the release preference is off**, rather than left holding the last picture:
    /// evidence nobody was allowed to keep gathering is not evidence of the present. Published for the
    /// admission seam that binds a recording to its owner, and so a test can see that observation
    /// happens from idle rather than infer it from a read count.
    public private(set) var releaseEvidence: ObservedProcessEvidence?
    private var pollTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    /// Latched at quit **initiation**, synchronously.
    ///
    /// ⚠️ **The same window the socket teardown exists to close.** `applicationShouldTerminate` begins a
    /// `.terminateLater` finalisation; a prompt still on screen could otherwise admit a start into it.
    /// Stopping the coordinator in `applicationWillTerminate` is too late — that runs *after* the
    /// finalisation.
    private var isClosing = false

    /// When `tick` last ran, on a clock that cannot jump.
    ///
    /// ⚠️ **`Date` is not evidence of elapsed observation.** A laptop that slept for an hour, a process
    /// suspended by the system, or a clock corrected by NTP all move wall time without anything having
    /// been watched — and both rules measure *observed* intervals on purpose. A gap therefore
    /// rebaselines rather than being treated as a very long interval in which nothing happened, which is
    /// how waking a Mac would otherwise produce "record this call?" for a call that was already running.
    private var lastTick: ContinuousClock.Instant?

    /// How long a gap between observations must be before the picture is thrown away.
    ///
    /// ⚠️ Several poll intervals rather than one: a busy machine can miss a tick without anything being
    /// wrong, and rebaselining on ordinary jitter would make the start reminder miss real calls.
    public static let rebaselineAfter: Duration = .seconds(10)

    /// The threshold this instance uses. Production takes the constant; a test shortens it rather than
    /// sleeping through it.
    public var rebaselineThreshold: Duration = ReminderCoordinator.rebaselineAfter

    /// Whether the menu is open, so a prompt does not duplicate what is already on screen.
    public var isMenuOpen = false

    /// A monotonic id per recording, minted here because `ControlState` has no notion of one.
    private var recordingID: UInt64 = 0

    /// Identifies one press of one button.
    ///
    /// ⚠️ **A late answer must never speak over a newer one.** The acceptance path suspends at the
    /// settings barrier, so two presses — or a press and a fresh offer raised while the first was still
    /// parked — can land out of order. Every prompt this path publishes carries the attempt that
    /// produced it, and publishes only while it is still the current attempt.
    private var currentAttempt: UInt64 = 0

    /// Which presentation is on screen, and when it stops being answerable. Both exist so the
    /// admission point can refuse an expired offer without asking the view anything.
    /// Diagnostic only — the last set of input holders logged, so an idle machine logs nothing.
    private var lastLoggedHolders: [String]?

    private var presentation: UInt64 = 0
    private var promptDeadline: Date?
    private var wasRecording = false
    /// The capture generation the quiet rule is currently calibrated for.
    ///
    /// ⚠️ **Adopted from the summaries rather than guessed.** The recorder mints the generation, several
    /// layers below; a coordinator that assumed one would silently drop every measurement when the two
    /// disagreed — a stop reminder that never fires and never says why.
    private var currentGeneration: UInt64 = 0
    /// The title of a start accepted from a prompt whose capture has not confirmed yet.
    private var awaitingConfirmation: String?
    /// The recording count at the moment that start was accepted.
    ///
    /// ⚠️ **A title is not an identity.** Promoting on any later `.recording` state lets a delayed event
    /// — or a recording somebody started from the menu — announce success for a start that has not
    /// happened. Only a recording that began *after* the acceptance can confirm it.
    private var awaitingConfirmationAfter: UInt64 = 0
    /// The folder the recording `recordingID` names. Compared at the admission point, because a
    /// coordinator-minted counter says only how many transitions *this observer* saw.
    private var recordingDirectory: URL?

    /// How many ticks this instance has run.
    ///
    /// ⚠️ **A property rather than a log assertion.** `log` is a private `let` and the test runner has no
    /// seam that captures `os_log`, so a test that could only read the unified log would be an
    /// integration test of Apple's logging rather than of this counter.
    public private(set) var tickCount: UInt64 = 0

    /// How many heartbeats have been emitted, and the last one.
    ///
    /// ⚠️ **A count and the latest, not a list.** This instance is meant to run for days; an array of
    /// every beat would be a leak whose only reader is a test.
    public private(set) var heartbeatCount: UInt64 = 0
    public private(set) var lastHeartbeat: ReminderHeartbeat?

    /// When this instance was built, on a clock that cannot jump.
    ///
    /// ⚠️ **Construction, not `start()`.** The app builds the coordinator and starts it in the same
    /// launch, and a test drives `tick()` without ever calling `start()` — an uptime that only began at
    /// `start()` would be absent in exactly the case the beat exists to describe.
    private let startedAt = ContinuousClock.now

    /// How many ticks apart the beats are. Sixty at a one-second poll is one line a minute.
    public static let heartbeatTicks: UInt64 = 60

    /// The interval this instance uses. Production takes the constant; a test shortens it rather than
    /// driving sixty ticks to see two beats.
    public var heartbeatInterval: UInt64 = ReminderCoordinator.heartbeatTicks

    /// Ticks left before the next beat. Starts at one, so a launch is on the record immediately.
    private var ticksUntilHeartbeat: UInt64 = 1

    /// How often the process list is read.
    ///
    /// ⚠️ **One second, chosen over HAL listeners on per-process properties.** The qualification hold is
    /// three seconds, so one-second resolution is ample — expect three to four seconds from a real onset
    /// to a prompt, not exactly three. A listener would be cheaper and I cannot verify that it fires for
    /// `kAudioProcessPropertyIsRunningInput` without a live meeting to test against, and an unverified
    /// event source is a feature that silently never works.
    public static let pollInterval: Duration = .seconds(1)

    /// What "now" means to this coordinator.
    ///
    /// ⚠️ **Injectable, because the evidence and the evaluation must share a clock.** Summaries carry the
    /// time the audio was measured; the rule asks whether that evidence is fresh *now* and how long the
    /// quiet has lasted. A test that fabricates observation times while the coordinator reads the wall
    /// clock is not testing the rule — it is reading stale evidence and correctly getting nothing, which
    /// is exactly the false negative my first fixture produced.
    private let now: @Sendable () -> Date

    public init(service: ControlAPI, reader: any AudioProcessReading,
                now: @escaping @Sendable () -> Date = { MonotonicClock.now() }) {
        self.service = service
        self.reader = reader
        self.now = now
    }

    public static func live(service: ControlAPI = .shared) -> ReminderCoordinator {
        ReminderCoordinator(service: service, reader: AudioProcessProjection.live())
    }

    // MARK: - Lifecycle

    /// Begin watching. Safe to call twice.
    public func start() {
        guard pollTask == nil else { return }
        ActivitySink.shared.setHandler { [weak self] summary in
            Task { @MainActor in self?.ingest(summary) }
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        // ⚠️ **Recording identity comes from the state stream, not from sampling a Boolean once a
        // second.** A recording that stops and another that starts between two polls left the sampled
        // flag true throughout, so the id never changed — and a stop prompt raised for the first could
        // stop the second. The stream emits on every transition.
        stateTask = Task { @MainActor [weak self] in
            guard let stream = self?.service.states() else { return }
            for await state in stream {
                self?.trackRecordingIdentity(state)
            }
        }
    }

    /// Quit has begun. Called **synchronously** at quit initiation, before any finalisation.
    public func beginClosing() {
        isClosing = true
        revokeCountdown(.closing)
        prompt = nil
        stop()
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        stateTask?.cancel()
        stateTask = nil
        ActivitySink.shared.setHandler(nil)
        ActivitySink.shared.setEnabled(false)
    }

    /// The meter's publications arrive here, off the capture queue.
    ///
    /// ⚠️ A **rising** generation is adopted; a straggler from a capture that has already been replaced
    /// is not, and the rule drops it.
    public func ingest(_ summary: AudioActivitySummary) {
        // ⚠️ **Queued deliveries outlive the switch that stopped them.** `beginClosing` and `stop` remove
        // the handler, but tasks already enqueued on the main actor still arrive; without this, enough
        // of them could raise a fresh stop prompt during the quit finalisation.
        guard !isClosing, service.settings.offersStopWhenQuiet else { return }
        // ⚠️ Older evidence is refused outright rather than merely ignored by the rule: after a
        // discontinuity the coordinator has already moved to the reserved epoch, and anything below it
        // belongs to a capture that no longer exists.
        guard summary.generation >= currentGeneration else { return }
        if summary.generation > currentGeneration {
            currentGeneration = summary.generation
            quietRule.beginGeneration(summary.generation)
        }
        // ⚠️ The time the audio was measured, not the time this hop happened to run.
        quietRule.ingest(summary, at: summary.observedAt)
        evaluateQuiet()
    }

    // MARK: - Polling

    /// One observation step.
    ///
    /// ⚠️ **Public so it can be driven.** Production calls this from a one-second timer; a test calls it
    /// directly, which is the only way the admission rules — a stale episode, a quit already begun, a
    /// preference switched off between the prompt and the click — can be decided rather than raced.
    public func tick() {
        guard !isClosing else { return }
        tickCount += 1
        // ⚠️ Read at the end of the tick through `defer`, so the beat describes what this tick actually
        // did rather than what it was about to do — and so a later early return could not take the
        // record of the tick with it.
        var observation = ReminderHeartbeat.Observation.notObserved
        // ⚠️ **Settings are read before the `defer` is registered, on Codex's correction.** Captured as
        // mutable booleans assigned further down, an early return inserted between the two would make
        // the beat report both reminders *off* — a fabricated fact, in the one line whose whole job is
        // to be believed hours later.
        let settings = service.settings
        defer {
            emitHeartbeatIfDue(
                observation,
                offersRecordingWhenMicrophoneBusy: settings.offersRecordingWhenMicrophoneBusy,
                offersStopWhenQuiet: settings.offersStopWhenQuiet,
                offersStopWhenOwnerReleases: settings.offersStopWhenOwnerReleases)
        }
        rebaselineIfObservationLapsed()
        applyPreferenceChanges(settings)
        quietRule.setQuietInterval(TimeInterval(settings.quietMinutesBeforeStopOffer * 60))
        // ⚠️ Applied to the *live* meter too, not only to the next one built: switching the reminder off
        // during a recording has to stop the measuring there and then, and switching it on has to start
        // a fresh warm-up rather than resume an estimate nobody was allowed to build.
        ActivitySink.shared.setEnabled(settings.offersStopWhenQuiet)
        if !settings.offersStopWhenQuiet { quietRule.invalidate() }
        trackRecordingIdentity(service.state)

        let context = MicrophoneActivityRule.Context(
            isEnabled: settings.offersRecordingWhenMicrophoneBusy,
            isBusy: service.state.operation != .idle,
            isMenuOpen: isMenuOpen,
            excludedBundleIDs: Set(settings.reminderExcludedBundleIDs),
            ownBundleIDs: Self.ownBundleIDs,
            ownPIDs: [ProcessInfo.processInfo.processIdentifier])

        // ⚠️ **One read per tick, above both preference checks, feeding each rule by its own switch.**
        // The release side must observe from idle rather than only once a bound recording exists:
        // gating the read on the start reminder would make the release offer depend on a preference
        // the user can switch off independently — the shared authority Decision 6 of the owner-bound
        // stop plan forbids. ⚠️ **And nothing is read when neither consumer is on** — a property walk per
        // second for features nobody asked for is not worth keeping state warm; a re-enable rebaselines
        // instead. The quiet reminder measures audio, not processes, so it never gates this read.
        // ⚠️ This must **not** return either: an early exit left the quiet evaluation depending entirely
        // on summaries arriving, and with a stalled meter a standing stop offer would never notice it had
        // gone stale.
        let observesProcesses = settings.offersRecordingWhenMicrophoneBusy
            || settings.offersStopWhenOwnerReleases
        if !settings.offersStopWhenOwnerReleases { releaseEvidence = nil }
        if observesProcesses {
            let snapshot = reader.readSnapshot()
            let observedAt = now()
            observation = .observed(processes: snapshot.processes.count,
                                    isComplete: snapshot.isComplete,
                                    holders: snapshot.processes.filter { $0.isRunningInput == true }.count)
            // ⚠️ **Diagnostic, added because the feature was silent through a real 95-second Slack
            // huddle** with the preference on and nothing excluded, and reading the rule did not
            // explain it. Logged only when the set of input holders changes, so an idle machine is
            // silent.
            let holders = snapshot.processes.filter { $0.isRunningInput == true }
                .map { $0.bundleID ?? "pid:\($0.pid)" }.sorted()
            if holders != lastLoggedHolders {   // nil on the first tick, so it always logs once
                lastLoggedHolders = holders
                log.info("observed \(snapshot.processes.count, privacy: .public) processes, complete=\(snapshot.isComplete, privacy: .public), holding=[\(holders.joined(separator: ", "), privacy: .public)]")
            }
            if settings.offersRecordingWhenMicrophoneBusy {
                observeActivity(snapshot, at: observedAt, context: context)
            }
            if settings.offersStopWhenOwnerReleases {
                // ⚠️ **Folded with Acta's own processes dropped and nothing else.** The start reminder's
                // exclusion list is deliberately absent: "do not offer to record Slack" is not consent to
                // disregard Slack while deciding who may stop a recording.
                releaseEvidence = ObservedProcessEvidence(
                    evidence: AudioProcessReadings.evidence(
                        from: snapshot,
                        dropping: .init(bundleIDs: Self.ownBundleIDs,
                                        pids: [ProcessInfo.processInfo.processIdentifier])),
                    observedAt: observedAt,
                    epoch: observationEpoch)
            }
        }

        evaluateQuiet()
        // ⚠️ **After the quiet evaluation**, so a quiet offer raised on this tick is already on the panel
        // and the release offer, which only ever takes an empty one, waits behind it.
        observeOwnerRelease(settings)
        // ⚠️ **Last, after everything this tick observed.** Evidence that should cancel a countdown has to
        // reach it before the countdown is asked whether it has run out.
        evaluateCountdown()
    }

    /// Feed the start reminder's rule one snapshot, and act on what it says.
    private func observeActivity(_ snapshot: AudioProcessSnapshot, at observedAt: Date,
                                 context: MicrophoneActivityRule.Context) {
        switch activityRule.observe(snapshot, at: observedAt, context: context) {
        case .none:
            break
        case .offer(let episode):
            // ⚠️ **Instrumentation, and it decides a design question rather than decorating one.**
            // Whether a per-application mode can ever be remembered depends on there being a durable
            // key: a bundle identifier survives a helper restart, a PID does not. Nothing recorded this,
            // so every claim about it so far has been inference from an absent display name — which is
            // nil for three different reasons, only one of them a helper. One huddle and one call now
            // settle it.
            log.info("episode \(episode.id, privacy: .public) minted — bundle=\(episode.bundleID ?? "<none>", privacy: .public) display=\(episode.displayName ?? "<none>", privacy: .public) process=\(episode.processName ?? "<none>", privacy: .public)")
            present(.offerToRecord(episodeID: token(for: episode.id),
                                   application: episode.displayName,
                                   bundleID: episode.bundleID,
                                   suggestedTitle: service.state.suggestedTitle,
                                   microphone: service.microphoneStatus.captureSummary))
        case .withdraw(let episodeID):
            log.info("episode \(episodeID, privacy: .public) withdrawn — the holder let go")
            withdrawStartOffer(token(for: episodeID))
        }
    }

    /// Feed the recording's owner the release evidence this tick gathered, and offer to stop when it has
    /// let the microphone go for long enough.
    ///
    /// ⚠️ **Only a bound recording is watched**, and the binding is read from the recorder on every tick
    /// rather than remembered: a recording that stopped and one that started between two ticks carry
    /// different admissions, and the watch is rebuilt the moment they differ.
    ///
    /// ⚠️ **The offer is raised only onto an empty panel.** A prompt already on screen may be what the user
    /// is reading, and a countdown that took its place would start acting on a panel nobody had looked at
    /// yet. The reverse is allowed: a quiet offer raised while the countdown runs replaces it — displacement
    /// only ever moves toward the prompt that keeps recording — and the countdown is revoked, never handed on.
    ///
    /// ⚠️ **Deferred while the menu is open**, as the quiet offer is: the menu already shows the recording
    /// and its Stop button, and a panel raised over it would duplicate the one control the user is looking
    /// at. Unlike the quiet offer this spends nothing — the release stays qualified and is offered once the
    /// menu closes. A countdown already running is **not** revoked by opening the menu; if the menu hides
    /// the panel, the presenter reports the presentation lost, which does revoke it.
    private func observeOwnerRelease(_ settings: RecordingSettings) {
        guard settings.offersStopWhenOwnerReleases, wasRecording,
              let binding = service.state.ownerAdmission?.binding else {
            if ownerWatch != nil {
                ownerWatch = nil
                if case .offerToStopOnRelease = prompt { prompt = nil }
            }
            return
        }
        if ownerWatch?.rule.owner != binding {
            if case .offerToStopOnRelease = prompt { prompt = nil }
            let name = admittedApplication?.binding == binding ? admittedApplication?.name : nil
            ownerWatch = OwnerWatch(rule: MicrophoneOwnershipRule(owner: binding), application: name)
        }
        guard var watch = ownerWatch, let observed = releaseEvidence else { return }
        let outcome = watch.rule.observe(observed.evidence, at: observed.observedAt)
        if case .held = watch.rule.phase { watch.isDeclined = false }
        // ⚠️ Stored before anything below can revoke a countdown, because revocation writes to the watch.
        ownerWatch = watch
        switch outcome {
        case .ownerReturned:
            log.info("owner \(binding.bundleID, privacy: .public) is holding the input again")
            withdrawReleaseOffer(.ownerReturned)
        case .evidenceLost:
            log.info("owner \(binding.bundleID, privacy: .public) release lost its evidence")
            withdrawReleaseOffer(.evidenceLost)
        case .releaseQualified:
            log.notice("owner \(binding.bundleID, privacy: .public) released the input for the full interval")
        case .none:
            break
        }

        guard let current = ownerWatch, case .releasedQualified = current.rule.phase, !current.isDeclined,
              current.offer == nil, prompt == nil, !isMenuOpen,
              case .recording = service.state.operation, recordingDirectory != nil else { return }
        presentCountdown(.offerToStopOnRelease(recordingID: recordingID, title: service.title,
                                               text: OwnerReleaseOfferText(application: current.application)))
        ownerWatch?.offer = presentation
    }

    /// Take a standing release offer down, and its countdown with it, whether acknowledged or not.
    private func withdrawReleaseOffer(_ reason: AcknowledgedCountdown.Revocation) {
        guard case .offerToStopOnRelease = prompt else { return }
        revokeCountdown(reason)
        prompt = nil
    }

    /// Emit a beat if this tick is due one.
    ///
    /// ⚠️ **`.notice`, chosen against the two cheaper levels.** Apple documents `.notice` as persisted to
    /// the store, and `.info` and `.debug` as normally memory-only unless something asks for them — and
    /// the defect this exists for appears after *hours*, long enough for a memory buffer to have wrapped
    /// before anyone thinks to look. ⚠️ Persisted is not permanent: the store has a size limit and this
    /// promises no particular retention. About 1440 short records a day of continuous running is a
    /// judgement about a reasonable cost, not a measurement of one. The holder diagnostic beside it
    /// stays `.info`: it is read while reproducing, not hours later.
    ///
    /// ⚠️ **Beats are emitted from `tick`, so a stopped tick emits none.** That is the signal, not a
    /// gap in it — do not add a separate timer to keep beating when the loop this describes has died.
    private func emitHeartbeatIfDue(_ observation: ReminderHeartbeat.Observation,
                                    offersRecordingWhenMicrophoneBusy: Bool,
                                    offersStopWhenQuiet: Bool,
                                    offersStopWhenOwnerReleases: Bool) {
        ticksUntilHeartbeat -= 1
        guard ticksUntilHeartbeat == 0 else { return }
        ticksUntilHeartbeat = max(1, heartbeatInterval)
        let beat = ReminderHeartbeat(
            tick: tickCount, uptime: ContinuousClock.now - startedAt, observation: observation,
            offersRecordingWhenMicrophoneBusy: offersRecordingWhenMicrophoneBusy,
            offersStopWhenQuiet: offersStopWhenQuiet,
            offersStopWhenOwnerReleases: offersStopWhenOwnerReleases)
        heartbeatCount += 1
        lastHeartbeat = beat
        let seen: String
        switch observation {
        case .observed(let processes, let isComplete, let holders):
            seen = "processes=\(processes) complete=\(isComplete) holding=\(holders)"
        case .notObserved:
            seen = "not observed"
        }
        let seconds = beat.uptime.components.seconds
        log.notice("""
            heartbeat tick=\(beat.tick, privacy: .public) uptime=\(seconds, privacy: .public)s \
            \(seen, privacy: .public) \
            start=\(offersRecordingWhenMicrophoneBusy, privacy: .public) \
            quiet=\(offersStopWhenQuiet, privacy: .public) \
            release=\(offersStopWhenOwnerReleases, privacy: .public)
            """)
    }

    /// Throw the picture away after a gap in which nothing was observed.
    private func rebaselineIfObservationLapsed() {
        let now = ContinuousClock.now
        defer { lastTick = now }
        guard let lastTick, now - lastTick > rebaselineThreshold else { return }
        log.info("rebaselining the reminders after an unobserved gap")
        // ⚠️ A fresh rule, not a cleared one: the baseline is what makes an application already holding
        // the input at this instant silent, and that is exactly the state a wake needs.
        resetActivityRule()
        adoptReservedEpoch()
        quietRule.invalidate()
        // ⚠️ **No catch-up after a wake.** A countdown the Mac slept through never gave the user the
        // interval it promised; it is withdrawn, and only fresh evidence and a new, fully shown countdown
        // may ask again.
        if revokeCountdown(.observationLapsed) { prompt = nil }
        if case .offerToRecord = prompt {
            prompt = nil
        }
        if case .offerToStop = prompt {
            quietRule.offerResolved()
            prompt = nil
        }
    }

    /// What the quiet rule believes about one track — exposed so a failing test can say *why* rather
    /// than only that nothing happened.
    public func trackStateForTesting(_ track: AudioActivitySummary.Track)
        -> AudioActivityRule.TrackState {
        quietRule.state(of: track, at: now())
    }

    /// A preference switched off must take the prompt it governs off the screen, and must never act on
    /// the recording while doing so.
    private func applyPreferenceChanges(_ settings: RecordingSettings) {
        if !settings.offersRecordingWhenMicrophoneBusy {
            if case .offerToRecord(let shown, _, _, _, _) = prompt {
                if let episodeID = episode(in: shown) {
                    activityRule.offerResolved(episodeID: episodeID)
                }
                prompt = nil
            }
            // Re-enabling starts from a fresh baseline rather than from episodes nobody was watching.
            resetActivityRule()
        }
        if !settings.offersStopWhenQuiet, case .offerToStop = prompt {
            quietRule.offerResolved()
            prompt = nil
        }
        // ⚠️ The countdown belongs to the release offer, and only that preference governs it.
        if !settings.offersStopWhenOwnerReleases, revokeCountdown(.preferenceOff) {
            prompt = nil
        }
    }

    /// Move to the epoch the meter will stamp from now on, so everything already in flight is refused.
    private func adoptReservedEpoch() {
        // ⚠️ **The floor moves whether or not a meter exists.** Asking the sink and giving up when it
        // answers nothing made the revocation conditional on something the coordinator does not own —
        // and "no meter is running" is exactly the state in which stale deliveries are still in flight.
        let reserved = ActivitySink.shared.reserveNextEpoch() ?? 0
        currentGeneration = max(currentGeneration + 1, reserved)
        quietRule.beginGeneration(currentGeneration)
    }

    /// The token a prompt carries: an observation epoch and an episode id, so an id minted by a
    /// different rule cannot answer for this one.
    private func token(for episodeID: UInt64) -> UInt64 {
        (observationEpoch << 40) | (episodeID & 0xFF_FFFF_FFFF)
    }

    /// The episode id inside `token`, or `nil` when it belongs to a rule that has since been replaced.
    private func episode(in token: UInt64) -> UInt64? {
        guard token >> 40 == observationEpoch else { return nil }
        return token & 0xFF_FFFF_FFFF
    }

    /// Replace the activity rule, and with it every token it ever minted.
    private func resetActivityRule() {
        observationEpoch += 1
        activityRule = MicrophoneActivityRule()
    }

    /// ⚠️ Both flavours, because they coexist on purpose and neither must offer to record the other.
    private static let ownBundleIDs: Set<String> = [
        "dev.personal.acta", "dev.personal.acta-dev",
        Bundle.main.bundleIdentifier,
    ].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }

    private func trackRecordingIdentity(_ state: ControlState) {
        let isRecording: Bool
        switch state.operation {
        case .recording, .starting: isRecording = true
        case .idle, .saving: isRecording = false
        }
        // ⚠️ **A changed folder is a changed recording, whatever the sampled flag says.** A stop and a
        // start between two observations leave "is recording" true throughout, so a counter driven by
        // that flag never moves — and a stop prompt raised for the first could stop the second.
        let directory = service.activeRecordingDirectory
        if isRecording, !wasRecording || directory != recordingDirectory {
            recordingID += 1
            recordingDirectory = directory
            // ⚠️ **Evidence from the previous recording is revoked here, not when the next summary
            // happens to arrive.** Until then a queued summary carries exactly the epoch this
            // coordinator considers current, and would warm the new recording's estimate with the old
            // one's audio.
            adoptReservedEpoch()
            quietRule.beginRecording(recordingID, generation: currentGeneration)
            if case .offerToStop = prompt { prompt = nil }
            if case .offerToStopOnRelease = prompt { prompt = nil }
        }
        // ⚠️ Promotion happens on `.recording`, never on `.starting`: capture writing segments is what
        // the confirmation claims, and `.starting` is precisely the state in which that is not yet known.
        if case .recording = state.operation, let title = awaitingConfirmation,
           recordingID > awaitingConfirmationAfter {
            awaitingConfirmation = nil
            present(.startedRecording(title: title))
        }
        if case .idle = state.operation, awaitingConfirmation != nil {
            // The start failed, or was cancelled. The panel must not be left claiming otherwise.
            awaitingConfirmation = nil
            if case .startingRecording = prompt { prompt = nil }
        }
        if !isRecording, wasRecording {
            recordingDirectory = nil
            adoptReservedEpoch()
            quietRule.invalidate()
            if case .offerToStop = prompt { prompt = nil }
            if case .offerToStopOnRelease = prompt { prompt = nil }
        }
        wasRecording = isRecording
    }

    private func evaluateQuiet() {
        guard !isClosing, wasRecording else { return }
        let settings = service.settings
        let context = AudioActivityRule.Context(isEnabled: settings.offersStopWhenQuiet,
                                                recordingID: recordingID)
        switch quietRule.evaluate(at: now(), context: context) {
        case .none:
            break
        case .offerStop(let id):
            guard id == recordingID, !isMenuOpen else { return }
            var elapsed = 0
            if case .recording(let seconds) = service.state.operation { elapsed = seconds }
            present(.offerToStop(recordingID: id, title: service.title, elapsedSeconds: elapsed))
        case .withdraw(let id):
            if case .offerToStop(let shown, _, _) = prompt, shown == id { prompt = nil }
        }
    }

    /// How long each prompt stays answerable — **the authoritative lifetime**, owned here rather than
    /// by the panel that draws it.
    ///
    /// ⚠️ **The view's dismissal timer is a convenience; this is the rule.** A `Timer` can be late or
    /// can fail to fire — a panel was observed still on screen forty-three seconds after a twenty-second
    /// offer was raised — and a late timer must never be able to *admit* a click that the offer's own
    /// deadline has already refused. So the deadline is recorded when the prompt is published and
    /// checked again at the admission point, where it outranks whatever the panel happens to be showing.
    public static func lifetime(of prompt: ReminderPrompt) -> TimeInterval {
        switch prompt {
        case .offerToRecord: return 20
        case .offerToStop: return 30
        // ⚠️ **Must outlast the countdown**, or `isWithinDeadline` refuses a Stop Now pressed in its last
        // seconds: twenty for the countdown and ten for the panel to reach the screen. An acknowledgement
        // later than that extends the deadline to the countdown's own — see `acknowledgePresentation`.
        case .offerToStopOnRelease: return 30
        case .startingRecording: return 12
        case .startedRecording: return 3
        case .checkingStart: return 12
        case .startNoLongerAvailable: return 6
        }
    }

    private func present(_ newPrompt: ReminderPrompt) {
        present(newPrompt, countdown: nil)
    }

    /// Publish a prompt that carries a countdown. The countdown does not run until the presenter
    /// acknowledges this presentation as on screen.
    ///
    /// ⚠️ **Internal.** Production's one caller is the release stop offer; the presenter tests call it with
    /// a carrier prompt to exercise the contract on its own.
    func presentCountdown(_ newPrompt: ReminderPrompt,
                          configuration: AcknowledgedCountdown.Configuration = .default) {
        present(newPrompt, countdown: configuration)
    }

    private func present(_ newPrompt: ReminderPrompt,
                         countdown configuration: AcknowledgedCountdown.Configuration?) {
        // ⚠️ One at a time, never a stack. A second prompt replaces the first rather than queueing
        // behind it: two offers about two different moments, both stale by the time they are read, is
        // worse than one. A countdown on the prompt being replaced is revoked, never inherited.
        revokeCountdown(.replaced)
        // ⚠️ **The deadline is set once per prompt and never extended by a redraw.** Re-publishing the
        // same offer must not buy it another twenty seconds; that is how an offer outlives the evidence
        // behind it.
        presentation &+= 1
        promptDeadline = now().addingTimeInterval(Self.lifetime(of: newPrompt))
        log.debug("prompt \(self.presentation, privacy: .public) presented, answerable for \(Self.lifetime(of: newPrompt), privacy: .public)s")
        let attached = configuration.map { AcknowledgedCountdown(presentation: presentation, configuration: $0) }
        countdown = attached
        lastRenderedSeconds = attached?.fullSeconds
        prompt = newPrompt
        // ⚠️ **After the state is in place.** A presenter may acknowledge from inside `show`, and that
        // acknowledgement must find the countdown it names.
        presenter?.show(ReminderPresentation(id: presentation, prompt: newPrompt,
                                             secondsRemaining: attached?.fullSeconds))
    }

    // MARK: - The presenter contract

    /// The presenter says this presentation is on screen.
    ///
    /// ⚠️ **The only thing that starts a countdown.** Its deadline is measured from here, on this
    /// coordinator's clock; a second acknowledgement, or one for a presentation that has been replaced,
    /// changes nothing.
    public func acknowledgePresentation(_ id: UInt64) {
        guard !isClosing, var current = countdown else { return }
        guard current.acknowledge(presentation: id, at: now()) else { return }
        countdown = current
        // ⚠️ **The prompt stays answerable for as long as its countdown runs.** The lifetime is counted from
        // publication, and a late acknowledgement starts a full countdown that could otherwise outlive it —
        // leaving a Stop Now pressed in the last seconds refused while the countdown itself went on to
        // stop. Extended once, here, to the countdown's own deadline, which nothing can move afterwards.
        if case .running(let deadline) = current.phase {
            promptDeadline = max(promptDeadline ?? deadline, deadline)
        }
        log.info("countdown for prompt \(id, privacy: .public) acknowledged on screen")
    }

    /// The presenter can no longer show this presentation — the screen locked or went to sleep.
    ///
    /// ⚠️ **Withdraws a countdown, and leaves every other prompt alone.** A prompt without a countdown
    /// authorises nothing by staying up, so losing sight of it changes nothing it could do.
    public func presentationLost(_ id: UInt64) {
        guard id == presentation, countdown?.presentation == id else { return }
        if revokeCountdown(.presentationLost) {
            log.info("countdown for prompt \(id, privacy: .public) lost its presentation")
            prompt = nil
        }
    }

    /// End the attached countdown early. Returns whether one was live.
    @discardableResult
    private func revokeCountdown(_ reason: AcknowledgedCountdown.Revocation) -> Bool {
        guard var current = countdown, current.revoke(reason) else { return false }
        countdown = current
        log.info("countdown for prompt \(current.presentation, privacy: .public) revoked: \(String(describing: reason), privacy: .public)")
        releaseOfferEnded(current.presentation, revokedBy: reason)
        return true
    }

    /// The countdown of `presentation` has ended, by revocation or — `nil` — by completing.
    ///
    /// ⚠️ **What an ended release offer leaves behind depends on why it ended.** Kept or dismissed: the user
    /// was asked, and is not asked again until the owner returns. Lost from the screen or not watched: the
    /// user never had the promised interval, so the release must be observed afresh before a new offer.
    /// Replaced, withdrawn, switched off: nothing about the release changed, and the next empty panel may
    /// carry a new offer with a full countdown — never the old one's remainder.
    private func releaseOfferEnded(_ presentation: UInt64, revokedBy reason: AcknowledgedCountdown.Revocation?) {
        guard ownerWatch?.offer == presentation else { return }
        ownerWatch?.offer = nil
        switch reason {
        case .dismissed:
            ownerWatch?.isDeclined = true
        case .presentationLost, .observationLapsed:
            ownerWatch?.rule.discardAccumulatedRelease()
        case .replaced, .preferenceOff, .closing, .withdrawn, .ownerReturned, .evidenceLost, nil:
            break
        }
    }

    /// Ask the countdown where it stands, and pass the answer on.
    private func evaluateCountdown() {
        guard !isClosing, var current = countdown else { return }
        let outcome = current.evaluate(at: now())
        countdown = current
        switch outcome {
        case .none:
            break
        case .remaining(let seconds):
            guard seconds != lastRenderedSeconds, let shown = prompt else { return }
            lastRenderedSeconds = seconds
            presenter?.updateCountdown(ReminderPresentation(id: current.presentation, prompt: shown,
                                                            secondsRemaining: seconds))
        case .completed:
            log.notice("countdown for prompt \(current.presentation, privacy: .public) ran its full acknowledged duration")
            authorisedCountdown = current.presentation
            let wasReleaseOffer = ownerWatch?.offer == current.presentation
            let shown = prompt
            releaseOfferEnded(current.presentation, revokedBy: nil)
            prompt = nil
            // ⚠️ **The narrow exception, and the only place a timer stops a recording.** Reached only by a
            // countdown that was acknowledged on screen and evaluated without a gap to its deadline; the
            // stop re-checks everything a click would, plus that the release is still qualified.
            if wasReleaseOffer, case .offerToStopOnRelease(let id, _, _)? = shown {
                stopForOwnerRelease(recordingID: id, requiringQualifiedRelease: true)
            }
        case .revoked(let reason):
            let id = current.presentation
            log.info("countdown for prompt \(id, privacy: .public) revoked: \(String(describing: reason), privacy: .public)")
            releaseOfferEnded(id, revokedBy: reason)
            prompt = nil
        }
    }

    /// Test-facing: whether the rule still considers this token's episode actionable. It exists so a
    /// deadline test can assert that the deadline — and nothing else — is what refused the click.
    public func isEpisodeActionableForTesting(_ token: UInt64) -> Bool {
        guard let episodeID = episode(in: token) else { return false }
        return activityRule.isEpisodeActionable(episodeID)
    }

    /// Whether the prompt on screen may still be answered.
    private func isWithinDeadline() -> Bool {
        guard let promptDeadline else { return false }
        return now() < promptDeadline
    }

    /// Whether the countdown on screen has reached its deadline but not yet the tick that completes it.
    ///
    /// ⚠️ **The prompt's deadline ends where the countdown's does, and the countdown completes only on the
    /// next evaluation** — up to a tick later, with the panel still reading "1 s". A Stop Now in that gap
    /// asks for exactly what the countdown is about to do, so it stays answerable until the countdown could
    /// no longer complete.
    private func isCountdownAwaitingItsCompletionTick() -> Bool {
        guard let current = countdown, current.presentation == presentation,
              case .running(let deadline) = current.phase else { return false }
        return now() < deadline.addingTimeInterval(current.configuration.maxEvaluationGap)
    }

    private func withdrawStartOffer(_ token: UInt64) {
        if case .offerToRecord(let shown, _, _, _, _) = prompt, shown == token {
            prompt = nil
        }
        if let episodeID = episode(in: token) { activityRule.offerResolved(episodeID: episodeID) }
    }

    // MARK: - Answers

    /// Start recording, from a prompt.
    ///
    /// ⚠️ **The identity is re-checked here, in the same turn as the command.** The episode may have
    /// ended while the prompt sat on screen — the application released the input at t+1 and the click
    /// arrives at t+15 — and the anti-duplicate grace that keeps the episode *alive* for thirty seconds
    /// says nothing about whether a call is still in progress. `isEpisodeActionable` is the question
    /// that does.
    public func acceptStart(episodeID token: UInt64) {
        guard case .offerToRecord(let shown, let application, let bundleID, let intendedTitle, _) = prompt,
              shown == token else { return }
        // ⚠️ **The offer's own deadline, not the panel's timer.** The view arms a `Timer` to take the
        // prompt down, and a timer can be late or can fail to fire — a panel was observed still on
        // screen forty-three seconds after a twenty-second offer. A click that arrives after the
        // deadline is refused here regardless of what the user was looking at, so a delayed dismissal
        // can never *admit* anything.
        guard isWithinDeadline() else {
            log.info("start offer \(token, privacy: .public) was clicked after its deadline")
            currentAttempt &+= 1
            present(.startNoLongerAvailable(attempt: currentAttempt))
            return
        }
        guard let episodeID = episode(in: token) else { return }
        let acceptedEpoch = observationEpoch
        // ⚠️ **The offer is replaced, not simply removed.** It used to become `nil` here, so between
        // the click and whatever the checks below decided there was nothing on screen at all — and if a
        // check refused, that was the whole of the user's feedback: the panel vanished and no recording
        // began. Every exit from this path now leaves something visible.
        currentAttempt &+= 1
        let attempt = currentAttempt
        activityRule.offerResolved(episodeID: episodeID)
        present(.checkingStart(attempt: attempt, title: intendedTitle))

        Task { @MainActor [weak self] in
            guard let self else { return }
            // ⚠️ **The same barrier a socket `start` waits on.** Settings reach the microphone owner
            // asynchronously; starting before the capture policy has landed records under the previous
            // one — the defect this barrier was added for. A click is no more entitled to skip it than
            // a socket client is.
            await self.service.settleMicrophoneSettings()

            // ⚠️ **Everything is re-checked after the await, in this turn, with no suspension between
            // the check and the command.** Quit may have begun, the preference may have been switched
            // off, the call may have ended, and a recording may have started by another route.
            // ⚠️ Quitting is the one exit that shows nothing: a panel reopening as the app goes away
            // is worse than silence, and there is nobody left to act on it.
            guard !self.isClosing else {
                self.withdrawAttempt(attempt)
                return
            }
            guard self.service.settings.offersRecordingWhenMicrophoneBusy else {
                self.withdrawAttempt(attempt)
                return
            }
            // ⚠️ **The rule that minted this id must still be the rule being asked.** A reset during the
            // wait restarts episode numbering at one, and numeric equality inside a fresh rule is not
            // identity continuity — it is a different call wearing the same number.
            guard self.observationEpoch == acceptedEpoch else {
                self.log.info("start offer \(token, privacy: .public) outlived the rule that made it")
                self.reportStale(attempt)
                return
            }
            guard self.activityRule.isEpisodeActionable(episodeID) else {
                self.log.info("start offer \(episodeID, privacy: .public) is no longer actionable")
                self.reportStale(attempt)
                return
            }
            // Already recording by some other route: not stale, just already done.
            guard self.service.state.canStart else {
                self.withdrawAttempt(attempt)
                return
            }
            // ⚠️ The title the prompt promised, not whatever the field holds now: "Will save as X" has
            // to be true, and `service.title` can have been edited in the menu since.
            // ⚠️ **The owner is resolved inside the recorder's latching turn, after the barrier, from the
            // episode captured before it.** Resolving at the click would bind evidence the barrier has
            // since outdated; resolving from whatever holds the input now would bind a newer candidate.
            self.service.start(title: intendedTitle) {
                self.resolveOwner(episodeID: episodeID, bundleID: bundleID, application: application,
                                  acceptedEpoch: acceptedEpoch)
            }
            // Honest until the recorder says otherwise; `trackRecordingIdentity` promotes or withdraws it.
            self.awaitingConfirmation = intendedTitle
            self.awaitingConfirmationAfter = self.recordingID
            // ⚠️ "Starting…" only **after** the command is issued, never while the barrier is awaited.
            // The panel's oldest rule is that it does not claim a recording is under way before one is.
            self.present(.startingRecording(title: intendedTitle))
        }
    }

    /// The owner a prompt-started recording is admitted with, re-checked against the evidence held now.
    ///
    /// ⚠️ **The episode's identity is preserved, its evidence is not trusted.** The key comes from the
    /// prompt, never from the readings; the epoch, the key's reading and the time are taken from the
    /// latest release evidence. No HAL read happens here — this is the state the last tick already folded.
    ///
    /// ⚠️ **Every answer starts a recording.** A withheld binding is logged with its reason and the start
    /// proceeds unbound.
    private func resolveOwner(episodeID: UInt64, bundleID: String?, application: String?,
                              acceptedEpoch: UInt64) -> OwnerAdmission {
        let admission: OwnerAdmission
        if let observed = releaseEvidence {
            if observed.epoch != acceptedEpoch {
                admission = .unbound(.evidenceFromAnotherEpoch)
            } else {
                admission = OwnerAdmission.admit(
                    episode: MicrophoneActivityEpisode(id: episodeID, bundleID: bundleID, displayName: nil),
                    holding: observed.evidence.readings,
                    epoch: observed.epoch,
                    observedAt: observed.observedAt)
            }
        } else {
            admission = .unbound(.releaseNotObserved)
        }
        switch admission {
        case .bound(let binding):
            admittedApplication = (binding, application)
            log.notice("recording admitted bound to \(binding.bundleID, privacy: .public)")
        case .unbound(let reason):
            log.notice("recording admitted unbound: \(String(describing: reason), privacy: .public)")
        }
        return admission
    }

    /// Say that the offer went stale — but only if this attempt is still the one on screen.
    private func reportStale(_ attempt: UInt64) {
        guard currentAttempt == attempt else { return }
        guard case .checkingStart(let shown, _) = prompt, shown == attempt else { return }
        present(.startNoLongerAvailable(attempt: attempt))
    }

    /// Take this attempt's panel down without saying anything — for the exits where there is nothing
    /// useful to say, or nobody left to say it to.
    private func withdrawAttempt(_ attempt: UInt64) {
        guard currentAttempt == attempt else { return }
        if case .checkingStart(let shown, _) = prompt, shown == attempt { prompt = nil }
    }

    public func declineStart(episodeID token: UInt64) {
        if let episodeID = episode(in: token) { activityRule.offerResolved(episodeID: episodeID) }
        dismiss()
    }

    /// Never ask for this application again.
    public func excludeApplication(bundleID: String, episodeID: UInt64) {
        var settings = service.settings
        guard !settings.reminderExcludedBundleIDs.contains(bundleID) else { return dismiss() }
        settings.reminderExcludedBundleIDs.append(bundleID)
        service.settings = settings
        service.saveSettings()
        declineStart(episodeID: episodeID)
    }

    /// Stop and save, from a prompt.
    ///
    /// ⚠️ **Bound to the recording it was raised for.** A prompt about a recording that has already been
    /// stopped, and replaced by another, must not stop the replacement.
    public func acceptStop(recordingID id: UInt64) {
        guard case .offerToStop(let shown, _, _) = prompt, shown == id else { return }
        // ⚠️ The same authoritative deadline the start offer uses. An expired stop offer is the safe
        // direction — it keeps recording — so this one simply takes the panel down and says nothing
        // more: there is no action that failed, only one that was never taken.
        guard isWithinDeadline() else {
            log.info("stop offer \(id, privacy: .public) was clicked after its deadline")
            prompt = nil
            return
        }
        prompt = nil
        quietRule.offerResolved()
        guard !isClosing else { return }
        guard service.settings.offersStopWhenQuiet else { return }
        guard id == recordingID else {
            log.info("stop offer \(id, privacy: .public) belongs to a finished recording")
            return
        }
        guard case .recording = service.state.operation else { return }
        // ⚠️ **Asked of the recorder, not of the observer, and in this turn.** The state stream is
        // documented as lossy, so "the coordinator thinks this is still recording A" is not evidence;
        // the folder being written into is.
        guard service.activeRecordingDirectory == recordingDirectory else {
            log.info("stop offer \(id, privacy: .public) names a recording that has been replaced")
            return
        }
        service.stop()
    }

    public func keepRecording() {
        quietRule.offerResolved()
        dismiss()
    }

    /// Stop Now, from the release offer.
    ///
    /// ⚠️ **A click, so it does not ask whether the release is still qualified** — the user decided about
    /// their recording, and an owner that returned would already have taken the offer down. Everything
    /// else a stop is bound to is re-checked, in this turn.
    public func acceptReleaseStop(recordingID id: UInt64) {
        guard case .offerToStopOnRelease(let shown, _, _) = prompt, shown == id else { return }
        guard isWithinDeadline() || isCountdownAwaitingItsCompletionTick() else {
            log.info("release stop offer \(id, privacy: .public) was clicked after its deadline")
            // ⚠️ **A refused Stop Now is not a decline.** The user asked for the stop; recording it as Keep
            // would silence the offer for the rest of the recording. Ended as the panel's timer or the tick
            // would have ended it, each of which leaves the release to be observed afresh.
            if case .running? = countdown?.phase {
                revokeCountdown(.observationLapsed)
            } else {
                revokeCountdown(.presentationLost)
            }
            prompt = nil
            return
        }
        dismiss()
        stopForOwnerRelease(recordingID: id, requiringQualifiedRelease: false)
    }

    /// Keep Recording, from the release offer: nothing more is offered until the owner holds the input again.
    ///
    /// ⚠️ **Never deadline-gated.** Keeping the recording is the safe direction, and a refused Keep would
    /// leave the countdown running to a stop the user just declined.
    public func keepRecordingAfterRelease(recordingID id: UInt64) {
        guard case .offerToStopOnRelease(let shown, _, _) = prompt, shown == id else { return }
        dismiss()
    }

    /// Stop the recording a release offer was raised for — if it is still that recording.
    ///
    /// ⚠️ **The identity checks of the quiet offer, plus the owner.** The recording must be the one the offer
    /// named, by the coordinator's id and by the folder the recorder is writing into, and it must still be
    /// admitted with the binding the watch was built from. A countdown additionally requires the release to
    /// still stand qualified: evidence gathered in this tick reached the rule before the countdown was asked.
    private func stopForOwnerRelease(recordingID id: UInt64, requiringQualifiedRelease: Bool) {
        guard !isClosing, service.settings.offersStopWhenOwnerReleases else { return }
        guard id == recordingID else {
            log.info("release stop offer \(id, privacy: .public) belongs to a finished recording")
            return
        }
        guard case .recording = service.state.operation else { return }
        guard let directory = recordingDirectory, service.activeRecordingDirectory == directory else {
            log.info("release stop offer \(id, privacy: .public) names a recording that has been replaced")
            return
        }
        guard let watch = ownerWatch, service.state.ownerAdmission?.binding == watch.rule.owner else {
            log.info("release stop offer \(id, privacy: .public) names an owner the recording no longer has")
            return
        }
        if requiringQualifiedRelease {
            guard case .releasedQualified = watch.rule.phase else { return }
        }
        let cause = requiringQualifiedRelease ? "the release countdown completed" : "Stop Now"
        log.notice("stopping recording \(id, privacy: .public): \(cause, privacy: .public)")
        service.stop()
    }

    /// "Remind me in thirty minutes", bound to this recording.
    public func snooze(recordingID id: UInt64, minutes: Int = 30) {
        guard id == recordingID else { return dismiss() }
        quietRule.armSnooze(until: now().addingTimeInterval(TimeInterval(minutes * 60)),
                            recordingID: id)
        dismiss()
    }

    /// The presenter's own lifetime for this presentation ran out. **Never an action, and never an answer.**
    ///
    /// ⚠️ **Scoped by presentation, not by prompt.** Two release offers for one recording are equal prompts;
    /// an expiry enqueued for the first must not take down the second.
    ///
    /// ⚠️ **A countdown is not the user's to have declined by a timer.** Still awaiting acknowledgement,
    /// it was never on screen — a locked display, a sleeping one — so it ends as a lost presentation, and
    /// the release must be observed afresh. Running, it owns its own end: the tick completes it or revokes
    /// it, and an expiry that pre-empted it would cut short the interval an acknowledgement promised, and
    /// record a decline nobody made. Every other prompt is dismissed as before.
    public func expire(_ presentationID: UInt64) {
        guard presentationID == presentation, prompt != nil else { return }
        if let current = countdown, current.presentation == presentationID {
            switch current.phase {
            case .running:
                return
            case .awaitingAcknowledgement:
                log.info("countdown for prompt \(presentationID, privacy: .public) expired unacknowledged")
                revokeCountdown(.presentationLost)
                prompt = nil
                return
            case .completed, .revoked:
                break
            }
        }
        dismiss()
    }

    /// The user clicked away. **Never an action.**
    ///
    /// ⚠️ **Identity-scoped.** A dismissal enqueued for prompt A must not take prompt B off the screen;
    /// the caller says which prompt it is dismissing.
    public func dismiss(_ expected: ReminderPrompt) {
        guard prompt == expected else { return }
        dismiss()
    }

    public func dismiss() {
        revokeCountdown(.dismissed)
        if case .offerToRecord(let shown, _, _, _, _) = prompt,
           let episodeID = episode(in: shown) {
            activityRule.offerResolved(episodeID: episodeID)
        }
        if case .offerToStop = prompt {
            quietRule.offerResolved()
        }
        prompt = nil
    }
}
