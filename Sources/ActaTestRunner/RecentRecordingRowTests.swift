import ActaKit
@testable import ActaRuntime
import Foundation
import Testing

/// What the menu's Recent list says about a folder — and the bounded reading that feeds it.
@Suite("Recent rows")
struct RecentRecordingRowTests {
    private static let root = URL(fileURLWithPath: "/tmp/acta-fixture", isDirectory: true)

    private static func folder(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    @available(macOS 15.0, *)
    private static func recording(_ name: String = "2026-09-12_2007__telegram",
                                  status: SessionManifest.Status? = .done,
                                  info: ArchivedMeetingInfo? = nil) -> MeetingStore.Recording {
        MeetingStore.Recording(
            directory: folder(name),
            manifest: status.map { SessionManifest(status: $0, startedAt: Date(), segmentSeconds: 30,
                                                   segmentCount: 3) },
            info: info)
    }

    @available(macOS 15.0, *)
    private static func row(_ recording: MeetingStore.Recording,
                            operation: ControlState.Operation = .idle,
                            active: URL? = nil) -> RecentRecordingRow {
        RecentRecordingRow.make(recording, operation: operation, activeDirectory: active)
    }

    // MARK: - Which folder is the live one

    /// ⚠️ **The defect this guards, with a fixture built from the real file system rather than from my
    /// idea of it.** The controller holds the URL `createMeetingDirectory` returned; the listing holds
    /// the one `contentsOfDirectory` returned, which has resolved the symlink — `/var/folders/…` in the
    /// first, `/private/var/folders/…` in the second. `==` calls them different, so the live recording
    /// would read "Unfinished" in its own menu while it was recording.
    ///
    /// ⚠️ The first version of this test constructed both sides with `appendingPathComponent` and a
    /// trailing slash, asserting a difference that was not there: **deleting the rule left it
    /// passing.** The fixture below makes the folder for real, which is the only way to reproduce the
    /// difference that actually exists.
    @Test("the active folder is matched by resolved path, not by URL equality")
    @available(macOS 15.0, *)
    func symlinkedTempPathDoesNotHideTheLiveRecording() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Exactly what `createMeetingDirectory` hands the controller.
        let created = root.appendingPathComponent("2026-09-12_2007__telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // Exactly what the listing puts in `MeetingStore.Recording`.
        let listedURL = try #require(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]).first)

        // The premise this test rests on — asserted, so it cannot quietly stop being true.
        #expect(created != listedURL, "the two URLs no longer differ; this fixture proves nothing")

        let listed = MeetingStore.Recording(
            directory: listedURL,
            manifest: SessionManifest(status: .recording, startedAt: Date(), segmentSeconds: 30,
                                      segmentCount: 1),
            info: nil)
        #expect(Self.row(listed, operation: .recording(elapsedSeconds: 12), active: created).state
                    == .live)
    }

    /// ⚠️ **Identity and lifecycle are two reads.** The marker says `recording` throughout a save, so
    /// matching the directory alone would label a folder being finalised as "Recording".
    @Test("the live folder follows the operation through starting, recording and saving")
    @available(macOS 15.0, *)
    func theLiveRowFollowsTheOperation() {
        let listed = Self.recording(status: .recording)
        let active = listed.directory
        #expect(Self.row(listed, operation: .starting, active: active).state == .starting)
        #expect(Self.row(listed, operation: .recording(elapsedSeconds: 1), active: active).state == .live)
        #expect(Self.row(listed, operation: .saving, active: active).state == .saving)
    }

