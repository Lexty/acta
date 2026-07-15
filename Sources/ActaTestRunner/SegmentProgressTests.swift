import Testing
import Foundation
import ActaKit

// Счётчик закрытых сегментов для `session.json` (Task 8.2) и его отношения с восстановлением.

@Test
func segmentCountGrowsAsSegmentsAreClosed() {
    var progress = SegmentProgress()
    #expect(progress.segmentCount == 0)

    // Дорожки закрывают сегменты парами — счётчик двигает первая, вторая лишь догоняет.
    for expected in 1...3 {
        let systemMoved = progress.recordFinalizedSegment(track: .system)
        #expect(systemMoved)
        #expect(progress.segmentCount == expected)
        let micMoved = progress.recordFinalizedSegment(track: .mic)
        #expect(micMoved == false)
        #expect(progress.segmentCount == expected)
    }
    #expect(progress.system == 3)
    #expect(progress.mic == 3)
}

@Test
func segmentCountFollowsTheTrackThatIsAhead() {
    // Микрофон может отставать (устройство отвалилось) — показываем то, что реально на диске,
    // а не минимум по дорожкам: сегменты системного звука никуда не делись.
    var progress = SegmentProgress()
    progress.recordFinalizedSegment(track: .system)
    progress.recordFinalizedSegment(track: .system)
    #expect(progress.segmentCount == 2)
    let micMoved = progress.recordFinalizedSegment(track: .mic)
    #expect(micMoved == false)
    #expect(progress.segmentCount == 2)
}

@Test
func recoveryFollowsTheFileSystemWhenTheCounterDisagrees() {
    // Ключевое свойство: маркер отстаёт (в живом прогоне `kill -9` заморозил его на нуле при 12
    // сегментах на диске), поэтому источник правды — файловая система. План строится по ней и о
    // счётчике не знает вовсе.
    let manifest = SessionManifest(status: .recording, startedAt: Date(),
                                   segmentSeconds: 15, segmentCount: 0)
    #expect(Recovery.needsRecovery(manifest))

    let names = (0..<3).map { SegmentLayout.segmentFileName(index: $0) }
    let sizes = Dictionary(uniqueKeysWithValues: names.map { ($0, 4096) })
    let headers = Dictionary(uniqueKeysWithValues: names.map { name -> (String, Data) in
        var bytes: [UInt8] = Array("RIFF".utf8) + le32(4088) + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + le32(16)
        bytes += [1, 0, 2, 0] + le32(48_000) + le32(48_000 * 4) + [4, 0, 16, 0]
        bytes += Array("data".utf8) + le32(4096 - 44)
        return (name, Data(bytes))
    })

    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: headers)
    #expect(plan.map(\.fileName) == names)
    #expect(manifest.segmentCount == 0)
}
