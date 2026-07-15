import Foundation

/// User recording settings — a **pure, testable** model (Task 7).
///
/// A value type (`Codable`/`Equatable`): the archive path, which final tracks to save
/// (`system`/`mic`/`combined`), the segment length, and whether to delete segments after assembly.
/// Persistence (UserDefaults) and applying the settings to the pipeline live in
/// `SettingsStore`/`RecordingController` (the `Acta` target); here there are only values,
/// normalisation and layout — covered by unit tests (`RecordingSettingsTests`).
///
/// Normalisation (`normalized()`) is the only "smart" part: the segment length is clamped to a
/// sensible range, and clearing every track selection does not lead to "recording into nowhere"
/// (we force `combined`).
public struct RecordingSettings: Codable, Equatable, Sendable {
    /// Path of the archive folder. Empty → the default path (`~/Acta`). A leading `~` is supported.
    public var archivePath: String
    /// Save the final `system.wav` (the other participants' audio).
    public var saveSystemTrack: Bool
    /// Save the final `mic.wav` (the microphone).
    public var saveMicTrack: Bool
    /// Save the final `combined.wav` (a mix of the two tracks).
    public var saveCombinedTrack: Bool
    /// Segment length, s (clamped to `[minSegmentSeconds, maxSegmentSeconds]`).
    public var segmentSeconds: Int
    /// Delete the segment directories after a successful assembly.
    public var deleteSegmentsAfterAssembly: Bool

    public init(archivePath: String = "",
                saveSystemTrack: Bool = true,
                saveMicTrack: Bool = true,
                saveCombinedTrack: Bool = true,
                segmentSeconds: Int = SegmentLayout.defaultSegmentSeconds,
                deleteSegmentsAfterAssembly: Bool = true) {
        self.archivePath = archivePath
        self.saveSystemTrack = saveSystemTrack
        self.saveMicTrack = saveMicTrack
        self.saveCombinedTrack = saveCombinedTrack
        self.segmentSeconds = segmentSeconds
        self.deleteSegmentsAfterAssembly = deleteSegmentsAfterAssembly
    }

    /// Default settings.
    public static let `default` = RecordingSettings()

    /// Lower bound of the segment length, s. Shorter multiplies files and finalisations for nothing.
    public static let minSegmentSeconds = 5
    /// Upper bound of the segment length, s. Longer means a crash loses too much.
    public static let maxSegmentSeconds = 120

    /// Fields missing from the JSON fall back to their defaults (compatibility with an old config).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = RecordingSettings.default
        archivePath = try c.decodeIfPresent(String.self, forKey: .archivePath) ?? def.archivePath
        saveSystemTrack = try c.decodeIfPresent(Bool.self, forKey: .saveSystemTrack) ?? def.saveSystemTrack
        saveMicTrack = try c.decodeIfPresent(Bool.self, forKey: .saveMicTrack) ?? def.saveMicTrack
        saveCombinedTrack = try c.decodeIfPresent(Bool.self, forKey: .saveCombinedTrack) ?? def.saveCombinedTrack
        segmentSeconds = try c.decodeIfPresent(Int.self, forKey: .segmentSeconds) ?? def.segmentSeconds
        deleteSegmentsAfterAssembly = try c.decodeIfPresent(Bool.self, forKey: .deleteSegmentsAfterAssembly)
            ?? def.deleteSegmentsAfterAssembly
    }

    /// Which tracks to build as final files (see `SegmentAssembler`).
    public struct TrackSelection: Equatable, Sendable {
        public var system: Bool
        public var mic: Bool
        public var combined: Bool

        public init(system: Bool, mic: Bool, combined: Bool) {
            self.system = system
            self.mic = mic
            self.combined = combined
        }
    }

    /// The track selection derived from the normalised settings.
    public var trackSelection: TrackSelection {
        let n = normalized()
        return TrackSelection(system: n.saveSystemTrack, mic: n.saveMicTrack, combined: n.saveCombinedTrack)
    }

    /// Clamp the segment length to the allowed range.
    public static func clampSegmentSeconds(_ value: Int) -> Int {
        min(maxSegmentSeconds, max(minSegmentSeconds, value))
    }

    /// A normalised copy: the segment length within range; at least one track is saved (otherwise
    /// the recording would go "into nowhere" — we force `combined`).
    public func normalized() -> RecordingSettings {
        var s = self
        s.segmentSeconds = RecordingSettings.clampSegmentSeconds(segmentSeconds)
        if !saveSystemTrack && !saveMicTrack && !saveCombinedTrack {
            s.saveCombinedTrack = true
        }
        return s
    }

    /// The resolved URL of the archive root, relative to the home folder.
    ///
    /// An empty path → `<home>/<defaultFolderName>`; a leading `~` expands to `homeDirectory`; an
    /// absolute path is taken as is; a relative one is resolved against the home folder.
    /// `homeDirectory` is injected for testability.
    ///
    /// `defaultFolderName` exists so the two build flavors cannot share an archive: the stable app
    /// defaults to `~/Acta`, the dev app to `~/Acta-dev`. An experimental build writing into real
    /// recordings is the one failure this app must never have, so the separation is in the default
    /// rather than left to a setting the user might forget. An explicit `archivePath` still wins —
    /// if you deliberately point both flavors at one folder, that is your call.
    public func resolvedArchiveURL(homeDirectory: URL, defaultFolderName: String = "Acta") -> URL {
        let trimmed = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return homeDirectory.appendingPathComponent(defaultFolderName, isDirectory: true)
        }
        if trimmed == "~" {
            return homeDirectory
        }
        if trimmed.hasPrefix("~/") {
            let rel = String(trimmed.dropFirst(2))
            return homeDirectory.appendingPathComponent(rel, isDirectory: true)
        }
        // A relative path is resolved against the home folder rather than the process working
        // directory: for an `.app` launched from Finder that directory is `/`, so a setting like
        // "Recordings" would silently aim at the disk root (where recordings will not land at all).
        // Home is the only meaningful base here.
        guard trimmed.hasPrefix("/") else {
            return homeDirectory.appendingPathComponent(trimmed, isDirectory: true)
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }
}
