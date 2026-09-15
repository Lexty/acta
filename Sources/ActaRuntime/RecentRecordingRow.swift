import ActaKit
import Foundation

/// One row of the menu's "Recent" list, already decided.
///
/// ⚠️ **Why this is a type and not four `if`s in the view.** Every question the row answers is one the
/// project has got wrong before: whether a folder carrying a `recording` marker is the live recording
/// or an abandoned one, whether the duration in `info.md` is a measurement or the `00:00:00` written
/// at start, and whether an unreadable manifest is the same thing as a finished recording. A view is
/// the one layer nothing tests, so the deciding happens here and the view only draws the answer.
@available(macOS 15.0, *)
public struct RecentRecordingRow: Equatable, Sendable {
    /// What the row says about the recording — **six answers, never folded into fewer**.
    public enum State: Equatable, Sendable {
        /// This session's folder, with a start still in flight.
        case starting
        /// This session's folder, capture running.
        case live
        /// This session's folder, being finalised.
        case saving
        /// Assembled and closed.
        case saved
        /// Interrupted, and recovery rebuilt it from the surviving segments.
        ///
        /// ⚠️ Not a promise that everything was recovered: the front matter cannot express partial
        /// loss, so the word means "recovery ran on it", and the folder is the only place the truth
        /// about its contents lives.
        case recovered
        /// A `recording` marker on a folder this session does not own — an interrupted recording that
        /// recovery has not claimed yet.
        case unfinished
        /// No readable `session.json`. **Not** the same as saved, and deliberately not silent.
        case unknown
    }

    public var directory: URL
    /// The display title: the real one when `info.md` had it, the folder name when it did not.
    public var title: String
    public var state: State
    /// `Today 20:07` — nil when nothing in the folder said when it began.
    public var stamp: String?
    /// `41:12` — **nil unless the recording is finished and the duration was measured.**
    public var duration: String?

    public init(directory: URL, title: String, state: State,
                stamp: String? = nil, duration: String? = nil) {
        self.directory = directory
        self.title = title
        self.state = state
        self.stamp = stamp
        self.duration = duration
    }

    /// Decide one row.
    ///
    /// ⚠️ **Identity and lifecycle are two reads, and both are needed.** `activeDirectory` says which
    /// folder is this session's; `operation` says what is happening to it. Matching the directory
    /// alone would label a folder "Recording" while the app was finalising it; reading the operation
    /// alone would label *every* row with whatever the app happens to be doing.
    ///
    /// ⚠️ **The manifest outranks `info.md` on lifecycle.** They are two separate writes and can
    /// disagree — `session.json` is the recording marker and is updated by the machinery that knows,
    /// while the front matter is patched afterwards. `info.status` is consulted only when there is no
    /// readable manifest at all.
    public static func make(_ recording: MeetingStore.Recording,
                            operation: ControlState.Operation,
                            activeDirectory: URL?,
                            now: Date = Date(),
                            calendar: Calendar = .current,
                            locale: Locale = .current) -> RecentRecordingRow {
        let info = recording.info
        let title = info?.title.map(MeetingInfo.singleLine) ?? recording.directory.lastPathComponent
        let started = info?.date ?? recording.manifest?.startedAt
        let stamp = started.map {
            MeetingInfo.relativeStamp(for: $0, now: now, calendar: calendar, locale: locale)
        }
        let status = recording.manifest?.status ?? info?.status
        let state = self.state(of: status, isActive: isActive(recording, activeDirectory),
                               operation: operation)
        return RecentRecordingRow(directory: recording.directory, title: title, state: state,
                                  stamp: stamp, duration: duration(info, state: state))
    }

    /// ⚠️ **Compared as standardised paths, and the reason is measured rather than assumed.** The two
    /// URLs for one folder are built by different means and do not compare equal: the controller holds
    /// what `createMeetingDirectory` returned, built by `appendingPathComponent`, while the listing
    /// holds what `contentsOfDirectory` returned — and that one has **resolved the symlink**. On this
    /// machine the same folder is `file:///var/folders/…` in the first and `file:///private/var/…` in
    /// the second. `==` on `URL` calls those different, which would have made the live recording read
    /// as "Unfinished" in its own menu while it was recording.
    private static func isActive(_ recording: MeetingStore.Recording, _ active: URL?) -> Bool {
        guard let active else { return false }
        return active.standardizedFileURL.path == recording.directory.standardizedFileURL.path
    }

    private static func state(of status: SessionManifest.Status?, isActive: Bool,
                              operation: ControlState.Operation) -> State {
        // The live folder's own row follows the operation, not the marker: the marker says `recording`
        // throughout a save, and the folder is not abandoned merely because capture has stopped.
        if isActive {
            switch operation {
            case .starting: return .starting
            case .recording: return .live
            case .saving: return .saving
            // Idle with a folder still claimed is a transient the controller clears; the marker is
            // then the better witness, and it falls through to the ordinary reading below.
            case .idle: break
            }
        }
        switch status {
        case .done: return .saved
        case .recovered: return .recovered
        case .recording: return .unfinished
        case nil: return .unknown
        }
    }

    /// ⚠️ **A duration only when one was measured.** `info.md` is written at start with
    /// `duration: "00:00:00"` and patched when the recording stops, so a live or abandoned recording
    /// has a *placeholder* in that field. Showing it next to the real durations of the rows above
    /// would state that a recording lasted no time at all.
    private static func duration(_ info: ArchivedMeetingInfo?, state: State) -> String? {
        guard state == .saved || state == .recovered,
              let seconds = info?.durationSeconds, seconds > 0 else { return nil }
        return MeetingInfo.formatCompactDuration(seconds: seconds)
    }
}
