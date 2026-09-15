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
    ///
    /// `Equatable`/`Sendable` because the listing travels inside `ControlState`, which is compared for
    /// distinctness and crosses an `AsyncStream`. Both are plain value semantics over a `URL` and a
    /// `SessionManifest`; nothing here is derived from the file system at compare time.
    public struct Recording: Equatable, Sendable {
        public var directory: URL
        public var manifest: SessionManifest?

        /// What `info.md` said, when there was one to read.
        ///
        /// ⚠️ **The folder name is not the title.** It is a slug: lower-cased, punctuation stripped,
        /// truncated, and prefixed with a date the title usually repeats. The real title is written to
        /// `info.md` at start and has been all along — the listing simply never read it back, which is
        /// why the menu showed `2026-01-15_2007__t…am-2026-01-15-20-07`. Optional because a folder
        /// without a readable `info.md` is still a real recording.
        public var info: ArchivedMeetingInfo?

        public init(directory: URL, manifest: SessionManifest? = nil,
                    info: ArchivedMeetingInfo? = nil) {
            self.directory = directory
            self.manifest = manifest
            self.info = info
        }
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
    /// ⚠️ **`hydratingFirst` bounds the `info.md` reads, and nothing else.** Every folder is returned
    /// either way — the wire listing and `openInFinder` depend on that and must not silently start
    /// seeing five recordings. What the parameter buys is that a menu showing five rows does not read
    /// a file per folder in an archive of a thousand. The sort happens *before* hydration, so the
    /// hydrated entries are the newest ones rather than whichever the file system happened to name
    /// first. Zero — the default — reads no `info.md` at all.
    public func listRecordings(hydratingFirst hydrated: Int = 0) -> [Recording] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: archiveRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let sorted = dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        return sorted.enumerated().map { index, directory in
            Recording(directory: directory,
                      manifest: manifestStore.read(from: directory),
                      info: index < hydrated ? readInfo(from: directory) : nil)
        }
    }

    /// Read `info.md` back out of a meeting folder, or nil if there is nothing usable there.
    ///
    /// ⚠️ **Best-effort by contract.** A missing file, an unreadable one, non-UTF-8 bytes and a file
    /// with no front matter all answer nil — the same answer, because the caller does the same thing
    /// with each: shows what it does know, and the folder's row survives regardless.
    ///
    /// ⚠️ **A prefix, never the whole file.** `info.md` is not small by contract: `appendingNote`
    /// writes into it, and the archive doc this store itself generates invites the user's Claude Code
    /// to keep transcription and notes there. The front matter is the first few lines by construction,
    /// so reading beyond `frontMatterReadLimit` buys nothing and risks pulling a transcript into
    /// memory once per row. A truncated read cannot corrupt the answer: the parser requires a closing
    /// `---`, and a prefix that does not contain one parses as nothing rather than as a half-record.
    static let frontMatterReadLimit = 8 * 1024

    func readInfo(from directory: URL) -> ArchivedMeetingInfo? {
        let url = directory.appendingPathComponent(MeetingArchive.infoFileName)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.frontMatterReadLimit),
              let info = MeetingInfo.parse(prefix: data), !info.isEmpty else { return nil }
        return info
    }

    /// Fences around the part of `~/Acta/CLAUDE.md` that Acta generates.
    ///
    /// Everything between them is Acta's own account of a layout Acta decides, so it is regenerated:
    /// a stale copy misinforms the one consumer it exists for. Everything **outside** them is the
    /// user's and is never touched — this is a `CLAUDE.md` in the user's home, the obvious place to
    /// keep one's own `mlx_whisper` notes, and rewriting the whole file to fix one stale sentence
    /// would trade unbounded user text for it.
    static let archiveDocBeginFence = "<!-- acta-archive-doc: begin -->"
    static let archiveDocEndFence = "<!-- acta-archive-doc: end -->"

    /// The description of the archive Acta writes for the user's Claude Code (`SPEC.md` §6).
    static let archiveDocBody = """
        # Acta — meeting recordings archive

        Each subfolder is one meeting (`YYYY-MM-DD_HHMM__<slug>/`):
        - `system.wav` — the other participants' audio, `mic.wav` — the microphone.
          A mix is not produced: two tracks keep "me vs. them" apart, and `ffmpeg` merges them on
          demand if you ever need one file.
        - `info.md` — metadata (YAML front-matter: title, date, source, duration, status).
        - `session.json` — the internal recording-state marker.

        Transcription/summarisation are done separately (locally, via `mlx_whisper`).
        """

    /// The generated block as it appears on disk, fences included.
    static let archiveDoc = """
        \(archiveDocBeginFence)
        \(archiveDocBody)
        \(archiveDocEndFence)
        """

    /// The exact body the pre-fence build wrote, byte for byte.
    ///
    /// Kept as a literal because it is the one unfenced text Acta can positively identify as its own:
    /// every archive from that build holds this and nothing else. Without it the upgrade appends, and
    /// the file ends up asserting both "`combined.wav` — the mix" and "A mix is not produced" — an
    /// archive doc that contradicts itself is worse than the stale one it replaced, and `combined.wav`
    /// has not existed since the pipeline dropped it.
    ///
    /// An exact match is the whole safeguard: the moment a user edits a line, this stops matching and
    /// the append path takes over, which is the behaviour we want for text that is theirs.
    static let legacyArchiveDocBody = """
        # Acta — meeting recordings archive

        Each subfolder is one meeting (`YYYY-MM-DD_HHMM__<slug>/`):
        - `system.wav` — the other participants' audio, `mic.wav` — the microphone,
          `combined.wav` — the mix.
        - `info.md` — metadata (YAML front-matter: title, date, source, duration, status).
        - `session.json` — the internal recording-state marker.

        Transcription/summarisation are done separately (locally, via `mlx_whisper`).
        """

    /// Splice the current generated block into `existing`, leaving every line outside the fences as
    /// the user left it. Returns `nil` when the file already carries exactly this block — there is
    /// nothing to write, and rewriting would only churn the mtime.
    ///
    /// A file with no fences (written by a build that predated them, or by the user) is *appended*
    /// to, never truncated: the text already there is not ours to judge — unless it is verbatim
    /// `legacyArchiveDocBody`, which is Acta's own output and is replaced outright.
    ///
    /// A begin fence with no end fence is malformed — only a user's own hand puts it there — and the
    /// file is left exactly as it is. Appending to it would lay down a *second* begin fence, and the
    /// next launch would then bind `begin` to the first fence and `end` to the only end fence and
    /// replace everything in between: the user's text under their unbalanced fence, deleted from
    /// their home directory without a word. Writing nothing costs a stale block; the alternative
    /// costs their notes.
    static func archiveDocRefreshed(from existing: String?) -> String? {
        guard let existing, !existing.isEmpty else { return archiveDoc + "\n" }
        guard let begin = existing.range(of: archiveDocBeginFence) else {
            // Whitespace-insensitive only at the edges: the write went through `atomic` and a trailing
            // newline is the one byte an editor adds without the user meaning anything by it.
            if existing.trimmingCharacters(in: .whitespacesAndNewlines) == legacyArchiveDocBody {
                return archiveDoc + "\n"
            }
            return existing.hasSuffix("\n")
                ? existing + "\n" + archiveDoc + "\n"
                : existing + "\n\n" + archiveDoc + "\n"
        }
        guard let end = existing.range(of: archiveDocEndFence,
                                       range: begin.upperBound..<existing.endIndex) else { return nil }
        guard String(existing[begin.lowerBound..<end.upperBound]) != archiveDoc else { return nil }
        return existing.replacingCharacters(in: begin.lowerBound..<end.upperBound, with: archiveDoc)
    }

    /// Guarantee that the archive root exists and drop a description for the user's Claude Code into
    /// it (`~/Acta/CLAUDE.md`, see `SPEC.md` §6), refreshing the generated block when the copy on
    /// disk predates the current layout.
    ///
    /// Also called before opening the archive in Finder: until the first recording the root does not
    /// exist, and opening a missing path is a silent no-op — the button would look broken on a fresh
    /// install.
    public func ensureArchiveRoot() throws {
        try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let claudeMD = archiveRoot.appendingPathComponent("CLAUDE.md")
        let existing = try? String(contentsOf: claudeMD, encoding: .utf8)
        guard let refreshed = Self.archiveDocRefreshed(from: existing) else { return }
        try? refreshed.data(using: .utf8)?.write(to: claudeMD, options: .atomic)
    }
}
