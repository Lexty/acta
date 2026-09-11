import Foundation

/// User recording settings — a **pure, testable** model (Task 7).
///
/// A value type (`Codable`/`Equatable`): the archive path, the segment length, and whether to
/// delete segments after assembly. Persistence (UserDefaults) and applying the settings to the
/// pipeline live in `SettingsStore`/`RecordingController` (the `Acta` target); here there are only
/// values, normalisation and layout — covered by unit tests (`RecordingSettingsTests`).
///
/// Normalisation (`normalized()`) only clamps the segment length to a sensible range.
public struct RecordingSettings: Codable, Equatable, Sendable {
    /// Path of the archive folder. Empty → the default path (`~/Acta`). A leading `~` is supported.
    public var archivePath: String
    /// Segment length, s (clamped to `[minSegmentSeconds, maxSegmentSeconds]`).
    public var segmentSeconds: Int
    /// Delete the segment directories after a successful assembly.
    public var deleteSegmentsAfterAssembly: Bool
    /// The user's microphones, most preferred first, by **UID**.
    ///
    /// ⚠️ **One list, two consumers**, and that is deliberate: a user has one order of preference, and
    /// two lists would let a menu showing one of them lie about the other. What differs is eligibility
    /// (`canBeSystemDefault` filters the system default and not Acta's capture) and lifetime (a
    /// recording pins at start; the system default is held continuously).
    ///
    /// ⚠️ Never the display name: two devices can share one, and a rename must not orphan an entry.
    public var microphonePriority: [String]
    /// Whether Acta holds the **Mac's** default input on that list — feature (B).
    ///
    /// ⚠️ **Opt-in, off by default**, because it changes state every other application on the machine
    /// depends on. It is not a switch over Acta's own recording device: that keeps working either way,
    /// and sharing one flag between the two promises is what the plan forbids.
    public var managesSystemDefaultInput: Bool
    /// Whether a recording follows `microphonePriority` or starts from the system default.
    ///
    /// ⚠️ **Persisted, and this is the field the plan's Task 6 checklist does not name.** It was added
    /// here rather than in Task 7 for one reason worth stating: Task 5 made "use the system default" an
    /// explicit resolve-then-pin *choice*, and a choice that resets at every relaunch is not a setting.
    /// Adding it later would also mean a second protocol bump for a field that could ride this one.
    ///
    /// ⚠️ **`.systemDefault` out of the box, and the alternative shipped broken.** With `.followPriority`
    /// as the default the priority list a fresh install has is empty, so the very first *Start Recording*
    /// resolved `.noneConfigured` and refused — "No microphone selected. Choose one in Acta's menu" before
    /// the user had been given any reason to visit that menu. A recorder that cannot record until it is
    /// configured is not what a default is for.
    ///
    /// ⚠️ This is **not** the silent inheritance `CaptureMicrophoneChoice` exists to end, and the
    /// difference is resolve-then-pin: the default is read at start and the recording is pinned to that
    /// concrete UID, so a headset connecting mid-meeting still does not move it. What changes is only
    /// where an unconfigured user *starts*. The moment they rank anything, `.followPriority` is one click
    /// away and the list is theirs.
    ///
    /// ⚠️ It changes nothing for anyone who already chose: `SettingsStore` encodes the whole struct, so
    /// every config saved even once carries this field explicitly and decodes to what its owner picked.
    /// The default is reached only by a config that predates the field — which is the same population as
    /// a fresh install, and in the same broken state.
    public var captureMicrophoneChoice: CaptureMicrophoneChoice

    // MARK: - Reminders

    /// Whether Acta offers to start a recording when another application opens the microphone.
    ///
    /// ⚠️ **An offer, never an action.** Nothing in this feature starts a recording on its own: the
    /// flag decides whether the question is asked, and only a click answers it. The same is true of
    /// `offersStopWhenQuiet` below. That rule is the reason both reminders are safe to default on.
    public var offersRecordingWhenMicrophoneBusy: Bool

    /// Applications that never raise the recording offer, by bundle identifier.
    ///
    /// ⚠️ **Bundle identifiers, and the scope is honestly an application** — never a website. A call
    /// in a browser tab is the browser's helper process holding the input, so excluding it excludes
    /// the browser. The UI must say that rather than promise a per-site rule the API cannot keep.
    public var reminderExcludedBundleIDs: [String]

