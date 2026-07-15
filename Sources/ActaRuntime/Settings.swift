import ActaKit
import Foundation
import os

/// Persistence of the user's recording settings (`RecordingSettings`).
///
/// Stores a single JSON blob in `UserDefaults` under the `settings` key. Works outside an `.app`
/// bundle too (UserDefaults is always available), so it is safe in the unit runner/scripts.
/// Resolving the archive path into a concrete URL and all normalisation is pure `RecordingSettings`
/// logic (covered by tests); here there is only reading/writing and substituting the home directory.
public struct SettingsStore {
    private static let key = "settings"

    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "SettingsStore")
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read the settings (normalised). Missing/corrupt JSON → default values.
    public func load() -> RecordingSettings {
        guard let data = defaults.data(forKey: Self.key) else { return .default }
        do {
            return try JSONDecoder().decode(RecordingSettings.self, from: data).normalized()
        } catch {
            let reason = error.localizedDescription
            log.error("Failed to parse settings, falling back to defaults: \(reason, privacy: .public)")
            return .default
        }
    }

    /// Save the settings (normalised before writing).
    public func save(_ settings: RecordingSettings) {
        let normalized = settings.normalized()
        do {
            let data = try JSONEncoder().encode(normalized)
            defaults.set(data, forKey: Self.key)
        } catch {
            log.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The resolved archive root from the current settings.
    ///
    /// The default folder depends on the build flavor (`~/Acta` vs `~/Acta-dev`) so the experimental
    /// build cannot write into real recordings. An explicit `archivePath` still overrides it.
    public func archiveRoot(for settings: RecordingSettings) -> URL {
        settings.resolvedArchiveURL(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            defaultFolderName: BuildFlavor.current.defaultArchiveFolderName
        )
    }
}
