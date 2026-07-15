import ActaKit
import AppKit
import Foundation
import os

/// Menu-bar view model: owns the recording lifecycle and the state for the UI (Task 6).
///
/// It wires together the ready-made building blocks — `RecordingSession` (fault-tolerant recording
/// + self-diagnosis), `MeetingStore` (folders/`info.md`/listing) and `RecoveryManager` (recovery at
/// startup) — into a single observable state for SwiftUI. All the heavy logic is already covered by
/// tests in `ActaKit`; what is left here is orchestration and publishing state on the main thread.
@available(macOS 15.0, *)
@MainActor
final class RecordingController: ObservableObject {
    /// Recording phase for the status indicator.
    enum Phase: Equatable {
        case idle
        case recording
        /// Capture has already stopped and segments are being assembled (`ffmpeg`) — seconds, and
        /// for an hour-long meeting tens of seconds. A separate phase, because showing "Recording"
        /// all that time would be a lie: nothing is being written to the files any more.
        case saving
        case error
    }

    private let log = Logger(subsystem: AppInfo.bundleID, category: "RecordingController")
    private let settingsStore: SettingsStore

    /// Current recording settings (edited in the "Settings" section, saved on change).
    @Published var settings: RecordingSettings

    /// Current phase (idle/recording/error).
    @Published private(set) var phase: Phase = .idle
    /// Human-readable startup self-diagnosis error (empty when there is no error).
    @Published private(set) var errorMessage: String = ""
    /// Recovery banner shown after a failure (empty when there was nothing to recover).
    @Published private(set) var recoveredBanner: String = ""
    /// Elapsed time of the current recording, s.
    @Published private(set) var elapsedSeconds: Int = 0
    /// Meeting title (edited in the field; when empty the auto-suggestion is used).
    @Published var title: String = ""
    /// Auto-suggested title — shown as the field's placeholder. A suggestion only: it must not be
    /// pre-filled into `title`, otherwise a menu opened an hour before the start would record the
    /// time the menu was opened in `info.md` instead of the time the recording began.
    @Published private(set) var suggestedTitle: String = ""
    /// List of saved recordings (newest first).
    @Published private(set) var recordings: [MeetingStore.Recording] = []

    // Active session state.
    private var session: RecordingSession?
    private var currentDirectory: URL?
    private var currentTitle: String = ""
    private var currentSource: String = ""
    private var startedAt: Date?
    private var timerTask: Task<Void, Never>?
    /// Whether an asynchronous start is in flight right now (before the transition to `.recording`).
    /// Guards against a double click: `phase` only becomes `.recording` at the end of `performStart`
    /// (after the ~2 s self-check), so without this flag a second click would bring up a second
    /// session and the first one would leak.
    private var isStarting = false
    /// Whether an asynchronous stop is in flight right now. Symmetric to `isStarting`: `phase` only
    /// becomes `.idle` at the end of `performStop` — after the assembly, which takes seconds.
    /// Without the flag a second click (or a watchdog firing at that moment) would kick off a second
    /// assembly of the same folder: two `ffmpeg` processes would write the same wav and list files,
    /// up to losing the recording.
    private var isStopping = false
    /// The active stop task — `stopAndWait()` awaits it when the app quits.
    private var stopTask: Task<Void, Never>?
    /// Recovery of interrupted recordings runs once per app launch (from `onLaunch`).
    /// `RecoveryManager` treats any folder with status `recording` as interrupted — including the
    /// active recording, whose assembly must not be started on the fly, so the start awaits this
    /// task.
    private var recoveryTask: Task<Void, Never>?
    private var didRunRecovery = false

