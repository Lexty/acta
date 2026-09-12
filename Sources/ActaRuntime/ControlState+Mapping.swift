import ActaKit
import Foundation

/// The translation from `RecordingController`'s published bag to a typed `ControlState` — a **pure
/// function** over `ControllerSnapshot`, with no I/O, no clock and no controller in reach.
///
/// That purity is the point rather than a nicety: several of the states this mapping must get right
/// cannot be induced through the real pipeline (an archive-open failure, an assembly failure, a retry
/// after a failed start), so a test that could only reach them through a live recording could not
/// cover them at all. As a function over literals, every combination is reachable.
@available(macOS 15.0, *)
extension ControlState {
    /// Map a snapshot of the controller to the typed state.
    public init(from snapshot: ControllerSnapshot) {
        let classified = ControlState.classify(errorMessage: snapshot.errorMessage)
        self.init(operation: ControlState.operation(from: snapshot),
                  lifecycleFailure: classified.failure,
                  notice: classified.notice,
                  recoveryNotice: snapshot.recoveredBanner.isEmpty
                      ? nil
                      : RecoveryNotice(message: snapshot.recoveredBanner),
                  title: snapshot.title,
                  suggestedTitle: snapshot.suggestedTitle,
                  settings: snapshot.settings,
                  recordings: snapshot.recordings,
                  activeRecordingDirectory: snapshot.activeRecordingDirectory)
    }

    /// The operation, with explicit precedence — the order below **is** the contract.
    ///
    /// 1. `isStarting` wins over `phase`, whatever `phase` says. A retry after a failed start leaves
    ///    `phase == .error` (the controller clears `errorMessage`, not the phase), and reading the
    ///    phase first would call that live start `.idle`.
    /// 2. Then a stop in flight (`isSaving`, which already folds `phase == .saving` and the private
    ///    `isStopping`). This is what makes a **fatal stall** read `.saving` — its `phase` is `.error`
    ///    while the assembly runs — with the failure carried alongside rather than instead.
    /// 3. Then the settled phase, where `.error` maps to **`.idle`**: once the assembly settles, the
    ///    stall leaves `.saving` and the recorder genuinely is idle. Leaving `.saving` is not clearing
    ///    the failure — `errorMessage` still stands, so `lifecycleFailure` still stands with it.
    private static func operation(from snapshot: ControllerSnapshot) -> Operation {
        if snapshot.isStarting { return .starting }
        if snapshot.isSaving { return .saving }
        switch snapshot.phase {
        case .recording: return .recording(elapsedSeconds: snapshot.elapsedSeconds)
        case .saving: return .saving
        case .idle, .error: return .idle
        }
    }

    /// Split the controller's one `errorMessage` into the two views the state exposes.
    ///
    /// The rule is **snapshot-local**: a pure function has no previous state, so the discrimination can
    /// only come from the message itself. The archive prefix is checked **first and without consulting
    /// `phase`**, because `openArchive()` can overwrite a failure that was set while `phase == .error`
    /// — classifying by phase would then report a lifecycle failure whose message is about Finder.
    /// Everything else non-empty is a lifecycle failure.
    ///
    /// ⚠️ This is **last-write and lossy**, by construction and on purpose: that same overwrite leaves
    /// the archive string alone in the snapshot, so the earlier failure is not reported. It is not
    /// recoverable here — the controller lost it too.
    private static func classify(errorMessage: String) -> (failure: ControlFailure?, notice: Notice?) {
        guard !errorMessage.isEmpty else { return (nil, nil) }
        if errorMessage.hasPrefix(ControllerMessage.Prefix.archiveOpenFailed) {
            return (nil, Notice(category: .archiveOpenFailed, displayMessage: errorMessage))
        }
        if errorMessage.hasPrefix(ControllerMessage.Prefix.microphoneSwitched) {
            return (nil, Notice(category: .microphoneSwitched, displayMessage: errorMessage))
        }
        if errorMessage.hasPrefix(ControllerMessage.Prefix.microphoneObservationDegraded) {
            return (nil, Notice(category: .microphoneObservationDegraded, displayMessage: errorMessage))
        }
        if errorMessage.hasPrefix(ControllerMessage.Prefix.microphoneSwitchFailed) {
            return (nil, Notice(category: .microphoneSwitchFailed, displayMessage: errorMessage))
        }
        return (ControlFailure(category: category(of: errorMessage), displayMessage: errorMessage), nil)
    }

    /// The reverse lookup: which known production string is this?
    ///
    /// Both closed sets it matches against are the writers' own — `StartupFailure.userMessage` is what
    /// the controller publishes verbatim (matched by equality, since `CaseIterable` enumerates it), and
    /// `ControllerMessage.Prefix` is the leading text of every message the controller composes (matched
    /// by prefix, since two of the four interpolate an `error.localizedDescription` tail). Neither is a
    /// copy, so neither can drift out from under this lookup.
    private static func category(of errorMessage: String) -> ControlFailure.Category {
        if let failure = StartupFailure.allCases.first(where: { $0.userMessage == errorMessage }) {
            return .startup(failure)
        }
        if errorMessage.hasPrefix(ControllerMessage.Prefix.ffmpegMissing) {
            return .assemblyFailed(ffmpegMissing: true)
        }
        if errorMessage.hasPrefix(ControllerMessage.Prefix.assemblyFailed) {
            return .assemblyFailed(ffmpegMissing: false)
        }
        if errorMessage.hasPrefix(ControllerMessage.Prefix.startFailed) { return .startFailed }
        return .unknown
    }
}
