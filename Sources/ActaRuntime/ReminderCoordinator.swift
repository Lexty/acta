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

/// Joins the two reminder rules to the recorder.
///
/// ⚠️ **Nothing here acts on its own.** Every path that starts or stops a recording begins with a click.
/// A timer may *withdraw* a prompt; no timer may ever answer one.
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
    @Published public private(set) var prompt: ReminderPrompt?

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
        rebaselineIfObservationLapsed()
        let settings = service.settings
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

        // ⚠️ **The HAL is not read at all when the start reminder is off** — a property walk per second
        // for a feature nobody asked for is not worth keeping episode state warm; a re-enable
        // rebaselines instead. ⚠️ But this must **not** return: the two preferences are independent, and
        // an early exit here left the quiet evaluation depending entirely on summaries arriving. With a
        // stalled meter there are no summaries, so a standing stop offer would never notice it had gone
        // stale.
        if settings.offersRecordingWhenMicrophoneBusy {
            switch activityRule.observe(reader.readSnapshot(), at: now(), context: context) {
            case .none:
                break
            case .offer(let episode):
                // ⚠️ **Instrumentation, and it decides a design question rather than decorating one.**
                // Whether a per-application mode can ever be remembered depends on there being a
                // durable key: a bundle identifier survives a helper restart, a PID does not. Nothing
                // recorded this, so every claim about it so far has been inference from an absent
                // display name — which is nil for three different reasons, only one of them a helper.
                // One huddle and one call now settle it.
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

        evaluateQuiet()
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
        case .startingRecording: return 12
        case .startedRecording: return 3
        case .checkingStart: return 12
        case .startNoLongerAvailable: return 6
        }
    }

    private func present(_ newPrompt: ReminderPrompt) {
        // ⚠️ One at a time, never a stack. A second prompt replaces the first rather than queueing
        // behind it: two offers about two different moments, both stale by the time they are read, is
        // worse than one.
        //
        // ⚠️ **The deadline is set once per prompt and never extended by a redraw.** Re-publishing the
        // same offer must not buy it another twenty seconds; that is how an offer outlives the evidence
        // behind it.
        presentation &+= 1
        promptDeadline = now().addingTimeInterval(Self.lifetime(of: newPrompt))
        log.debug("prompt \(self.presentation, privacy: .public) presented, answerable for \(Self.lifetime(of: newPrompt), privacy: .public)s")
        prompt = newPrompt
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
        guard case .offerToRecord(let shown, _, _, let intendedTitle, _) = prompt,
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
            self.service.start(title: intendedTitle)
            // Honest until the recorder says otherwise; `trackRecordingIdentity` promotes or withdraws it.
            self.awaitingConfirmation = intendedTitle
            self.awaitingConfirmationAfter = self.recordingID
            // ⚠️ "Starting…" only **after** the command is issued, never while the barrier is awaited.
            // The panel's oldest rule is that it does not claim a recording is under way before one is.
            self.present(.startingRecording(title: intendedTitle))
        }
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

    /// "Remind me in thirty minutes", bound to this recording.
    public func snooze(recordingID id: UInt64, minutes: Int = 30) {
        guard id == recordingID else { return dismiss() }
        quietRule.armSnooze(until: now().addingTimeInterval(TimeInterval(minutes * 60)),
                            recordingID: id)
        dismiss()
    }

    /// The prompt expired, or the user clicked away. **Never an action.**
    ///
    /// ⚠️ **Identity-scoped.** An expiry enqueued for prompt A must not take prompt B off the screen;
    /// the caller says which prompt it is dismissing.
    public func dismiss(_ expected: ReminderPrompt) {
        guard prompt == expected else { return }
        dismiss()
    }

    public func dismiss() {
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
