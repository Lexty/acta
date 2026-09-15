import Foundation

/// The words of the offer to stop a recording whose owner let the microphone go.
///
/// ⚠️ **A projection, not view code.** Naming the application is a statement of fact, and `AGENTS.md` puts
/// every user-facing string that states a fact where a test can read it. The view decides layout and colour;
/// what the prompt claims is decided here.
///
/// ⚠️ **It says what was observed, and nothing it implies.** Acta saw an application stop running audio
/// input. That is not evidence that a call ended — a participant can drop the input and stay in the meeting,
/// and an application can release it for reasons nobody has measured — so no sentence here says the call,
/// the meeting or the huddle is over. The countdown is described as what *Acta* will do, which is the one
/// thing Acta does know.
///
/// ⚠️ **`application` must already be a nameable application's display name, or `nil`.** The attribution
/// rule — only a regular application's name may appear in a prompt, and a helper is never mapped to a parent
/// by guessing — is applied where the episode is minted; this type does not re-derive it and must not be
/// handed a bundle identifier to prettify.
public struct OwnerReleaseOfferText: Equatable, Sendable {
    public let headline: String
    public let detail: String

    /// The primary action: stop and save now.
    public static let stopNow = "Stop Now"
    /// The secondary action: keep recording.
    ///
    /// ⚠️ **Not "Cancel".** On a prompt about stopping a recording, "Cancel" reads as cancelling the
    /// recording — and cancel-and-delete is a separate, unbuilt feature. The button says what it keeps.
    public static let keepRecording = "Keep Recording"

    public init(application: String?) {
        if let application {
            headline = "\(application) released the microphone"
            detail = "Acta saw \(application) stop using the microphone input. "
                + "The recording will stop and save unless you keep it."
        } else {
            headline = "The microphone was released"
            detail = "Acta saw the app this recording was started for stop using the microphone input. "
                + "The recording will stop and save unless you keep it."
        }
    }

    /// The line under the countdown, for whole seconds remaining.
    ///
    /// ⚠️ **A rendering of the coordinator's deadline.** The number comes from the countdown; this only says
    /// what happens when it reaches zero.
    public static func countdown(seconds: Int) -> String {
        "Stopping and saving in \(max(0, seconds)) s"
    }
}
