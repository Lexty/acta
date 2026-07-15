import Testing
import Foundation
import ActaKit

// The counter of closed segments for `session.json` (Task 8.2) and how it relates to recovery.

@Test
func segmentCountGrowsAsSegmentsAreClosed() {
    var progress = SegmentProgress()
    #expect(progress.segmentCount == 0)

    // The tracks close segments in pairs - the first one advances the counter, the second
    // merely catches up.
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
    // The microphone may lag behind (the device dropped out) - we report what is actually on
    // disk rather than the minimum across tracks: the system audio segments are still there.
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
    // Key property: the marker lags behind (in a live run `kill -9` froze it at zero while 12
    // segments sat on disk), so the file system is the source of truth. The plan is built from
    // it and knows nothing about the counter at all.
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
