import Foundation

/// Every message `RecordingController` writes into its single untyped `errorMessage`, and the one
/// place their text lives.
///
/// **Why this type exists.** The controller publishes one untyped `errorMessage`, so `ControlState`
/// has to recover the provenance by a reverse lookup over the strings production is known to write.
/// While the writer held the literals and the reader held hand-typed copies, the two agreed only by
/// coincidence: rewording the controller left the build and the whole suite green while
/// `ControlFailure.category` silently degraded to `.unknown` for a real production message. That is
/// the failure mode `SelfCheckTuning` already exists to prevent — "a threshold written once in the
/// runtime and again in the test asserts only that the test agrees with itself". The writer emits
/// `text`, the reader matches `prefix`, and a reworded message moves both at once.
///
/// It sits in `ActaKit` for the same reason `SelfCheckTuning` does: it is pure text a test must assert
/// exactly against, and both `RecordingController` and `ControlState`'s mapping must reach it.
public enum ControllerMessage: Equatable, Sendable {
    /// `openArchive()` could not reveal the archive root. Not a lifecycle failure — the controller
    /// deliberately leaves `phase` alone on this path.
    case archiveOpenFailed(detail: String)
    /// `performStart` threw something other than a `StartupFailure`.
    case startFailed(detail: String)
    /// `performStop` found no `ffmpeg` to build the final file with.
    case ffmpegMissing
    /// `performStop` ran the assembly and it failed.
    case assemblyFailed
    /// The recording device changed **during** a recording, and the user is told which one and why.
    ///
    /// ⚠️ **Reported, never silent, and this is the case the plan insists on.** Acta pins its
    /// microphone at start and does not preempt a healthy capture — but a watchdog restart re-resolves,
    /// so a priority edit made mid-recording *can* take effect partway through, and a *Use now* is
    /// meant to. Either way the audio changes source in the middle of a meeting, and a user who cannot
    /// tell why has been handed a mystery instead of a feature.
    case microphoneSwitched(device: String, reason: String)
    /// An explicit *Use now* did not come up, and the previous microphone was restored.
    ///
    /// ⚠️ The requested device must **never** have been shown as active in between: the switch is
    /// reported when capture succeeds, not when it is asked for.
    case microphoneSwitchFailed(device: String)

    /// The stable leading text — the **only** part a reverse lookup can match on, since the tails of
    /// `.archiveOpenFailed` and `.startFailed` interpolate an `error.localizedDescription` no lookup
    /// can predict. `Prefix` is a separate namespace because the reader needs the prefix of a case it
    /// cannot construct: it is matching a bare `String` and has no `detail` to supply.
    public enum Prefix {
        public static let archiveOpenFailed = "Could not open the archive: "
        public static let startFailed = "Could not start recording: "
        public static let ffmpegMissing = "Recording stopped, but there is nothing to build the final file with:"
        public static let assemblyFailed = "Recording stopped, but the assembly failed."
        public static let microphoneSwitched = "Now recording from "
        public static let microphoneSwitchFailed = "Could not switch the microphone to "
    }

    /// This message's own prefix.
    public var prefix: String {
        switch self {
        case .archiveOpenFailed: return Prefix.archiveOpenFailed
        case .startFailed: return Prefix.startFailed
        case .ffmpegMissing: return Prefix.ffmpegMissing
        case .assemblyFailed: return Prefix.assemblyFailed
        case .microphoneSwitched: return Prefix.microphoneSwitched
        case .microphoneSwitchFailed: return Prefix.microphoneSwitchFailed
        }
    }

    /// Everything after the prefix.
    private var detail: String {
        switch self {
        case .archiveOpenFailed(let detail), .startFailed(let detail):
            return detail
        case .ffmpegMissing:
            return " ffmpeg was not found (install it: brew install ffmpeg). The segments are saved — "
                + "recovery will assemble them on the next launch."
        case .microphoneSwitched(let device, let reason):
            return "\(device) (\(reason))."
        case .microphoneSwitchFailed(let device):
            return "\(device). The previous microphone is still recording."
        case .assemblyFailed:
            // Not "will assemble on the next launch": `RecoveryManager` bounds its attempts, and these causes are
            // the ones it treats as non-transient — promising a fix we may never deliver is the same over-claim.
            return " The segments are saved — recovery will retry on the next launches; if it still cannot "
                + "assemble them, the raw segments are kept (see info.md)."
        }
    }

    /// The text the controller publishes, verbatim.
    ///
    /// Composed as `prefix + detail` rather than written out per case, which is what makes "every
    /// message begins with its own prefix" — the invariant the reverse lookup rests on — structural
    /// instead of a convention a reword could quietly break.
    public var text: String { prefix + detail }

    /// The closed set, with a placeholder `detail` for the interpolating cases, so a test can enumerate
    /// it. Hand-written because the associated values rule out `CaseIterable`: a new case added above
    /// and forgotten here is the one gap this type cannot close by construction.
    public static let allMessages: [ControllerMessage] = [
        .archiveOpenFailed(detail: "detail."),
        .startFailed(detail: "detail."),
        .ffmpegMissing,
        .assemblyFailed,
        .microphoneSwitched(device: "device", reason: "reason"),
        .microphoneSwitchFailed(device: "device")
    ]
}
