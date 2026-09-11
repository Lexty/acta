import Testing
import Foundation
import ActaKit

// Recording settings (Task 7) - pure logic: default values, normalization (clamping the segment
// length), resolving the archive path, the Codable round-trip and compatibility with old/partial
// JSON.

// MARK: - Default values

@Test
func settingsDefaultsUseTheDefaultSegmentLength() {
    let s = RecordingSettings.default
    #expect(s.segmentSeconds == SegmentLayout.defaultSegmentSeconds)
    #expect(s.deleteSegmentsAfterAssembly)
    #expect(s.archivePath.isEmpty)
}

// MARK: - Clamping the segment length

@Test
func clampSegmentSecondsStaysInRange() {
    #expect(RecordingSettings.clampSegmentSeconds(1) == RecordingSettings.minSegmentSeconds)
    #expect(RecordingSettings.clampSegmentSeconds(10_000) == RecordingSettings.maxSegmentSeconds)
    #expect(RecordingSettings.clampSegmentSeconds(30) == 30)
}

@Test
func clampSegmentSecondsPinsTheRangeItself() {
    // The bounds are what a UI stepper actually produces, so they are pinned as literals rather
    // than against the constants - a range that silently moves must fail here.
    #expect(RecordingSettings.minSegmentSeconds == 5)
    #expect(RecordingSettings.maxSegmentSeconds == 120)
    // The bounds pass through untouched; one step outside snaps back to them.
    #expect(RecordingSettings.clampSegmentSeconds(5) == 5)
    #expect(RecordingSettings.clampSegmentSeconds(120) == 120)
    #expect(RecordingSettings.clampSegmentSeconds(4) == 5)
    #expect(RecordingSettings.clampSegmentSeconds(121) == 120)
}

// MARK: - Normalization

@Test
func normalizeClampsSegmentSeconds() {
    var s = RecordingSettings.default
    s.segmentSeconds = 2
    #expect(s.normalized().segmentSeconds == RecordingSettings.minSegmentSeconds)

    s.segmentSeconds = 999
    #expect(s.normalized().segmentSeconds == RecordingSettings.maxSegmentSeconds)
}

@Test
func normalizeIsIdempotent() {
    let s = RecordingSettings(archivePath: "~/Recordings", segmentSeconds: 3).normalized()
    #expect(s.normalized() == s)
}

@Test
func normalizeLeavesEverythingButTheSegmentLengthAlone() {
    let s = RecordingSettings(archivePath: "~/Recordings", segmentSeconds: 3,
                              deleteSegmentsAfterAssembly: false).normalized()
    #expect(s.segmentSeconds == RecordingSettings.minSegmentSeconds)
    #expect(s.archivePath == "~/Recordings")
    #expect(!s.deleteSegmentsAfterAssembly)
}

// MARK: - Merging one field (the settings anti-clobber primitive)

@Test
func mergingReplacesOnlyTheNamedField() {
    let base = RecordingSettings(archivePath: "~/Meetings", segmentSeconds: 30,
                                 deleteSegmentsAfterAssembly: true)

    let path = base.merging(.archivePath("~/Other"))
    #expect(path.archivePath == "~/Other")
    #expect(path.segmentSeconds == 30)
    #expect(path.deleteSegmentsAfterAssembly)

    let segment = base.merging(.segmentSeconds(45))
    #expect(segment.segmentSeconds == 45)
    #expect(segment.archivePath == "~/Meetings")
    #expect(segment.deleteSegmentsAfterAssembly)

    let toggle = base.merging(.deleteSegmentsAfterAssembly(false))
    #expect(!toggle.deleteSegmentsAfterAssembly)
    #expect(toggle.archivePath == "~/Meetings")
    #expect(toggle.segmentSeconds == 30)
}

/// The reason `merging(_:)` exists: a setter must fold its one field into the authoritative current
/// settings, not into a stale snapshot, so a sibling edit not yet delivered is not clobbered. This
/// models the hazard — a recent path edit followed by a segment-length edit against the authoritative
/// value — and asserts both survive.
@Test
func mergingSequentialFieldEditsDoNotClobberEachOther() {
    var authoritative = RecordingSettings.default
    authoritative = authoritative.merging(.archivePath("~/Meetings"))
    authoritative = authoritative.merging(.segmentSeconds(45))
    #expect(authoritative.archivePath == "~/Meetings")
    #expect(authoritative.segmentSeconds == 45)
    #expect(authoritative.deleteSegmentsAfterAssembly)
}

@Test
func mergingLeavesTheBaseUnchanged() {
    let base = RecordingSettings(archivePath: "~/Meetings", segmentSeconds: 30)
    _ = base.merging(.segmentSeconds(45))
    #expect(base.segmentSeconds == 30)
}

// MARK: - Resolving the archive path

