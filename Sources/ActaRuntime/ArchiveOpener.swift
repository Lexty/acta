import AppKit
import Foundation

/// Showing the archive in Finder. Keeps `NSWorkspace` and the "does the folder even exist yet"
/// question out of `RecordingController`, which otherwise deals only in recording state.
enum ArchiveOpener {
    /// Reveal one recording's folder — selected inside the archive, so the neighbouring recordings
    /// stay in view.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open the archive root itself, creating it first if this is a fresh install.
    ///
    /// The creation is the point: the root only appears with the first recording, and `NSWorkspace`
    /// opens a missing path with no window and no error — without this the button would silently do
    /// nothing until the user had recorded something. It also means `~/Acta/CLAUDE.md` (SPEC §6) is
    /// there the first time the user goes looking for the archive.
    static func openArchive(store: MeetingStore) throws {
        try store.ensureArchiveRoot()
        NSWorkspace.shared.open(store.archiveRoot)
    }
}
