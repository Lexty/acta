import Testing
import Foundation
import ActaKit

// Логика восстановления и маркера сессии — чистая, покрыта отдельно от файловой системы/ffmpeg.

@Test
func recoveryPlanOrdersValidSegments() {
    let names = ["0002.wav", "0000.wav", "0001.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 4096, "0002.wav": 4096]
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes)
    #expect(plan == ["0000.wav", "0001.wav", "0002.wav"])
}

@Test
func recoveryPlanDropsCorruptLastSegment() {
    // Классический сценарий kill -9: последний сегмент не финализирован → битый/пустой.
    let names = ["0000.wav", "0001.wav", "0002.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 4096, "0002.wav": 0]
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes)
    #expect(plan == ["0000.wav", "0001.wav"])
}

@Test
func recoveryPlanFiltersJunkAndMissingSizes() {
    let names = ["0000.wav", ".DS_Store", "combined.wav", "0001.wav"]
    // 0001.wav отсутствует в размерах → трактуем как 0 → отбрасываем.
    let sizes = ["0000.wav": 4096]
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes)
    #expect(plan == ["0000.wav"])
}

@Test
func recoveryPlanEmptyWhenNothingValid() {
    let plan = Recovery.recoveryPlan(fromFileNames: ["0000.wav"], sizeByFileName: ["0000.wav": 10])
    #expect(plan.isEmpty)
}

@Test
func isValidSegmentThreshold() {
    #expect(Recovery.isValidSegment(bytes: Recovery.minValidSegmentBytes))
    #expect(Recovery.isValidSegment(bytes: Recovery.minValidSegmentBytes - 1) == false)
    #expect(Recovery.isValidSegment(bytes: 0) == false)
}

@Test
func needsRecoveryOnlyForRecordingStatus() {
    let base = SessionManifest(status: .recording, startedAt: Date(timeIntervalSince1970: 0),
                               segmentSeconds: 15, segmentCount: 3)
    #expect(Recovery.needsRecovery(base))

    var done = base; done.status = .done
    #expect(Recovery.needsRecovery(done) == false)

    var recovered = base; recovered.status = .recovered
    #expect(Recovery.needsRecovery(recovered) == false)
}

@Test
func sessionManifestRoundTrips() throws {
    let original = SessionManifest(status: .recording,
                                   startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   segmentSeconds: 15, segmentCount: 7)
    let data = try original.encoded()
    let decoded = try SessionManifest.decode(from: data)
    #expect(decoded == original)
}

@Test
func sessionManifestUsesSnakeCaseAndIsoDate() throws {
    let manifest = SessionManifest(status: .done,
                                   startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   segmentSeconds: 10, segmentCount: 2)
    let json = String(data: try manifest.encoded(), encoding: .utf8) ?? ""
    #expect(json.contains("\"started_at\""))
    #expect(json.contains("\"segment_seconds\""))
    #expect(json.contains("\"segment_count\""))
    #expect(json.contains("\"status\" : \"done\""))
    // ISO-8601 для 1_700_000_000 = 2023-11-14T22:13:20Z.
    #expect(json.contains("2023-11-14T22:13:20Z"))
}

@Test
func sessionManifestDecodesFromHandWrittenJSON() throws {
    let raw = """
    {
      "status": "recovered",
      "started_at": "2023-11-14T22:13:20Z",
      "segment_seconds": 15,
      "segment_count": 4
    }
    """
    let manifest = try SessionManifest.decode(from: Data(raw.utf8))
    #expect(manifest.status == .recovered)
    #expect(manifest.segmentSeconds == 15)
    #expect(manifest.segmentCount == 4)
    #expect(manifest.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
}
