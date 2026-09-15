import ActaKit
@testable import ActaRuntime
import Foundation
import Testing

/// Listing the archive, and the bound on how much of it is read.
///
/// ⚠️ **The listing's contract is "every folder"; hydration is only about `info.md`.** The wire
/// listing and `openInFinder` both enumerate through here, so a bound that silently truncated the list
/// would turn a menu optimisation into a client-visible change of meaning.
@Suite("Archive hydration")
struct ArchiveHydrationTests {
    private func withArchive(_ folders: [String],
                             body: (MeetingStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-hydration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(archiveRoot: root)
        for name in folders {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let info = MeetingInfo(title: "Title of \(name)", date: Date(), source: "Telegram",
                                   durationSeconds: 61, status: .done)
            try store.writeInfo(info, to: folder)
        }
        try body(store, root)
    }

    private static let sevenFolders = (1...7).map { String(format: "2026-09-%02d_1000__meeting", $0) }

    @Test("the list is complete whether or not anything is hydrated")
    func theListIsAlwaysComplete() throws {
        try withArchive(Self.sevenFolders) { store, _ in
            #expect(store.listRecordings().count == 7)
            #expect(store.listRecordings(hydratingFirst: 5).count == 7)
            // The default reads no metadata at all: a caller that does not draw rows pays nothing.
            #expect(store.listRecordings().allSatisfy { $0.info == nil })
        }
    }

    /// ⚠️ **Sorted before hydrated, and that ordering is the point.** Hydrating first and sorting
    /// afterwards would enrich whichever five folders the file system happened to name first — so the
    /// menu's newest rows, the only ones drawn, would be the ones with no title.
    @Test("exactly the newest N are enriched, and they are the newest")
    func hydrationIsBoundedAndOrdered() throws {
        try withArchive(Self.sevenFolders) { store, _ in
            let listed = store.listRecordings(hydratingFirst: 5)
            #expect(listed.prefix(5).allSatisfy { $0.info?.title != nil })
            #expect(listed.dropFirst(5).allSatisfy { $0.info == nil })
            // Newest first: the folder names sort descending, so 07 leads.
            #expect(listed.first?.info?.title == "Title of 2026-09-07_1000__meeting")
            #expect(listed[4].info?.title == "Title of 2026-09-03_1000__meeting")
        }
    }

    /// ⚠️ **A folder with no readable `info.md` keeps its row.** Losing the row would lose the only
    /// way to reach the recording's files.
    @Test("an unreadable info.md costs the metadata, never the row")
    func aBadInfoFileKeepsItsRow() throws {
        try withArchive(["2026-09-01_1000__ok"]) { store, root in
            let broken = root.appendingPathComponent("2026-09-02_1000__broken", isDirectory: true)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data([0xFF, 0xFE, 0xFF]).write(to:
                broken.appendingPathComponent(MeetingArchive.infoFileName))

            let listed = store.listRecordings(hydratingFirst: 5)
            #expect(listed.count == 2)
            #expect(listed.first?.directory.lastPathComponent == "2026-09-02_1000__broken")
            #expect(listed.first?.info == nil)
            #expect(listed.last?.info?.title == "Title of 2026-09-01_1000__ok")
        }
    }

    /// ⚠️ **Only a prefix of the file is read, and this test states the consequence honestly.** A
    /// transcript appended under the heading — which the archive doc invites — must not be pulled into
    /// memory once per row. The price is that front matter which does not *close* within the limit
    /// reads as absent; that is the safe direction, because a truncated read can never produce a
    /// half-parsed record.
    @Test("a large body is ignored, and front matter beyond the limit is simply not found")
    func onlyAPrefixIsRead() throws {
        try withArchive([]) { store, root in
            let big = root.appendingPathComponent("2026-09-05_1000__big", isDirectory: true)
            try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
            let header = MeetingInfo(title: "Short header", date: Date(), source: "",
                                     durationSeconds: 61, status: .done).rendered()
            let transcript = String(repeating: "a transcript line that goes on and on\n", count: 5_000)
            try (header + transcript).write(to: big.appendingPathComponent(MeetingArchive.infoFileName),
                                            atomically: true, encoding: .utf8)

            let listed = store.listRecordings(hydratingFirst: 5)
            #expect(listed.first?.info?.title == "Short header")

            // And the other direction: a block whose closing fence sits past the limit is not a record.
            let padded = root.appendingPathComponent("2026-09-06_1000__padded", isDirectory: true)
            try FileManager.default.createDirectory(at: padded, withIntermediateDirectories: true)
            let padding = String(repeating: "comment: padding\n", count: 1_000)
            try ("---\ntitle: \"Buried\"\n" + padding + "---\n")
                .write(to: padded.appendingPathComponent(MeetingArchive.infoFileName),
                       atomically: true, encoding: .utf8)

            let second = store.listRecordings(hydratingFirst: 5)
            #expect(second.first?.directory.lastPathComponent == "2026-09-06_1000__padded")
            #expect(second.first?.info == nil)
        }
    }

    /// ⚠️ **A multi-byte character straddling the read boundary must not cost the header.** Found by
    /// Codex: the prefix used to be decoded whole before the fence was looked for, so a single `é` in
    /// the *body* landing across byte 8192 made `String(data:encoding:.utf8)` nil and threw away a
    /// valid header sitting a few hundred bytes earlier. The fence is now found in bytes and only the
    /// header slice is decoded.
    @Test("a character split by the read boundary does not cost the metadata")
    func multibyteAtTheBoundary() throws {
        try withArchive([]) { store, root in
            let folder = root.appendingPathComponent("2026-09-08_1000__split", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let header = MeetingInfo(title: "Valid title", date: Date(), source: "",
                                     durationSeconds: 61, status: .done).rendered()
            // Pad with ASCII so the next character begins at the last byte of the bounded read.
            let padding = String(repeating: "a",
                                 count: MeetingStore.frontMatterReadLimit - 1 - header.utf8.count)
            let text = header + padding + "é"
            try text.write(to: folder.appendingPathComponent(MeetingArchive.infoFileName),
                           atomically: true, encoding: .utf8)

            // The premise, asserted: the prefix genuinely does not decode on its own.
            let prefix = Data(text.utf8).prefix(MeetingStore.frontMatterReadLimit)
            #expect(String(data: prefix, encoding: .utf8) == nil,
                    "the boundary no longer splits a character; this fixture proves nothing")

            #expect(store.listRecordings(hydratingFirst: 5).first?.info?.title == "Valid title")
        }
    }

    /// ⚠️ **Malformed bytes inside the front matter are refused, never repaired.** Lossy decoding
    /// would turn a corrupted title into a plausible-looking one, which is the outcome this reader
    /// exists to prevent.
    @Test("invalid UTF-8 inside the header yields no metadata rather than repaired text")
    func headerBytesAreNotRepaired() throws {
        try withArchive([]) { store, root in
            let folder = root.appendingPathComponent("2026-09-09_1000__bad", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var bytes = Data("---\ntitle: \"Cor".utf8)
            bytes.append(contentsOf: [0xFF, 0xFE])          // not UTF-8 in any encoding of the title
            bytes.append(contentsOf: Data("rupt\"\n---\n".utf8))
            try bytes.write(to: folder.appendingPathComponent(MeetingArchive.infoFileName))

            #expect(store.listRecordings(hydratingFirst: 5).first?.info == nil)
        }
    }

    /// ⚠️ One constant for two jobs: the rows the menu draws and the files the refresh reads. Two
    /// constants would drift, and the drift shows as a row with no title — indistinguishable from a
    /// damaged recording.
    @Test("the controller hydrates exactly as many rows as the menu draws")
    @available(macOS 15.0, *)
    @MainActor
    func oneConstantForBothJobs() {
        #expect(RecordingController.hydratedRecentCount == 5)
    }
}
