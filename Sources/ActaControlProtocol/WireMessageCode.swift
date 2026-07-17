import Foundation

/// The stable machine codes carried by `WireControlState.Message` — the `code` half of a
/// `{code, message}` pair, which a client branches on instead of parsing the prose in `message`.
///
/// They live **here**, in the dependency-free target, for the same reason `WireError.Code` does: no
/// other layer may invent a code. The projection in `ActaRuntime` maps `ControlFailure.Category` /
/// `Notice.Category` / `RecoveryNotice` onto these strings, and a client (the future `actactl`) reads
/// them from this one definition rather than from a copy.
///
/// ⚠️ These are **not** `WireError.Code`. A `WireError` is a rejected *request*; these classify a banner
/// the recorder is already carrying in its state — a request that returned a perfectly good `state`
/// result can still carry a `lifecycle_failure` inside it.
public enum WireMessageCode {
    // MARK: - lifecycle_failure

    /// Self-diagnosis refused the start: no Screen Recording TCC grant.
    public static let startupNoScreenRecordingPermission = "startup_no_screen_recording_permission"
    /// Self-diagnosis refused the start: no Microphone TCC grant.
    public static let startupNoMicrophonePermission = "startup_no_microphone_permission"
    /// Capture did not come up.
    public static let startupStreamNotStarted = "startup_stream_not_started"
    /// Audio arrives but does not reach the disk.
    public static let startupDiskWriteFailed = "startup_disk_write_failed"
    /// Capture came up, but no audio arrives.
    public static let startupNoData = "startup_no_data"
    /// A start that failed with something other than a known startup failure.
    public static let startFailed = "start_failed"
    /// Capture stopped, but the segments did not become the final file.
    public static let assemblyFailed = "assembly_failed"
    /// The same, with the cause named: `ffmpeg` is not installed.
    public static let assemblyFailedFFmpegMissing = "assembly_failed_ffmpeg_missing"
    /// A banner no known writer accounts for. The honest reading of an unclassifiable message — see
    /// `ControlFailure.Category.unknown`; the human `message` is still verbatim and still useful.
    public static let unknownFailure = "unknown_failure"

    // MARK: - notice

    /// Revealing the archive root in Finder failed. Deliberately not a lifecycle failure: it says
    /// nothing about the recording.
    public static let archiveOpenFailed = "archive_open_failed"

    // MARK: - recovery_notice

    /// The recovery banner: a crashed recording was picked up on launch. One code — the banner's text
    /// varies (how many folders, what was lost), its meaning does not.
    public static let recoveryCompleted = "recovery_completed"
}
