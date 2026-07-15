import Testing
import Foundation
import ActaKit

// Recording settings (Task 7) - pure logic: default values, normalization (clamping the segment
// length + guaranteeing at least one track), resolving the archive path, the Codable round-trip
// and compatibility with old/partial JSON.

// MARK: - Default values

@Test
func settingsDefaultsSaveAllTracksAndDefaultSegment() {
    let s = RecordingSettings.default
    #expect(s.saveSystemTrack)
    #expect(s.saveMicTrack)
    #expect(s.saveCombinedTrack)
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
func normalizeForcesCombinedWhenNoTrackSelected() {
    var s = RecordingSettings(saveSystemTrack: false, saveMicTrack: false, saveCombinedTrack: false)
    s = s.normalized()
    // Clearing every option would turn the recording into a write to nowhere - we force combined.
    #expect(s.saveCombinedTrack)
    #expect(!s.saveSystemTrack)
    #expect(!s.saveMicTrack)
}

@Test
func normalizeKeepsPartialTrackSelection() {
    let s = RecordingSettings(saveSystemTrack: true, saveMicTrack: false, saveCombinedTrack: false)
    let n = s.normalized()
    #expect(n.saveSystemTrack)
    #expect(!n.saveMicTrack)
    #expect(!n.saveCombinedTrack)
}

@Test
func normalizeIsIdempotent() {
    let s = RecordingSettings(saveSystemTrack: false, saveMicTrack: false, saveCombinedTrack: false,
                              segmentSeconds: 3).normalized()
    #expect(s.normalized() == s)
}

@Test
func trackSelectionReflectsNormalizedSettings() {
    let sel = RecordingSettings(saveSystemTrack: false, saveMicTrack: false,
                                saveCombinedTrack: false).trackSelection
    #expect(sel == RecordingSettings.TrackSelection(system: false, mic: false, combined: true))
}

// MARK: - Resolving the archive path

@Test
func resolvedArchiveURLDefaultsToActaUnderHome() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let url = RecordingSettings(archivePath: "").resolvedArchiveURL(homeDirectory: home)
    #expect(url.path == "/Users/test/Acta")
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
    let original = RecordingSettings(archivePath: "~/Recordings",
                                     saveSystemTrack: true, saveMicTrack: false,
                                     saveCombinedTrack: true, segmentSeconds: 20,
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
    #expect(decoded.saveSystemTrack == RecordingSettings.default.saveSystemTrack)
    #expect(decoded.saveCombinedTrack == RecordingSettings.default.saveCombinedTrack)
    #expect(decoded.deleteSegmentsAfterAssembly == RecordingSettings.default.deleteSegmentsAfterAssembly)
    #expect(decoded.archivePath == RecordingSettings.default.archivePath)
}
