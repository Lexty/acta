import AVFoundation
import CoreGraphics

/// Checking and requesting the TCC permissions needed for recording: Screen Recording (system audio
/// via ScreenCaptureKit) and Microphone. Both checks are runtime ones; the UI/self-diagnosis
/// (Task 4/6) decide what to do based on the status. This is a thin wrapper over the system APIs
/// with no side logic.
enum Permissions {
    /// Whether the Screen Recording permission is granted (needed even for audio-only capture
    /// via SCStream).
    ///
    /// `CGPreflightScreenCaptureAccess()` does not show the system dialog — it only reads the status.
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request Screen Recording. The first call shows the system dialog; returns the current status
    /// synchronously (macOS may require restarting the app after the permission is granted).
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Whether the microphone permission is granted right now.
    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Microphone access status (for diagnostics: `notDetermined`/`denied`/`restricted`).
    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Request microphone access (system dialog when `notDetermined`).
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
