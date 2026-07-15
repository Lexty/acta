import ActaKit
import Foundation
import os

/// File storage for recordings: the `~/Acta/` archive root, creating the meeting folder
/// (`YYYY-MM-DD_HHMM__<slug>/`), writing `info.md` and listing the saved recordings.
///
/// A thin wrapper over the FS: the name layout and the `info.md` serialization are pure logic in
/// `ActaKit` (`MeetingArchive`/`MeetingInfo`, covered by unit tests); this file only touches disk.
public struct MeetingStore {
    /// One entry in the archive listing — the folder + the parsed session marker (if any).
    public struct Recording {
        public var directory: URL
        public var manifest: SessionManifest?
    }

    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "MeetingStore")
    private let fileManager = FileManager.default
    private let manifestStore = SessionManifestStore()

    /// The root of the recordings archive (`~/Acta/` by default).
    public let archiveRoot: URL

    /// `archiveRoot` is required on purpose: it used to default to `~/Acta/`, hardcoded, which
    /// bypassed `BuildFlavor.defaultArchiveFolderName` — whose entire job is to keep an experimental
    /// build out of the real archive. No caller ever used the default (every one resolves the path
    /// through `SettingsStore.archiveRoot(for:)`), so the only reachable use of it would have been
    /// the one that violates the invariant. Requiring the parameter makes flavor resolution
    /// structural.
    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    /// Create the folder for a new meeting and return its URL. Guarantees the archive root exists.
    ///
    /// If a folder with that name already exists (the minute and the slug coincided), appends a
    /// `-2`, `-3`, … suffix to the slug so as not to mix two recordings in one folder.
    public func createMeetingDirectory(title: String, date: Date = Date()) throws -> URL {
        try ensureArchiveRoot()
        let slug = MeetingArchive.slug(from: title)
        var candidate = archiveRoot.appendingPathComponent(
            MeetingArchive.folderName(date: date, slug: slug), isDirectory: true)
        var attempt = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = MeetingArchive.folderName(date: date, slug: "\(slug)-\(attempt)")
            candidate = archiveRoot.appendingPathComponent(name, isDirectory: true)
            attempt += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        log.info("Created meeting folder: \(candidate.lastPathComponent, privacy: .public)")
        return candidate
    }

    /// Write `info.md` into the meeting folder (atomically, as a full overwrite).
    public func writeInfo(_ info: MeetingInfo, to directory: URL) throws {
        let url = directory.appendingPathComponent(MeetingArchive.infoFileName)
        try info.rendered().data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// List the archive's recordings: the root's subfolders with their `session.json` parsed,
    /// newest first.
    ///
    /// Sorting by folder name descending = by start time descending (the name begins with
    /// `YYYY-MM-DD_HHMM`).
    public func listRecordings() -> [Recording] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: archiveRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
            .map { Recording(directory: $0, manifest: manifestStore.read(from: $0)) }
            .sorted { $0.directory.lastPathComponent > $1.directory.lastPathComponent }
    }

    /// Guarantee that the archive root exists and drop a description for the user's Claude Code into
    /// it (`~/Acta/CLAUDE.md`, see `SPEC.md` §6) — once, if the file is not there yet.
    ///
    /// Also called before opening the archive in Finder: until the first recording the root does not
    /// exist, and opening a missing path is a silent no-op — the button would look broken on a fresh
    /// install.
    public func ensureArchiveRoot() throws {
        try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let claudeMD = archiveRoot.appendingPathComponent("CLAUDE.md")
        guard !fileManager.fileExists(atPath: claudeMD.path) else { return }
        let contents = """
        # Acta — meeting recordings archive

        Each subfolder is one meeting (`YYYY-MM-DD_HHMM__<slug>/`):
        - `system.wav` — the other participants' audio, `mic.wav` — the microphone.
          A mix is not produced: two tracks keep "me vs. them" apart, and `ffmpeg` merges them on
          demand if you ever need one file.
        - `info.md` — metadata (YAML front-matter: title, date, source, duration, status).
        - `session.json` — the internal recording-state marker.

        Transcription/summarisation are done separately (locally, via `mlx_whisper`).
        """
        try? contents.data(using: .utf8)?.write(to: claudeMD, options: .atomic)
    }
}
