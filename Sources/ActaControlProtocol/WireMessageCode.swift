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
    /// No microphone to record from: nothing configured, or nothing configured is present.
    ///
    /// ⚠️ Additive: these are string constants, not enum cases, so a client that does not know this
    /// code falls through its default rather than failing to decode the response. Adding a **case** to
    /// a response-direction enum would be a version bump; adding a code is not.
    public static let startupMicrophoneUnavailable = "startup_microphone_unavailable"
    /// A restart was admitted for a capture that had already been replaced.
    public static let startupCaptureSuperseded = "startup_capture_superseded"
    /// The recording could not watch its own audio devices, or only some of them.
    public static let microphoneObservationDegraded = "microphone_observation_degraded"
    /// A start or restart was asked for after the recording had already stopped.
    public static let startupRecordingAlreadyStopped = "startup_recording_already_stopped"
    /// A list is configured and none of its devices is present.
    public static let startupPreferredMicrophoneAbsent = "startup_preferred_microphone_absent"
    /// This Mac has nothing that can be recorded from.
    public static let startupNoMicrophoneOnThisMac = "startup_no_microphone_on_this_mac"
    /// The audio devices could not be described well enough to choose one.
    public static let startupMicrophoneUnreadable = "startup_microphone_unreadable"
    /// The recording's microphone changed mid-recording.
    public static let microphoneSwitched = "microphone_switched"
    /// An explicit microphone switch did not come up; the previous device is still recording.
    public static let microphoneSwitchFailed = "microphone_switch_failed"
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
