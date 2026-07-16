import AVFoundation
import CoreGraphics

/// The real `PermissionChecking`: the system TCC calls and nothing else. Both checks are runtime
/// ones; the UI/self-diagnosis (Task 4/6) decide what to do based on the status. This is a thin
/// wrapper over the system APIs with no side logic.
///
/// This file is the **only** place in `ActaRuntime` allowed to touch those APIs — that confinement is
/// what makes the fake in the tests answer the same questions the production code asks, instead of
/// bypassing a different code path.
public struct SystemPermissions: PermissionChecking {
    public init() {}

    /// `CGPreflightScreenCaptureAccess()` does not show the system dialog — it only reads the status.
    public var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// The first call shows the system dialog; the status comes back synchronously. Agreeing to it
    /// does not help the recording being started right now — macOS only applies the grant to the next
    /// launch of the process, which is why `AudioRecorder` still rejects the start and tells the user
    /// to restart Acta.
    @discardableResult
    public func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
