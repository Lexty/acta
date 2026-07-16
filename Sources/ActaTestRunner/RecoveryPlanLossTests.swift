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

/// A preamble torn off mid-write is not audio, and must not be counted as any.
///
/// The intact preamble is spared because it *parses*; this one never got that far — a power loss
/// landing inside the writer's first 4 KiB leaves a RIFF header with no `data` chunk in it at all.
/// It cleared the 64-byte floor and failed to parse, which was precisely the "unreadable header over
/// a file big enough to hold audio" verdict — over a file with zero frames in it. The cost was the
/// same as the intact-preamble bug it sat next to: three futile recovery passes, a false "part of
/// the audio could not be assembled", and segments retained forever.
///
/// The missing `data` chunk is what settles it, not the byte count: a segment whose `fmt ` is
/// unplayable is *also* unparseable and *also* under 4 KiB in the fixtures, yet it does hold audio —
/// see `assembleAssemblesTheGoodSegmentButReportsTheUnplayableOneAsALoss`, which a size floor here
/// would silently break.
@Test
func discardedSegmentCountIgnoresAPreambleTornOffMidWrite() {
    let names = ["0000.wav"]
    // A RIFF/WAVE header cut short before its `data` chunk: bigger than a stub, smaller than the
    // ~4096-byte preamble it was on its way to becoming.
    let torn = Data(Array("RIFF".utf8) + le32(4_088) + Array("WAVE".utf8)
        + Array("fmt ".utf8) + le32(16) + pcmFormatBody()) + Data(repeating: 0, count: 1_024)

    let discarded = Recovery.discardedSegmentCount(fromFileNames: names,
                                                   sizeByFileName: ["0000.wav": torn.count],
                                                   headerByFileName: ["0000.wav": torn])

    #expect(discarded == 0)
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
