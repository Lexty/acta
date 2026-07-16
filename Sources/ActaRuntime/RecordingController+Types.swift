import ActaKit
import Foundation

/// `RecordingController`'s nested types. Declared in an extension, and in their own file, so that
/// `RecordingController.swift` stays within the file-length limit; the names are unchanged
/// (`RecordingController.Phase`, `RecordingController.SessionFactory`). Nothing here touches the
/// controller's state — which is why this is the half that moves.
@available(macOS 15.0, *)
extension RecordingController {
    /// Recording phase for the status indicator.
    public enum Phase: Equatable {
        case idle
        case recording
        /// Capture has already stopped and segments are being assembled (`ffmpeg`) — seconds, and
        /// for an hour-long meeting tens of seconds. A separate phase, because showing "Recording"
        /// all that time would be a lie: nothing is being written to the files any more.
        case saving
        case error
    }

    /// How a session is built for a start. Injected so that the controller's own responsibilities —
    /// notably cleaning up the folder a failed start left behind — can be driven without TCC, a
    /// display or an audio device: the fake goes into the *session's* dependencies, and everything
    /// the controller does around it stays the shipped code.
    public typealias SessionFactory = @MainActor (URL, RecordingSettings) -> RecordingSession
}
