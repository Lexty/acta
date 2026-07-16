import ActaRuntime
import Foundation
import Testing

/// `~/Acta/CLAUDE.md` is the archive's description for the user's Claude Code (SPEC §6), so it has
/// to describe the layout Acta actually writes. It used to be written only when absent, which meant
/// every existing archive kept the layout of the build that created it — including `combined.wav`,
/// which the pipeline no longer produces.
@Suite
struct ArchiveDocTests {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) rethrows {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-archive-doc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func doc(in directory: URL) -> String {
        (try? String(contentsOf: directory.appendingPathComponent("CLAUDE.md"), encoding: .utf8)) ?? ""
    }

    @Test
    func writesTheArchiveDocIntoAFreshArchive() throws {
        try withTemporaryDirectory { directory in
            let root = directory.appendingPathComponent("Acta")
            try MeetingStore(archiveRoot: root).ensureArchiveRoot()

            let contents = doc(in: root)
            #expect(contents.contains("system.wav"))
            #expect(contents.contains("mic.wav"))
            #expect(!contents.contains("combined.wav"))
        }
    }

    /// The bug this whole change exists for: an archive left by an older build gets the current doc.
    ///
    /// An unfenced file predates the fences, so the current block is *appended* — the stale prose is
    /// left in place rather than truncated, because at this point Acta cannot tell its own old output
    /// from the user's own notes.
    @Test
    func appendsTheCurrentDocToAFileLeftByAnOlderBuild() throws {
        try withTemporaryDirectory { directory in
            let stale = """
                # Acta — meeting recordings archive

                - `system.wav`, `mic.wav`, `combined.wav` — the mix.
                """
            let claudeMD = directory.appendingPathComponent("CLAUDE.md")
            try stale.write(to: claudeMD, atomically: true, encoding: .utf8)

            try MeetingStore(archiveRoot: directory).ensureArchiveRoot()

            #expect(doc(in: directory).contains("A mix is not produced"))
            #expect(doc(in: directory).contains("<!-- acta-archive-doc: begin -->"))
        }
    }

    /// A stale generated block is replaced in place, and only it.
    @Test
    func refreshesOnlyTheFencedBlock() throws {
        try withTemporaryDirectory { directory in
            let existing = """
                # My notes

                Transcribe with `mlx_whisper --model large-v3`.

                <!-- acta-archive-doc: begin -->
                Old and wrong: `combined.wav` is the mix.
                <!-- acta-archive-doc: end -->

                Trailing notes of mine.
                """
            let claudeMD = directory.appendingPathComponent("CLAUDE.md")
            try existing.write(to: claudeMD, atomically: true, encoding: .utf8)

            try MeetingStore(archiveRoot: directory).ensureArchiveRoot()

            let contents = doc(in: directory)
            #expect(!contents.contains("combined.wav"))
            #expect(contents.contains("A mix is not produced"))
            // The user's text, on both sides of the fence, survived.
            #expect(contents.contains("mlx_whisper --model large-v3"))
            #expect(contents.contains("Trailing notes of mine."))
            #expect(contents.contains("# My notes"))
        }
    }

    /// The whole point of the fences: a user's `CLAUDE.md` is never destroyed to fix Acta's block.
    @Test
    func neverDiscardsTextTheUserWrote() throws {
        try withTemporaryDirectory { directory in
            let mine = "# My own notes\n\nRun mlx_whisper over system.wav first.\n"
            let claudeMD = directory.appendingPathComponent("CLAUDE.md")
            try mine.write(to: claudeMD, atomically: true, encoding: .utf8)

            let store = MeetingStore(archiveRoot: directory)
            try store.ensureArchiveRoot()
            try store.ensureArchiveRoot()

            let contents = doc(in: directory)
            #expect(contents.contains("Run mlx_whisper over system.wav first."))
            // Appended once, not once per launch.
            #expect(contents.components(separatedBy: "<!-- acta-archive-doc: begin -->").count == 2)
        }
    }

    /// A begin fence the user left unclosed must not cost them the text under it.
    ///
    /// Appending here would lay down a second begin fence, and the launch after that would bind
    /// `begin` to the first and `end` to the only end fence — deleting everything in between. The
    /// file is malformed, so it is left alone: two launches, byte-for-byte unchanged.
    @Test
    func leavesAFileWithAnUnclosedFenceUntouched() throws {
        try withTemporaryDirectory { directory in
            let mine = """
                # My notes

                <!-- acta-archive-doc: begin -->
                Notes I keep under a fence I never closed.
                """
            let claudeMD = directory.appendingPathComponent("CLAUDE.md")
            try mine.write(to: claudeMD, atomically: true, encoding: .utf8)

            let store = MeetingStore(archiveRoot: directory)
            try store.ensureArchiveRoot()
            try store.ensureArchiveRoot()

            #expect(doc(in: directory) == mine)
        }
    }

    /// An up-to-date block stops the rewrite, or every launch would clobber the file it just wrote.
    @Test
    func leavesTheCurrentDocAlone() throws {
        try withTemporaryDirectory { directory in
            let store = MeetingStore(archiveRoot: directory)
            try store.ensureArchiveRoot()
            let first = doc(in: directory)
            let stamp = try FileManager.default
                .attributesOfItem(atPath: directory.appendingPathComponent("CLAUDE.md").path)[.modificationDate]
                as? Date

            try store.ensureArchiveRoot()

            #expect(doc(in: directory) == first)
            let second = try FileManager.default
                .attributesOfItem(atPath: directory.appendingPathComponent("CLAUDE.md").path)[.modificationDate]
                as? Date
            #expect(stamp == second)
        }
    }
}