    /// The shared instance: recovery must start when the app launches (`AppDelegate`), not when the
    /// menu is first opened, and `MenuContent` shows that same state.
    static let shared = RecordingController()

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
    }

    /// Whether a recording is in progress right now.
    var isRecording: Bool { phase == .recording }

    /// Whether the controller is busy recording or saving — for that time editing the settings and
    /// the title is blocked, and the start button is unavailable.
    var isBusy: Bool { phase == .recording || phase == .saving }

    /// The recordings store for the current archive path from the settings. Read on every access so
    /// that a path change in the settings is picked up without a restart (Task 7).
    private var store: MeetingStore {
        MeetingStore(archiveRoot: settingsStore.archiveRoot(for: settings))
    }

    /// The archive root for the current settings (the "Open Archive" button in the UI).
    var archiveRoot: URL { settingsStore.archiveRoot(for: settings) }

    /// Save the settings after they were edited in the UI (normalised before being written to disk).
    func saveSettings() {
        settings = settings.normalized()
        settingsStore.save(settings)
    }

    /// Formatted elapsed time `HH:MM:SS` for the timer in the UI.
    var elapsedString: String { MeetingInfo.formatDuration(seconds: elapsedSeconds) }

    // MARK: - App lifecycle

    /// Call once when the app launches (`AppDelegate`), before and independently of the menu being
    /// opened: SPEC §7 requires interrupted recordings to be recovered exactly at startup. A menu
    /// bar with `menuBarExtraStyle(.window)` builds its content only on a click, so recovery cannot
    /// be hung on `onAppear` — after a crash a recording would sit unassembled until the menu is
    /// opened.
    func onLaunch() {
        Notifier.requestAuthorization()
        guard !didRunRecovery else { return }
        didRunRecovery = true
        recoveryTask = Task { [weak self] in await self?.runRecovery() }
    }

    /// Call when the menu appears: suggest a source and refresh the list. Notification authorization
    /// is requested once in `onLaunch()` — there is no point in poking it on every menu opening.
    func onAppear() {
        if !isBusy {
            suggestedTitle = SourceDetector.detectedSource().map {
                MeetingSource.suggestedTitle(source: $0, date: Date())
            } ?? ""
        }
        refresh()
    }

    /// Scan the archive and recover recordings interrupted by a crash/restart (see `RecoveryManager`).
    ///
    /// The assembly runs `ffmpeg` synchronously over every interrupted folder — tens of seconds for
    /// an hour-long meeting. On the main actor that would freeze the whole menu, so the work moves
    /// off it and only the banner and the notification come back to the main one.
    private func runRecovery() async {
        let root = store.archiveRoot
        let tracks = settings.trackSelection
        let recovered = await Task.detached(priority: .utility) {
            RecoveryManager(archiveRoot: root, tracks: tracks).recoverInterruptedSessions()
        }.value
        guard !recovered.isEmpty else { return }
        recoveredBanner = recovered.count == 1
            ? "Recovered 1 interrupted recording."
            : "Interrupted recordings recovered: \(recovered.count)."
        log.info("Recordings recovered: \(recovered.count)")
        Notifier.notify(title: "Recordings recovered",
                        body: "Automatically recovered after a failure: \(recovered.count).")
        refresh()
    }

    /// Refresh the list of saved recordings.
    func refresh() {
        recordings = store.listRecordings()
    }

    // MARK: - Start/stop

    /// Start recording. The title is taken from the field, or from the auto-suggestion if it is empty.
    func start() {
        guard !isBusy, !isStarting, !isStopping else { return }
        isStarting = true
        recoveredBanner = ""
        errorMessage = ""
        let source = SourceDetector.detectedSource() ?? ""
        let finalTitle = title.isEmpty
            ? MeetingSource.suggestedTitle(source: source.isEmpty ? nil : source, date: Date())
            : title
        Task { await performStart(title: finalTitle, source: source) }
    }

    private func performStart(title: String, source: String) async {
        defer { isStarting = false }
        // Wait for recovery: it treats any folder with `status=recording` as interrupted — and a new
        // recording creates exactly such a folder. Otherwise a start right after the app launched
        // would end up having its own, still-being-written folder assembled.
        await recoveryTask?.value
        var createdDirectory: URL?
        do {
            // Snapshot the settings at start time: a change of the archive path/segment length is
            // picked up by the next recording (Task 7), while the current one runs to the end with
            // its own parameters.
            let currentSettings = settings.normalized()
            let directory = try MeetingStore(archiveRoot: settingsStore.archiveRoot(for: currentSettings))
                .createMeetingDirectory(title: title)
            createdDirectory = directory
            let startedAt = Date()
            let session = RecordingSession(directory: directory, settings: currentSettings)
            // Write a preliminary info.md (recording): if the process is killed, the folder already
            // has metadata; on a clean stop we rewrite it with status done and the duration.
            try? store.writeInfo(
                MeetingInfo(title: title, date: startedAt, source: source,
                            durationSeconds: 0, status: .recording),
                to: directory)

            try await session.start(onStall: { [weak self] failure in
                Task { @MainActor in self?.handleFatalStall(failure) }
            })

            self.session = session
            currentDirectory = directory
            currentTitle = title
            currentSource = source
            self.startedAt = startedAt
            elapsedSeconds = 0
            phase = .recording
            startTimer()
            log.info("Recording started")
        } catch let failure as StartupFailure {
            // Self-diagnosis did not confirm the data stream — we show a clear error rather than a
            // "mute" recording (Acta's key requirement). The recorder is already stopped in start().
            phase = .error
            errorMessage = failure.userMessage
            session = nil
            cleanupFailedStart(createdDirectory)
            log.error("Start rejected by self-diagnosis: \(failure.userMessage, privacy: .public)")
        } catch {
            phase = .error
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            session = nil
            cleanupFailedStart(createdDirectory)
            log.error("Start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove the folder of a failed start — but only if nothing was ever written into it.
    ///
    /// An empty folder must be deleted: with status `recording` it would be stuck forever — recovery
    /// would try to assemble it on every launch (no segments → error), and it would loiter in the
    /// list as "unfinished". But "the start failed" does not mean "there is nothing on disk":
    /// `.diskWriteFailed` is also raised when one track was being written fine and the other broke
    /// (`brokenTrack`) — there is real audio there already, and it is the only copy. Such a folder is
    /// handed over to recovery instead of being deleted.
    private func cleanupFailedStart(_ directory: URL?) {
        guard let directory, !Self.hasSegments(in: directory) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Whether the folder holds at least one segment with salvageable audio (including one that is
    /// unfinished but repairable) — the same rule the assembly will follow.
    ///
    /// Salvageable specifically, not "a file with a matching name": `AVAssetWriter` creates `0000.wav`
    /// before the very first buffer, so a start that broke while writing leaves an empty preamble.
    /// Counting it as audio would mean keeping a folder with `status=recording` that recovery would
    /// vainly assemble on every launch, and that the list would forever show as "unfinished".
    private static func hasSegments(in directory: URL) -> Bool {
        [SegmentLayout.systemDirName, SegmentLayout.micDirName].contains { trackDir in
            !SegmentAssembler.plannedSegments(
                inTrackDir: directory.appendingPathComponent(trackDir)).isEmpty
        }
    }

    /// The watchdog has exhausted its restart attempts during a recording — the buffer stream is gone
    /// for good. We must not keep showing "Recording": stop the session, assemble whatever was
    /// captured, and show an error.
    private func handleFatalStall(_ failure: StartupFailure) {
        guard phase == .recording, !isStopping, let session, let directory = currentDirectory,
              let startedAt else { return }
        isStopping = true
        stopTimer()
        phase = .error
        errorMessage = failure.userMessage
        log.error("Watchdog: data stream is gone — recording stopped, error shown")

        let title = currentTitle
        let source = currentSource
        self.session = nil
        currentDirectory = nil
        self.startedAt = nil
        elapsedSeconds = 0

        Task { [weak self] in
            let result = await session.stop()
            let duration = Self.savedDuration(result, startedAt: startedAt)
            await MainActor.run {
                guard let self else { return }
                self.isStopping = false
                // The assembly may have failed — then the marker stayed `recording` and recovery
                // will retry it. Putting `done` into `info.md` in that case is not allowed: the file
                // is archival metadata, and it would diverge from reality.
                try? self.store.writeInfo(
                    MeetingInfo(title: title, date: startedAt, source: source,
                                durationSeconds: duration,
                                status: result == nil ? .recording : .done),
                    to: directory)
                self.refresh()
            }
        }
    }

    /// Duration for `info.md`, s: taken from the assembled audio, falling back to the clock only if
    /// there is nothing to measure (the assembly failed).
    ///
    /// The clock systematically overstates: `SCStream` does not come up instantly, and for the first
    /// seconds after "Start" is pressed no audio is flowing yet — in a live run 29 s by the clock
    /// against 23.66 s of audio. `info.md` is archival metadata (SPEC §6), and the number in it must
    /// match the file.
    private static func savedDuration(_ result: SegmentAssembler.Result?, startedAt: Date) -> Int {
        if let measured = result?.durationSeconds { return max(0, Int(measured.rounded())) }
        return max(0, Int(Date().timeIntervalSince(startedAt)))
    }

    /// Stop the recording: finalise segments, update `info.md`, notify, refresh the list.
    func stop() {
        beginStop()
    }

    /// Stop the recording and wait until it is actually saved. Needed when the app quits: without
    /// waiting for the assembly the process would die exactly as it does on `kill -9` — the last
    /// segment would stay unfinalised, the marker `recording`, and a clean quit via the button would
    /// lose up to `segmentSeconds` of audio, dumping the rescue of the recording onto recovery at the
    /// next launch. If a stop is already in flight (the "Stop" button was pressed before "Quit") we
    /// simply wait for it.
    func stopAndWait() async {
        beginStop()
        await stopTask?.value
    }

    /// Kick off a stop if there is anything to stop. The `isStopping` flag is set synchronously:
    /// `phase` leaves `.recording` only inside the task, and without the flag a second click could
    /// slip past the check before the task starts.
    private func beginStop() {
        guard phase == .recording, !isStopping, let session, let directory = currentDirectory,
              let startedAt else { return }
        isStopping = true
        stopTask = Task { [weak self] in
            await self?.performStop(session: session, directory: directory, startedAt: startedAt)
        }
    }

    private func performStop(session: RecordingSession, directory: URL, startedAt: Date) async {
        defer { isStopping = false }
        stopTimer()
        // Capture is stopped first thing inside `session.stop()`, and the assembly follows — for that
        // time the state is honestly "Saving…", not "Recording".
        phase = .saving
        let result = await session.stop()
        let duration = Self.savedDuration(result, startedAt: startedAt)
        let stoppedTitle = currentTitle

        self.session = nil
        currentDirectory = nil
        self.startedAt = nil
        elapsedSeconds = 0

        // The assembly failed (no ffmpeg / ffmpeg crashed): there are no final wav files, the marker
        // stayed `recording`, the segments are intact and recovery will pick them up on the next
        // launch. Saying "saved" here is the same as showing a "mute" recording: the state would not
        // match what is actually on disk.
        guard result != nil else {
            try? store.writeInfo(
                MeetingInfo(title: stoppedTitle, date: startedAt, source: currentSource,
                            durationSeconds: duration, status: .recording),
                to: directory)
            phase = .error
            errorMessage = SegmentAssembler.locateFFmpeg() == nil
                ? "Recording stopped, but there is nothing to build the final file with: ffmpeg was "
                    + "not found (install it: brew install ffmpeg). The segments are saved — recovery "
                    + "will assemble them on the next launch."
                : "Recording stopped, but the assembly failed. The segments are saved — recovery "
                    + "will assemble them on the next launch."
            log.error("Recording stopped, but the assembly failed — leaving the segments to recovery")
            refresh()
            return
        }

        try? store.writeInfo(
            MeetingInfo(title: stoppedTitle, date: startedAt, source: currentSource,
                        durationSeconds: duration, status: .done),
            to: directory)
        Notifier.notify(title: "Recording saved", body: stoppedTitle)
        log.info("Recording stopped and saved")

        phase = .idle
        title = ""
        refresh()
    }

    // MARK: - Actions on recordings

    /// Open a recording's folder in Finder.
    func openInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Dismiss the recovery banner (once the user has seen it).
    func dismissRecoveredBanner() {
        recoveredBanner = ""
    }

    // MARK: - Timer

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let startedAt = self.startedAt else { break }
                self.elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
