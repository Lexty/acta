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
    /// A recording just started from a prompt — shown briefly, then gone.
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

    /// Whether the menu is open, so a prompt does not duplicate what is already on screen.
    public var isMenuOpen = false

    /// A monotonic id per recording, minted here because `ControlState` has no notion of one.
    private var recordingID: UInt64 = 0
    private var wasRecording = false
    /// The capture generation the quiet rule is currently calibrated for.
    ///
    /// ⚠️ **Adopted from the summaries rather than guessed.** The recorder mints the generation, several
    /// layers below; a coordinator that assumed one would silently drop every measurement when the two
    /// disagreed — a stop reminder that never fires and never says why.
    private var currentGeneration: UInt64 = 0

    /// How often the process list is read.
    ///
    /// ⚠️ **One second, chosen over HAL listeners on per-process properties.** The qualification hold is
    /// three seconds, so one-second resolution is ample — expect three to four seconds from a real onset
    /// to a prompt, not exactly three. A listener would be cheaper and I cannot verify that it fires for
    /// `kAudioProcessPropertyIsRunningInput` without a live meeting to test against, and an unverified
    /// event source is a feature that silently never works.
    public static let pollInterval: Duration = .seconds(1)

    public init(service: ControlAPI, reader: any AudioProcessReading) {
        self.service = service
        self.reader = reader
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

        // ⚠️ **The HAL is not read at all when the reminder is off.** Keeping the rule's episode state
        // warm is not worth a property walk per second for a feature nobody asked for; a re-enable
        // rebaselines instead.
        guard settings.offersRecordingWhenMicrophoneBusy else { return }

        switch activityRule.observe(reader.readSnapshot(), at: Date(), context: context) {
        case .none:
            break
        case .offer(let episode):
            present(.offerToRecord(episodeID: episode.id,
                                   application: episode.displayName,
                                   bundleID: episode.bundleID,
                                   suggestedTitle: service.state.suggestedTitle,
                                   microphone: service.microphoneStatus.captureSummary))
        case .withdraw(let episodeID):
            withdrawStartOffer(episodeID)
        }

        evaluateQuiet()
    }

    /// A preference switched off must take the prompt it governs off the screen, and must never act on
    /// the recording while doing so.
    private func applyPreferenceChanges(_ settings: RecordingSettings) {
        if !settings.offersRecordingWhenMicrophoneBusy {
            if case .offerToRecord(let episodeID, _, _, _, _) = prompt {
                activityRule.offerResolved(episodeID: episodeID)
                prompt = nil
            }
            // Re-enabling starts from a fresh baseline rather than from episodes nobody was watching.
            activityRule = MicrophoneActivityRule()
        }
        if !settings.offersStopWhenQuiet, case .offerToStop = prompt {
            quietRule.offerResolved()
            prompt = nil
        }
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
        if isRecording, !wasRecording {
            recordingID += 1
            quietRule.beginRecording(recordingID, generation: currentGeneration)
        }
        if !isRecording, wasRecording {
            quietRule.invalidate()
            if case .offerToStop = prompt { prompt = nil }
        }
        wasRecording = isRecording
    }

    private func evaluateQuiet() {
        guard wasRecording else { return }
        let settings = service.settings
        let context = AudioActivityRule.Context(isEnabled: settings.offersStopWhenQuiet,
                                                recordingID: recordingID)
        switch quietRule.evaluate(at: Date(), context: context) {
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

    private func present(_ newPrompt: ReminderPrompt) {
        // ⚠️ One at a time, never a stack. A second prompt replaces the first rather than queueing
        // behind it: two offers about two different moments, both stale by the time they are read, is
        // worse than one.
        prompt = newPrompt
    }

    private func withdrawStartOffer(_ episodeID: UInt64) {
        if case .offerToRecord(let shown, _, _, _, _) = prompt, shown == episodeID {
            prompt = nil
        }
        activityRule.offerResolved(episodeID: episodeID)
    }

    // MARK: - Answers

    /// Start recording, from a prompt.
    ///
    /// ⚠️ **The identity is re-checked here, in the same turn as the command.** The episode may have
    /// ended while the prompt sat on screen — the application released the input at t+1 and the click
    /// arrives at t+15 — and the anti-duplicate grace that keeps the episode *alive* for thirty seconds
    /// says nothing about whether a call is still in progress. `isEpisodeActionable` is the question
    /// that does.
    public func acceptStart(episodeID: UInt64) {
        guard case .offerToRecord(let shown, _, _, let intendedTitle, _) = prompt,
              shown == episodeID else { return }
        // The prompt comes down now; the episode is resolved explicitly rather than by a later
        // `dismiss()` that would be looking at a different prompt by then.
        prompt = nil
        activityRule.offerResolved(episodeID: episodeID)

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
            guard !self.isClosing else { return }
            guard self.service.settings.offersRecordingWhenMicrophoneBusy else { return }
            guard self.activityRule.isEpisodeActionable(episodeID) else {
                self.log.info("start offer \(episodeID, privacy: .public) is no longer actionable")
                return
            }
            guard self.service.state.canStart else { return }
            // ⚠️ The title the prompt promised, not whatever the field holds now: "Will save as X" has
            // to be true, and `service.title` can have been edited in the menu since.
            self.service.start(title: intendedTitle)
            self.present(.startedRecording(title: intendedTitle))
        }
    }

    public func declineStart(episodeID: UInt64) {
        activityRule.offerResolved(episodeID: episodeID)
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
        prompt = nil
        quietRule.offerResolved()
        guard !isClosing else { return }
        guard service.settings.offersStopWhenQuiet else { return }
        guard id == recordingID else {
            log.info("stop offer \(id, privacy: .public) belongs to a finished recording")
            return
        }
        guard case .recording = service.state.operation else { return }
        service.stop()
    }

    public func keepRecording() {
        quietRule.offerResolved()
        dismiss()
    }

    /// "Remind me in thirty minutes", bound to this recording.
    public func snooze(recordingID id: UInt64, minutes: Int = 30) {
        guard id == recordingID else { return dismiss() }
        quietRule.armSnooze(until: Date().addingTimeInterval(TimeInterval(minutes * 60)),
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
        if case .offerToRecord(let episodeID, _, _, _, _) = prompt {
            activityRule.offerResolved(episodeID: episodeID)
        }
        if case .offerToStop = prompt {
            quietRule.offerResolved()
        }
        prompt = nil
    }
}