    @Test("a recording marker on some other folder is an unfinished recording")
    @available(macOS 15.0, *)
    func anotherFoldersMarkerIsUnfinished() {
        let abandoned = Self.recording("2026-09-01_0900__crashed", status: .recording)
        let active = Self.folder("2026-09-12_2007__telegram")
        #expect(Self.row(abandoned, operation: .recording(elapsedSeconds: 5), active: active).state
                    == .unfinished)
        // And with nothing recording at all, it is still unfinished rather than saved.
        #expect(Self.row(abandoned).state == .unfinished)
    }

    /// ⚠️ Reading the operation alone would stamp every row with whatever the app happens to be doing.
    @Test("an ordinary saved recording is unaffected by what the app is doing")
    @available(macOS 15.0, *)
    func otherRowsAreNotStampedWithTheAppsState() {
        let saved = Self.recording("2026-09-10_1000__done", status: .done)
        #expect(Self.row(saved, operation: .recording(elapsedSeconds: 99),
                         active: Self.folder("2026-09-12_2007__telegram")).state == .saved)
    }

    // MARK: - Status precedence

    @Test("the manifest outranks info.md, which is only a fallback")
    @available(macOS 15.0, *)
    func manifestIsAuthoritative() {
        let disagreeing = Self.recording(status: .done, info: ArchivedMeetingInfo(status: .recording))
        #expect(Self.row(disagreeing).state == .saved)
        let noManifest = Self.recording(status: nil, info: ArchivedMeetingInfo(status: .recovered))
        #expect(Self.row(noManifest).state == .recovered)
    }

    /// ⚠️ Unknown is never ordinary. A folder whose marker cannot be read is a thing we do not know,
    /// and the row says so rather than joining the quiet saved ones.
    @Test("an unreadable marker with nothing to fall back on is unknown, not saved")
    @available(macOS 15.0, *)
    func unknownIsNotSaved() {
        #expect(Self.row(Self.recording(status: nil)).state == .unknown)
    }

    // MARK: - Duration

    /// ⚠️ `info.md` is written at start with `duration: "00:00:00"` and patched on stop. Showing that
    /// placeholder next to real durations would state that a recording lasted no time at all.
    @Test("a duration is shown only for a finished recording that measured one")
    @available(macOS 15.0, *)
    func durationOnlyWhenMeasured() {
        let measured = ArchivedMeetingInfo(durationSeconds: 2_472, status: .done)
        #expect(Self.row(Self.recording(status: .done, info: measured)).duration == "41:12")

        let placeholder = ArchivedMeetingInfo(durationSeconds: 0, status: .recording)
        #expect(Self.row(Self.recording(status: .recording, info: placeholder)).duration == nil)
        // Even on the live row, where the header is already showing a running timer.
        let live = Self.recording(status: .recording, info: placeholder)
        #expect(Self.row(live, operation: .recording(elapsedSeconds: 30),
                         active: live.directory).duration == nil)
        // A folder with a measured duration but an unreadable marker still does not claim to be done.
        #expect(Self.row(Self.recording(status: nil, info: ArchivedMeetingInfo(durationSeconds: 60)))
                    .duration == nil)
    }

    // MARK: - Title

    @Test("the title comes from info.md, and the folder name only when it did not")
    @available(macOS 15.0, *)
    func titleFallsBackToTheFolderName() {
        let titled = Self.recording(info: ArchivedMeetingInfo(title: "Планёрка по acta"))
        #expect(Self.row(titled).title == "Планёрка по acta")
        #expect(Self.row(Self.recording()).title == "2026-09-12_2007__telegram")
    }

    /// ⚠️ Flattened for the row only — the stored title keeps its line breaks.
    @Test("a multi-line title becomes one line in the row")
    @available(macOS 15.0, *)
    func titleIsFlattenedForTheRow() {
        let row = Self.row(Self.recording(info: ArchivedMeetingInfo(title: "First\nSecond")))
        #expect(row.title == "First Second")
    }

    @Test("no date anywhere means no stamp, rather than an invented one")
    @available(macOS 15.0, *)
    func noStampWithoutADate() {
        let noManifest = MeetingStore.Recording(directory: Self.folder("x"), manifest: nil, info: nil)
        #expect(Self.row(noManifest).stamp == nil)
    }
}
