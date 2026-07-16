import Foundation

/// What a recovery pass changed in the archive — the pass's whole answer, and the value both of its
/// readings are derived from (`RecordingController.RecoveryOutcome` for the harness's exit code,
/// `RecoveryReport` for the user's sentence).
///
/// In its own file because `RecoveryManager.swift` is at the file-length limit, and this is the part
/// of it that is a value rather than the machinery: nothing here touches the disk.
extension RecoveryManager {
    /// What a recovery pass changed in the archive.
    ///
    /// Five lists rather than one, because the outcomes need different things said about them: a
    /// folder that assembled whole holds audio the user can play, whereas one that gave up holds a
    /// meeting that lives, in part or entirely, only as raw segments. Reporting either give-up as
    /// "recovered" would be false, and not reporting it at all would leave the audio undiscoverable
    /// outside `log show`.
    public struct Outcome: Sendable, Equatable {
        /// Folders whose every track assembled — nothing was left behind in the segments.
        public var recovered: [URL] = []
        /// Folders closed over a track that assembled while audio the plan vouched for stayed in the
        /// segments. Apart from `recovered` because this is the loss that hides: the folder holds a
        /// wav that plays, so nothing about it looks wrong until the missing track is wanted.
        public var partial: [URL] = []
        /// Folders closed with their audio still only in the segments: no track assembled, so there
        /// is no wav to play and the segments are the sole copy of the meeting.
        public var unassembled: [URL] = []
        /// Folders the pass found interrupted and left interrupted, to try again on a later launch —
        /// an attempt spent on audio the assembly could not place, or a cause outside the folder
        /// (no `ffmpeg`). Apart from the three above because they are terminal and this is not: the
        /// marker still says `recording`.
        ///
        /// It exists because without it such a folder is invisible to the caller — the pass returns
        /// the same empty outcome it returns for an archive with nothing to recover, and those are
        /// opposite answers. That ambiguity is exactly what `RecordingController.awaitRecovery()`
        /// has to resolve.
        public var retrying: [URL] = []
        /// Folders the pass closed because there was nothing in them to salvage: the crash left the
        /// marker but not one valid segment, so the meeting is gone — not in a track, not in the
        /// segments.
        ///
        /// Its own list for exactly the reason `retrying` has one, and the case is not weaker.
        /// Closing a folder is not leaving the archive as it was found, and a total loss reported in
        /// no list at all comes back as the empty outcome of an archive with nothing to recover —
        /// "every meeting is fine" and "a meeting was lost" answering identically.
        public var lost: [URL] = []
        /// The pass could not read the archive root, so it never reached a folder to file anywhere.
        /// Not a list, because there is nothing to list: the failure is the whole answer.
        ///
        /// Its own signal for the reason `retrying` and `lost` have their own lists, and the case is
        /// the strongest of the three. An archive on an unmounted volume, or one the app has lost the
        /// right to open, answers `contentsOfDirectory` with an error — and reporting *that* as the
        /// empty outcome is the "nothing to recover" of a clean archive: the pass vouching for every
        /// meeting at the one moment it could not check a single one. A root that does not exist yet
        /// is deliberately **not** this — no recording has ever been made, so doing nothing over it is
        /// the correct answer and not a failure.
        public var unscannable: Bool = false

        /// A struct's memberwise initialiser is internal even when the struct is public, so this is
        /// spelled out: the verdict `RecoveryOutcome(_:)` derives from these lists is a decision, and
        /// a test in another module has to be able to hand it one.
        public init(recovered: [URL] = [], partial: [URL] = [], unassembled: [URL] = [],
                    retrying: [URL] = [], lost: [URL] = [], unscannable: Bool = false) {
            self.recovered = recovered
            self.partial = partial
            self.unassembled = unassembled
            self.retrying = retrying
            self.lost = lost
            self.unscannable = unscannable
        }

        /// Whether the pass has nothing at all to say — it looked, and the archive was as it found it.
        ///
        /// `unscannable` counts here even though such a pass changed nothing: it did not *look*, and
        /// the silence of "nothing to recover" is the one thing it must not be confused with.
        public var isEmpty: Bool {
            recovered.isEmpty && partial.isEmpty && unassembled.isEmpty && retrying.isEmpty
                && lost.isEmpty && !unscannable
        }
    }
}
