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

    /// Whether the menu is open, so a prompt does not duplicate what is already on screen.
    public var isMenuOpen = false

    /// A monotonic id per recording, minted here because `ControlState` has no notion of one.
    private var recordingID: UInt64 = 0
    private var wasRecording = false

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
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The meter's publications arrive here, off the capture queue.
    public func ingest(_ summary: AudioActivitySummary) {
        quietRule.ingest(summary, at: Date())
        evaluateQuiet()
    }

    /// A capture restart, device or format change.
    public func captureGenerationChanged(_ generation: UInt64) {
        quietRule.beginGeneration(generation)
    }

    // MARK: - Polling

    private func poll() {
        let settings = service.settings
        quietRule.setQuietInterval(TimeInterval(settings.quietMinutesBeforeStopOffer * 60))
        trackRecordingIdentity()

        let context = MicrophoneActivityRule.Context(
            isEnabled: settings.offersRecordingWhenMicrophoneBusy,
            isBusy: service.state.operation != .idle,
            isMenuOpen: isMenuOpen,
            excludedBundleIDs: Set(settings.reminderExcludedBundleIDs),
            ownBundleIDs: Self.ownBundleIDs,
            ownPIDs: [ProcessInfo.processInfo.processIdentifier])

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

    /// ⚠️ Both flavours, because they coexist on purpose and neither must offer to record the other.
    private static let ownBundleIDs: Set<String> = [
        "dev.personal.acta", "dev.personal.acta-dev",
        Bundle.main.bundleIdentifier,
    ].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }

    private func trackRecordingIdentity() {
        let isRecording: Bool
        switch service.state.operation {
        case .recording, .starting: isRecording = true
        case .idle, .saving: isRecording = false
        }
        if isRecording, !wasRecording {
            recordingID += 1
            quietRule.beginRecording(recordingID, generation: 0)
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
        defer { dismiss() }
        guard case .offerToRecord(let shown, _, _, _, _) = prompt, shown == episodeID else { return }
        guard activityRule.isEpisodeActionable(episodeID) else {
            log.info("start offer \(episodeID, privacy: .public) is no longer actionable")
            return
        }
        guard service.state.canStart else { return }
        service.start()
        present(.startedRecording(title: service.title))
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
        defer { dismiss() }
        guard case .offerToStop(let shown, _, _) = prompt, shown == id else { return }
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
