import ActaKit
import Foundation
import os

/// Reading/writing `session.json` in the recording directory. A thin wrapper over the FS:
/// serialisation lives in `ActaKit` (`SessionManifest`); here there is only atomic writing to disk
/// and parsing.
struct SessionManifestStore {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "SessionManifestStore")

    /// URL of the marker in the recording directory.
    func url(in directory: URL) -> URL {
        directory.appendingPathComponent(SessionManifest.fileName)
    }

    /// Write the marker atomically (a full file rewrite — the marker is small, there are no races).
    func write(_ manifest: SessionManifest, to directory: URL) throws {
        let data = try manifest.encoded()
        try data.write(to: url(in: directory), options: .atomic)
    }

    /// Read the marker; `nil` if the file is missing or does not parse (the directory is then skipped).
    func read(from directory: URL) -> SessionManifest? {
        let fileURL = url(in: directory)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try SessionManifest.decode(from: data)
        } catch {
            let name = fileURL.lastPathComponent
            let reason = error.localizedDescription
            log.error("Failed to parse \(name, privacy: .public): \(reason, privacy: .public)")
            return nil
        }
    }
}
