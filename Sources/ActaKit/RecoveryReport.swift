import Foundation

/// What a recovery pass tells the user — **pure logic** of the wording, kept out of
/// `RecordingController` so the one distinction that matters here is covered by a test rather than
/// by launching the app after a crash.
///
/// The distinction: a folder that assembled is *recovered* — there is a track to play. A folder that
/// gave up with nothing assembled is not, and calling it recovered would be false at the exact
/// moment the user most needs the truth: its audio is still only in the segments, and no later
/// launch will retry it (the marker went terminal). The two get their own sentences.
public enum RecoveryReport {
    /// A notification/banner ready to show.
    public struct Message: Equatable, Sendable {
        public var title: String
        public var body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// The message for a pass, or `nil` when it changed nothing and there is nothing to say.
    public static func message(recovered: Int, unassembled: Int) -> Message? {
        guard recovered > 0 || unassembled > 0 else { return nil }

        var parts: [String] = []
        if recovered > 0 {
            parts.append(recovered == 1
                ? "Recovered 1 interrupted recording."
                : "Interrupted recordings recovered: \(recovered).")
        }
        if unassembled > 0 {
            // Says where the audio is, because the folder holds no track to lead the user to it.
            parts.append(unassembled == 1
                ? "1 recording could not be assembled — its raw segments were kept; see its info.md."
                : "Recordings that could not be assembled: \(unassembled) — "
                    + "their raw segments were kept; see their info.md.")
        }
        // The title follows the worse half: a pass that saved nothing must not announce itself as a
        // recovery.
        return Message(title: recovered > 0 ? "Recordings recovered" : "Recordings could not be assembled",
                       body: parts.joined(separator: " "))
    }
}
