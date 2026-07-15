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
    @Test
    func refreshesADocLeftByAnOlderBuild() throws {
        try withTemporaryDirectory { directory in
            let stale = """
                # Acta — meeting recordings archive

                - `system.wav`, `mic.wav`, `combined.wav` — the mix.
                """
            let claudeMD = directory.appendingPathComponent("CLAUDE.md")
            try stale.write(to: claudeMD, atomically: true, encoding: .utf8)

            try MeetingStore(archiveRoot: directory).ensureArchiveRoot()

            #expect(!doc(in: directory).contains("combined.wav"))
            #expect(doc(in: directory).contains("A mix is not produced"))
        }
    }

    /// The marker has to stop the rewrite, or every launch would clobber the file it just wrote.
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