    /// Whether Acta offers to stop a recording that has gone quiet.
    public var offersStopWhenQuiet: Bool

    /// How long **both** tracks must be inactive before the stop offer appears, minutes.
    ///
    /// ⚠️ Both tracks: a person listening to a presentation without speaking is not an idle recording,
    /// so remote audio keeps the clock at zero. See `AudioActivityRule`.
    public var quietMinutesBeforeStopOffer: Int

    public init(archivePath: String = "",
                segmentSeconds: Int = SegmentLayout.defaultSegmentSeconds,
                deleteSegmentsAfterAssembly: Bool = true,
                microphonePriority: [String] = [],
                managesSystemDefaultInput: Bool = false,
                captureMicrophoneChoice: CaptureMicrophoneChoice = .systemDefault,
                offersRecordingWhenMicrophoneBusy: Bool = true,
                reminderExcludedBundleIDs: [String] = [],
                offersStopWhenQuiet: Bool = true,
                quietMinutesBeforeStopOffer: Int = defaultQuietMinutes) {
        self.archivePath = archivePath
        self.segmentSeconds = segmentSeconds
        self.deleteSegmentsAfterAssembly = deleteSegmentsAfterAssembly
        self.microphonePriority = microphonePriority
        self.managesSystemDefaultInput = managesSystemDefaultInput
        self.captureMicrophoneChoice = captureMicrophoneChoice
        self.offersRecordingWhenMicrophoneBusy = offersRecordingWhenMicrophoneBusy
        self.reminderExcludedBundleIDs = reminderExcludedBundleIDs
        self.offersStopWhenQuiet = offersStopWhenQuiet
        self.quietMinutesBeforeStopOffer = quietMinutesBeforeStopOffer
    }

    /// Default settings.
    public static let `default` = RecordingSettings()

    /// Lower bound of the segment length, s. Shorter multiplies files and finalisations for nothing.
    public static let minSegmentSeconds = 5
    /// Upper bound of the segment length, s. Longer means a crash loses too much.
    public static let maxSegmentSeconds = 120

    /// Default quiet interval before the stop offer, minutes.
    public static let defaultQuietMinutes = 5
    /// Lower bound of the quiet interval, minutes. Shorter turns an ordinary pause into a prompt.
    public static let minQuietMinutes = 2
    /// Upper bound of the quiet interval, minutes. Longer is indistinguishable from switching it off.
    public static let maxQuietMinutes = 30

    /// How long another application must hold microphone input before the recording offer appears.
    ///
    /// ⚠️ **A tuning constant, deliberately not a setting.** It is the filter that separates a useful
    /// prompt from spam: applications open the input for a fraction of a second to check a permission
    /// or draw a level meter, and without a hold every one of those would raise one. It does **not**
    /// filter a Sound Settings meter, a browser permission preview, dictation or another recorder —
    /// those hold input for a long time, and they are answered by `reminderExcludedBundleIDs`, not by
    /// a larger number here. Exposing it would offer the user a dial that cannot fix their actual
    /// complaint.
    public static let microphoneActivityHold: TimeInterval = 3

    /// Clamp the quiet interval to the allowed range.
    public static func clampQuietMinutes(_ value: Int) -> Int {
        min(maxQuietMinutes, max(minQuietMinutes, value))
    }