@Test
func resolvedArchiveURLDefaultsToActaUnderHome() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let url = RecordingSettings(archivePath: "").resolvedArchiveURL(homeDirectory: home)
    #expect(url.path == "/Users/test/Acta")
}

/// The stable and dev builds must never share an archive: an experimental build writing into real
/// recordings is the one failure this app must not have.
@Test
func resolvedArchiveURLDefaultFolderSeparatesBuildFlavors() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let settings = RecordingSettings(archivePath: "")

    let stable = settings.resolvedArchiveURL(homeDirectory: home, defaultFolderName: "Acta")
    let dev = settings.resolvedArchiveURL(homeDirectory: home, defaultFolderName: "Acta-dev")

    #expect(stable.path == "/Users/test/Acta")
    #expect(dev.path == "/Users/test/Acta-dev")
    #expect(stable.path != dev.path)
}

/// An explicit path is a deliberate choice and still wins over the flavor default — pointing both
/// builds at one folder must remain possible, just never accidental.
@Test
func resolvedArchiveURLExplicitPathOverridesFlavorDefault() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let settings = RecordingSettings(archivePath: "~/Shared")
    #expect(settings.resolvedArchiveURL(homeDirectory: home, defaultFolderName: "Acta-dev").path
        == "/Users/test/Shared")
}

@Test
func resolvedArchiveURLExpandsTilde() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    #expect(RecordingSettings(archivePath: "~").resolvedArchiveURL(homeDirectory: home).path == "/Users/test")
    #expect(RecordingSettings(archivePath: "~/Recordings/Acta")
        .resolvedArchiveURL(homeDirectory: home).path == "/Users/test/Recordings/Acta")
}

@Test
func resolvedArchiveURLUsesAbsolutePathAsIs() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let url = RecordingSettings(archivePath: "/Volumes/Ext/Meetings")
        .resolvedArchiveURL(homeDirectory: home)
    #expect(url.path == "/Volumes/Ext/Meetings")
}

@Test
func resolvedArchiveURLResolvesRelativePathAgainstHome() {
    // A relative path must not depend on the process working directory: for an `.app` launched
    // from Finder it is `/`, so "Recordings" would mean the root of the disk, where recordings
    // cannot be written.
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    #expect(RecordingSettings(archivePath: "Recordings")
        .resolvedArchiveURL(homeDirectory: home).path == "/Users/test/Recordings")
    #expect(RecordingSettings(archivePath: "Meetings/Acta")
        .resolvedArchiveURL(homeDirectory: home).path == "/Users/test/Meetings/Acta")
}

@Test
func resolvedArchiveURLTrimsWhitespace() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let url = RecordingSettings(archivePath: "   ").resolvedArchiveURL(homeDirectory: home)
    #expect(url.path == "/Users/test/Acta")
}

// MARK: - Codable

@Test
func settingsCodableRoundTrip() throws {
    let original = RecordingSettings(archivePath: "~/Recordings", segmentSeconds: 20,
                                     deleteSegmentsAfterAssembly: false)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RecordingSettings.self, from: data)
    #expect(decoded == original)
}

