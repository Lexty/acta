import AVFoundation

/// The TCC seam: the two permissions a recording needs — Screen Recording (system audio via
/// ScreenCaptureKit) and Microphone — behind a protocol, so the code that *decides* what to do about
/// a missing one can be driven without a system dialog.
///
/// It is deliberately a thin mirror of the system calls and holds no logic of its own: the decisions
/// live in `SelfDiagnosis` (pure) and in the two consumers below it. Nothing here knows about
/// capture, writers or segments.
///
/// **Who consumes it, and why it is those two.** `AudioRecorder` owns `requestPermissionsIfNeeded`
/// and rejects a start without a permission; `SelfCheck` diagnoses a permission that is missing or
/// was revoked mid-flight. `RecordingSession` passes the same instance to both — it is the
/// composition root, not a consumer.
public protocol PermissionChecking: Sendable {
    /// Whether the Screen Recording permission is granted (needed even for audio-only capture).
    /// Reads the status without showing a dialog.
    var hasScreenRecording: Bool { get }

    /// Request Screen Recording. The first call shows the system dialog; returns the current status
    /// synchronously (macOS may require restarting the app after the permission is granted).
    @discardableResult
    func requestScreenRecording() -> Bool

    /// Microphone access status (for diagnostics: `notDetermined`/`denied`/`restricted`).
    var microphoneStatus: AVAuthorizationStatus { get }

    /// Request microphone access (system dialog when `notDetermined`).
    func requestMicrophone() async -> Bool
}

extension PermissionChecking {
    /// Whether the microphone permission is granted right now.
    ///
    /// Derived rather than declared: leaving it to each implementation would let a fake answer
    /// `hasMicrophone == true` while reporting `microphoneStatus == .denied` — an inconsistency the
    /// real permission API cannot produce, and one the callers (which read both) would trip over.
    public var hasMicrophone: Bool { microphoneStatus == .authorized }
}
