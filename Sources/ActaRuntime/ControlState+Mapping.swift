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
    /// The message prefixes production is known to write into the controller's single `errorMessage`.
    ///
    /// ⚠️ These are copies of the controller's own literals — the unavoidable price of a reverse
    /// lookup over an untyped field, and the reason `ControlFailure.category` is documented as
    /// best-effort. Prefixes, not full strings, because the tails interpolate an
    /// `error.localizedDescription`; the startup failures are matched by full equality instead, since
    /// `StartupFailure.userMessage` is a closed set this mapping can enumerate. A literal that drifts
    /// out of sync degrades the category to `.unknown` — it never corrupts `displayMessage`, which is
    /// always the controller's own string passed through.
    enum KnownMessage {
        /// `RecordingController.openArchive()`.
        static let archiveOpenFailed = "Could not open the archive: "
        /// `RecordingController.performStart`, the non-`StartupFailure` branch.
        static let startFailed = "Could not start recording: "
        /// `RecordingController.performStop`, the branch where `ffmpeg` was not found.
        static let ffmpegMissing = "Recording stopped, but there is nothing to build the final file with:"
        /// `RecordingController.performStop`, the branch where the assembly itself failed.
        static let assemblyFailed = "Recording stopped, but the assembly failed."
    }

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
                  recordings: snapshot.recordings)
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
        if errorMessage.hasPrefix(KnownMessage.archiveOpenFailed) {
            return (nil, Notice(category: .archiveOpenFailed, displayMessage: errorMessage))
        }
        return (ControlFailure(category: category(of: errorMessage), displayMessage: errorMessage), nil)
    }

    /// The reverse lookup: which known production string is this?
    private static func category(of errorMessage: String) -> ControlFailure.Category {
        if let failure = StartupFailure.allCases.first(where: { $0.userMessage == errorMessage }) {
            return .startup(failure)
        }
        if errorMessage.hasPrefix(KnownMessage.ffmpegMissing) { return .assemblyFailed(ffmpegMissing: true) }
        if errorMessage.hasPrefix(KnownMessage.assemblyFailed) { return .assemblyFailed(ffmpegMissing: false) }
        if errorMessage.hasPrefix(KnownMessage.startFailed) { return .startFailed }
        return .unknown
    }
}