    /// Fields missing from the JSON fall back to their defaults (compatibility with an old config).
    /// Keys of removed settings (the track selection) are simply ignored by the keyed container, so
    /// a config written by an older build still decodes with every surviving value intact.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = RecordingSettings.default
        archivePath = try c.decodeIfPresent(String.self, forKey: .archivePath) ?? def.archivePath
        segmentSeconds = try c.decodeIfPresent(Int.self, forKey: .segmentSeconds) ?? def.segmentSeconds
        deleteSegmentsAfterAssembly = try c.decodeIfPresent(Bool.self, forKey: .deleteSegmentsAfterAssembly)
            ?? def.deleteSegmentsAfterAssembly
        // ⚠️ **On-disk migration is a separate concern from the wire version, and they must not be
        // conflated.** A config written before these fields existed decodes with them defaulted — an
        // empty list and feature (B) off, which is exactly the state a fresh install is in. The *wire*
        // fields are required, because there every peer ships in this same binary.
        microphonePriority = try c.decodeIfPresent([String].self, forKey: .microphonePriority)
            ?? def.microphonePriority
        managesSystemDefaultInput = try c.decodeIfPresent(Bool.self, forKey: .managesSystemDefaultInput)
            ?? def.managesSystemDefaultInput
        captureMicrophoneChoice = try c.decodeIfPresent(CaptureMicrophoneChoice.self,
                                                        forKey: .captureMicrophoneChoice)
            ?? def.captureMicrophoneChoice
        // The reminders are the same on-disk migration case: a config written before they existed
        // decodes with them defaulted, which is the state a fresh install is in.
        offersRecordingWhenMicrophoneBusy = try c.decodeIfPresent(
            Bool.self, forKey: .offersRecordingWhenMicrophoneBusy)
            ?? def.offersRecordingWhenMicrophoneBusy
        reminderExcludedBundleIDs = try c.decodeIfPresent([String].self,
                                                          forKey: .reminderExcludedBundleIDs)
            ?? def.reminderExcludedBundleIDs
        offersStopWhenQuiet = try c.decodeIfPresent(Bool.self, forKey: .offersStopWhenQuiet)
            ?? def.offersStopWhenQuiet
        quietMinutesBeforeStopOffer = try c.decodeIfPresent(Int.self,
                                                            forKey: .quietMinutesBeforeStopOffer)
            ?? def.quietMinutesBeforeStopOffer
    }

    /// Clamp the segment length to the allowed range.
    public static func clampSegmentSeconds(_ value: Int) -> Int {
        min(maxSegmentSeconds, max(minSegmentSeconds, value))
    }

    /// One editable settings field, carrying its new value. The UI edits exactly one field per action,
    /// and `merging(_:)` folds that field into a base value.
    public enum Field: Equatable, Sendable {
        case archivePath(String)
        case segmentSeconds(Int)
        case deleteSegmentsAfterAssembly(Bool)
        case microphonePriority([String])
        case managesSystemDefaultInput(Bool)
        case captureMicrophoneChoice(CaptureMicrophoneChoice)
        case offersRecordingWhenMicrophoneBusy(Bool)
        case reminderExcludedBundleIDs([String])
        case offersStopWhenQuiet(Bool)
        case quietMinutesBeforeStopOffer(Int)
    }

    /// A copy of `self` with one field replaced — the anti-clobber primitive for the two-way settings
    /// controls. Each setter merges into the **authoritative** current settings rather than a lagging
    /// UI snapshot, so a recent sibling-field edit not yet reflected in the snapshot is preserved
    /// instead of overwritten. Pure and total, so the clobber logic is covered by a unit test rather
    /// than living only in a review.
    public func merging(_ field: Field) -> RecordingSettings {
        var copy = self
        switch field {
        case .archivePath(let value): copy.archivePath = value
        case .segmentSeconds(let value): copy.segmentSeconds = value
        case .deleteSegmentsAfterAssembly(let value): copy.deleteSegmentsAfterAssembly = value
        case .microphonePriority(let value): copy.microphonePriority = value
        case .managesSystemDefaultInput(let value): copy.managesSystemDefaultInput = value
        case .captureMicrophoneChoice(let value): copy.captureMicrophoneChoice = value
        case .offersRecordingWhenMicrophoneBusy(let value):
            copy.offersRecordingWhenMicrophoneBusy = value
        case .reminderExcludedBundleIDs(let value): copy.reminderExcludedBundleIDs = value
        case .offersStopWhenQuiet(let value): copy.offersStopWhenQuiet = value
        case .quietMinutesBeforeStopOffer(let value): copy.quietMinutesBeforeStopOffer = value
        }
        return copy
    }

    /// A normalised copy: the segment length within range.
    public func normalized() -> RecordingSettings {
        var s = self
        s.segmentSeconds = RecordingSettings.clampSegmentSeconds(segmentSeconds)
        s.quietMinutesBeforeStopOffer =
            RecordingSettings.clampQuietMinutes(quietMinutesBeforeStopOffer)
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
