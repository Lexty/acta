import Testing
import Foundation
import ActaKit

// `Recovery.discardedSegmentCount` — the pure rule behind "keep the segments". `recoveryPlan` drops
// an unreadable segment without a word, so this count is the only thing that tells a caller whether
// a dropped file was empty or was audio it failed to read. `SegmentAssembler` deletes on that answer.

/// `recoveryPlan` drops an unreadable segment silently, so the count of what it dropped is the only
/// way a caller can tell "nothing was there" from "we could not read what was there" — and the
/// caller deletes segments based on that answer.
@Test
func discardedSegmentCountCountsOnlySegmentsBigEnoughToHoldAudio() {
    let names = ["0000.wav", "0001.wav", "0002.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 262_144, "0002.wav": 8]
    var byName = headers(names, fileSize: 4096)
    // Segment-sized, but its header says nothing we can read — audio we failed to place.
    byName["0001.wav"] = Data(repeating: 0, count: 4096)
    // A file the writer created before the first buffer: genuinely empty, and not a loss.
    byName["0002.wav"] = Data()

    let discarded = Recovery.discardedSegmentCount(fromFileNames: names, sizeByFileName: sizes,
                                                   headerByFileName: byName)

    #expect(discarded == 1)
}

/// The number the deletion hangs on: a clean recording must report zero, or every recording would
/// keep its segments forever.
@Test
func discardedSegmentCountIsZeroWhenEverySegmentIsUsable() {
    let names = ["0000.wav", "0001.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 4096]

    let discarded = Recovery.discardedSegmentCount(fromFileNames: names, sizeByFileName: sizes,
                                                   headerByFileName: headers(names, fileSize: 4096))

    #expect(discarded == 0)
}
