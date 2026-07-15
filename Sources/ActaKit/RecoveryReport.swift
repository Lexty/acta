import Foundation

/// What a recovery pass tells the user — **pure logic** of the wording, kept out of
/// `RecordingController` so the one distinction that matters here is covered by a test rather than
/// by launching the app after a crash.
///
/// The distinction: a folder that assembled cleanly is *recovered* — every track is on disk. A
/// folder that gave up is not, and calling it recovered would be false at the exact moment the user
/// most needs the truth: some or all of its audio is still only in the segments, and no later launch
/// will retry it (the marker went terminal). Whether one track survived or none changes what the
/// user should go looking for, not whether they should be told, so the give-up splits in two —
/// *partial* and *unassembled* — and all three get their own sentences.
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
    ///
    /// - Parameters:
    ///   - recovered: folders whose every track assembled.
    ///   - partial: folders closed over a track that assembled while the rest of their audio stayed
    ///     in the segments. Counted apart from `recovered`, because a playable `system.wav` is
    ///     exactly what makes the missing `mic.wav` easy to never notice.
    ///   - unassembled: folders closed with no track at all.
    public static func message(recovered: Int, partial: Int, unassembled: Int) -> Message? {
        guard recovered > 0 || partial > 0 || unassembled > 0 else { return nil }

        var parts: [String] = []
        if recovered > 0 {
            parts.append(recovered == 1
                ? "Recovered 1 interrupted recording."
                : "Interrupted recordings recovered: \(recovered).")
        }
        if partial > 0 {
            // Says "in part" before anything else: the folder has a track in it, so the loss is
            // invisible to a user who opens it and finds audio that plays.
            parts.append(partial == 1
                ? "1 recording was recovered only in part — some of its audio stayed in the raw "
                    + "segments; see its info.md."
                : "Recordings recovered only in part: \(partial) — some of their audio stayed in "
                    + "the raw segments; see their info.md.")
        }
        if unassembled > 0 {
            // Says where the audio is, because the folder holds no track to lead the user to it.
            parts.append(unassembled == 1
                ? "1 recording could not be assembled — its raw segments were kept; see its info.md."
                : "Recordings that could not be assembled: \(unassembled) — "
                    + "their raw segments were kept; see their info.md.")
        }
        // The title leads with the best outcome the pass actually reached, and the body carries every
        // outcome regardless. The floor is what matters: a pass that recovered nothing whole must not
        // announce itself as a recovery, and one that saved only pieces must not claim a whole one.
        let title: String
        if recovered > 0 {
            title = "Recordings recovered"
        } else if partial > 0 {
            title = "Recordings partially recovered"
        } else {
            title = "Recordings could not be assembled"
        }
        return Message(title: title, body: parts.joined(separator: " "))
    }
}