@Test
func settingsDecodesPartialJSONWithDefaults() throws {
    // An old/partial config: the missing fields take their default values.
    let json = Data(#"{"segmentSeconds": 30}"#.utf8)
    let decoded = try JSONDecoder().decode(RecordingSettings.self, from: json)
    #expect(decoded.segmentSeconds == 30)
    #expect(decoded.deleteSegmentsAfterAssembly == RecordingSettings.default.deleteSegmentsAfterAssembly)
    #expect(decoded.archivePath == RecordingSettings.default.archivePath)
}

/// Task 12 removed the track-selection settings, and real `UserDefaults` on an upgraded machine
/// still hold JSON carrying those keys. Swift's keyed container ignores unknown keys, so no
/// migration code is needed — but "no migration needed" is a claim about someone's saved settings,
/// so it is proven here rather than assumed.
///
/// Every surviving value is asserted, not just that decoding succeeded: a decode that quietly reset
/// the settings to defaults would sail past an "it decodes" assertion while silently losing the
/// user's archive path and segment length.
@Test
func settingsDecodeIgnoresRemovedTrackKeysAndKeepsEverySurvivingValue() throws {
    // The exact payload found in UserDefaults on this machine, written by the pre-Task-12 build.
    let json = Data((#"{"saveSystemTrack":true,"saveMicTrack":true,"saveCombinedTrack":false,"#
        + #""segmentSeconds":15,"archivePath":"","deleteSegmentsAfterAssembly":true}"#).utf8)
    let decoded = try JSONDecoder().decode(RecordingSettings.self, from: json)
    #expect(decoded.segmentSeconds == 15)
    #expect(decoded.archivePath == "")
    #expect(decoded.deleteSegmentsAfterAssembly)
}

/// The same, with non-default surviving values: the payload above happens to carry an empty
/// `archivePath` and `deleteSegmentsAfterAssembly: true`, which are also the defaults — so on its
/// own it cannot tell "the values were preserved" from "the values were reset". This one can.
@Test
func settingsDecodeWithRemovedKeysPreservesNonDefaultValues() throws {
    let json = Data((#"{"saveSystemTrack":false,"saveMicTrack":true,"saveCombinedTrack":true,"#
        + #""segmentSeconds":45,"archivePath":"~/Meetings","deleteSegmentsAfterAssembly":false}"#).utf8)
    let decoded = try JSONDecoder().decode(RecordingSettings.self, from: json)
    #expect(decoded.segmentSeconds == 45)
    #expect(decoded.archivePath == "~/Meetings")
    #expect(!decoded.deleteSegmentsAfterAssembly)
}

// MARK: - Reminders

/// A config written before the reminders existed opens with them defaulted — the same state a fresh
/// install is in, and the same migration rule the microphone fields follow.
@Test
func settingsDecodedFromAConfigWithoutRemindersGetsTheDefaults() throws {
    let json = Data(#"{"segmentSeconds":45,"archivePath":"~/Meetings"}"#.utf8)
    let decoded = try JSONDecoder().decode(RecordingSettings.self, from: json)
    #expect(decoded.offersRecordingWhenMicrophoneBusy)
    #expect(decoded.offersStopWhenQuiet)
    #expect(decoded.reminderExcludedBundleIDs.isEmpty)
    #expect(decoded.quietMinutesBeforeStopOffer == RecordingSettings.defaultQuietMinutes)
    // ...without disturbing what the old config did carry.
    #expect(decoded.segmentSeconds == 45)
    #expect(decoded.archivePath == "~/Meetings")
}

/// ⚠️ Stated in both directions on purpose. "Defaults when absent" alone would also pass if the
/// decoder ignored the keys entirely, which is the defect that would silently discard a user's choice
/// on every launch.
@Test
func settingsDecodedWithRemindersPresentKeepsThem() throws {
    let json = Data((#"{"segmentSeconds":45,"offersRecordingWhenMicrophoneBusy":false,"#
        + #""offersStopWhenQuiet":false,"reminderExcludedBundleIDs":["com.google.Chrome"],"#
        + #""quietMinutesBeforeStopOffer":12}"#).utf8)
    let decoded = try JSONDecoder().decode(RecordingSettings.self, from: json)
    #expect(!decoded.offersRecordingWhenMicrophoneBusy)
    #expect(!decoded.offersStopWhenQuiet)
    #expect(decoded.reminderExcludedBundleIDs == ["com.google.Chrome"])
    #expect(decoded.quietMinutesBeforeStopOffer == 12)
}

@Test
func normalizingClampsTheQuietIntervalAtBothEnds() {
    #expect(RecordingSettings(quietMinutesBeforeStopOffer: 0).normalized()
        .quietMinutesBeforeStopOffer == RecordingSettings.minQuietMinutes)
    #expect(RecordingSettings(quietMinutesBeforeStopOffer: 9_000).normalized()
        .quietMinutesBeforeStopOffer == RecordingSettings.maxQuietMinutes)
    // A value already inside the range is left alone rather than snapped to a default.
    #expect(RecordingSettings(quietMinutesBeforeStopOffer: 12).normalized()
        .quietMinutesBeforeStopOffer == 12)
}

/// The anti-clobber primitive has to cover the new fields too: each one merges alone and leaves its
/// siblings untouched.
@Test
func mergingOneReminderFieldLeavesTheOthersAlone() {
    let base = RecordingSettings(offersRecordingWhenMicrophoneBusy: true,
                                 reminderExcludedBundleIDs: ["com.apple.Safari"],
                                 offersStopWhenQuiet: true,
                                 quietMinutesBeforeStopOffer: 8)

    let a = base.merging(.offersRecordingWhenMicrophoneBusy(false))
    #expect(!a.offersRecordingWhenMicrophoneBusy)
    #expect(a.offersStopWhenQuiet)
    #expect(a.reminderExcludedBundleIDs == ["com.apple.Safari"])
    #expect(a.quietMinutesBeforeStopOffer == 8)

    let b = base.merging(.reminderExcludedBundleIDs(["com.google.Chrome", "com.apple.Safari"]))
    #expect(b.reminderExcludedBundleIDs == ["com.google.Chrome", "com.apple.Safari"])
    #expect(b.offersRecordingWhenMicrophoneBusy)
    #expect(b.offersStopWhenQuiet)

    let c = base.merging(.offersStopWhenQuiet(false))
    #expect(!c.offersStopWhenQuiet)
    #expect(c.offersRecordingWhenMicrophoneBusy)

    let d = base.merging(.quietMinutesBeforeStopOffer(20))
    #expect(d.quietMinutesBeforeStopOffer == 20)
    #expect(d.offersStopWhenQuiet)
}
