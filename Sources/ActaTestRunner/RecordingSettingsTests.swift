import Testing
import Foundation
import ActaKit

// Настройки записи (Task 7) — чистая логика: значения по умолчанию, нормализация (зажим длины
// сегмента + гарантия хотя бы одной дорожки), разрешение пути архива, Codable round-trip и
// совместимость со старым/частичным JSON.

// MARK: - Значения по умолчанию

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

// MARK: - Зажим длины сегмента

@Test
func clampSegmentSecondsStaysInRange() {
    #expect(RecordingSettings.clampSegmentSeconds(1) == RecordingSettings.minSegmentSeconds)
    #expect(RecordingSettings.clampSegmentSeconds(10_000) == RecordingSettings.maxSegmentSeconds)
    #expect(RecordingSettings.clampSegmentSeconds(30) == 30)
}

// MARK: - Нормализация

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
    // Полностью снятый выбор превратил бы запись «в никуда» — форсим combined.
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

// MARK: - Разрешение пути архива

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
    // Старый/частичный конфиг: отсутствующие поля берут значения по умолчанию.
    let json = Data(#"{"segmentSeconds": 30}"#.utf8)
    let decoded = try JSONDecoder().decode(RecordingSettings.self, from: json)
    #expect(decoded.segmentSeconds == 30)
    #expect(decoded.saveSystemTrack == RecordingSettings.default.saveSystemTrack)
    #expect(decoded.saveCombinedTrack == RecordingSettings.default.saveCombinedTrack)
    #expect(decoded.deleteSegmentsAfterAssembly == RecordingSettings.default.deleteSegmentsAfterAssembly)
    #expect(decoded.archivePath == RecordingSettings.default.archivePath)
}
