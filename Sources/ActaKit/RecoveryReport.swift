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
///
/// Two more outcomes are not terminal-or-recovered at all, and they get sentences for the same
/// reason: *retrying* is a folder left interrupted for a later launch (usually no `ffmpeg`, which is
/// one `brew install` away from being fixed), and *lost* is a folder closed with nothing to salvage.
/// Saying nothing about either is the silence this type exists to prevent — a pass that lost a
/// meeting and a pass over an archive with nothing to recover must not answer identically.
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
    ///   - retrying: folders left interrupted for a later launch. Not terminal — the marker still
    ///     says `recording` — but told about anyway, because the usual cause is a missing `ffmpeg`
    ///     and the user is the only one who can install it.
    ///   - lost: folders closed because the crash left no salvageable segment. Total loss, and the
    ///     one outcome that must never be reported by saying nothing.
    ///
    /// Every count is a required argument: a caller that omits one is the exact defect this
    /// signature guards against, and a default would let it compile.
    public static func message(recovered: Int, partial: Int, unassembled: Int,
                               retrying: Int, lost: Int) -> Message? {
        guard recovered > 0 || partial > 0 || unassembled > 0 || retrying > 0 || lost > 0 else {
            return nil
        }

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
        if retrying > 0 {
            // Names the one cause the user can act on. The audio is intact and a later launch will
            // retry it, so this is the sentence that turns a silent wait into a one-line fix.
            parts.append(retrying == 1
                ? "1 recording is not assembled yet — it will be retried on the next launch. If "
                    + "ffmpeg is missing, install it: brew install ffmpeg."
                : "Recordings not assembled yet: \(retrying) — they will be retried on the next "
                    + "launch. If ffmpeg is missing, install it: brew install ffmpeg.")
        }
        if lost > 0 {
            // Last, and blunt: there is no audio to point at and no launch that will retry it. The
            // only thing left to be truthful about is that the meeting is gone.
            parts.append(lost == 1
                ? "1 recording was lost — the crash left none of its audio on disk."
                : "Recordings lost: \(lost) — the crash left none of their audio on disk.")
        }
        // The title leads with the best outcome the pass actually reached, and the body carries every
        // outcome regardless. The floor is what matters: a pass that recovered nothing whole must not
        // announce itself as a recovery, and one that saved only pieces must not claim a whole one.
        let title: String
        if recovered > 0 {
            title = "Recordings recovered"
        } else if partial > 0 {
            title = "Recordings partially recovered"
        } else if unassembled > 0 {
            title = "Recordings could not be assembled"
        } else if retrying > 0 {
            // Nothing was closed and nothing was lost: the pass deferred. Saying "could not be
            // assembled" here would read as terminal, which is the opposite of what happened.
            title = "Recovery will retry"
        } else {
            title = "Recordings lost"
        }
        return Message(title: title, body: parts.joined(separator: " "))
    }
}
