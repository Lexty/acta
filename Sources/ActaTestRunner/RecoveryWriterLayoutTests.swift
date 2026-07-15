import ActaKit
import Foundation
import Testing

// Header checks against the layout that `AVAssetWriter(fileType: .wav)` actually writes -
// captured from a live writer. Kept separate from the synthetic headers in `RecoveryTests`: what
// matters here is not "the parsing logic is correct" but "the `headerProbeBytes` window covers a
// real file".

/// A header in exactly the layout a live `AVAssetWriter(fileType: .wav)` writes:
/// `JUNK`(28) -> `fmt `(40, extensible) -> `FLLR`(padding) -> `data`. With `padding: 3984` the
/// `data` header ends exactly at byte 4096 - just like in the file actually captured from the
/// writer. It is the aligning `FLLR` that makes the `headerProbeBytes` window the bottleneck.
private func realWriterLayout(dataSize: Int, fileSize: Int, padding: Int = 3984) -> Data {
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(fileSize - 8)
    bytes += Array("WAVE".utf8)
    bytes += Array("JUNK".utf8)
    bytes += le32(28)
    bytes += [UInt8](repeating: 0, count: 28)
    bytes += Array("fmt ".utf8)
    bytes += le32(40)
    bytes += extensibleFormatBody()
    bytes += Array("FLLR".utf8)
    bytes += le32(padding)
    bytes += [UInt8](repeating: 0, count: padding)
    bytes += Array("data".utf8)
    bytes += le32(dataSize)
    return Data(bytes)
}

@Test
func realWriterLayoutIsIncludedAsIs() {
    // Regression: with a live writer the `data` header ends exactly at byte 4096 - in the former
    // 4096-byte window it fit byte for byte. Any extra chunk would push it out, and then ALL
    // segments would become invalid at once: both assembly and recovery would return nothing.
    let header = realWriterLayout(dataSize: 192_000, fileSize: 196_096)
    #expect(header.count == 4096)
    #expect(Recovery.headerProbeBytes > header.count)
    #expect(Recovery.action(bytes: 196_096, header: header) == .include)
}

@Test
func realWriterLayoutWithLargerPaddingIsIncludedAsIs() {
    // The window's headroom must not depend on the current padding size: a `data` chunk that
    // moved past 4 KiB (a different formatHint, an extra chunk, changed padding in a new macOS)
    // must still be found - otherwise segments become invalid all at once, which is a silent
    // loss of the whole recording. A 16112-byte header (16000 bytes of padding) + 192000 bytes
    // of audio.
    let header = realWriterLayout(dataSize: 192_000, fileSize: 208_112, padding: 16_000)
    #expect(header.count > 4096)
    #expect(header.count <= Recovery.headerProbeBytes)
    #expect(Recovery.action(bytes: 208_112, header: header) == .include)
}

@Test
func realWriterLayoutFromCrashIsRepairedNotDiscarded() {
    // A writer killed by `kill -9` leaves the `data` size at zero, and the RIFF field holds the
    // preamble size (4088), which is SMALLER than the file, i.e. it passes the RIFF check. The
    // zero `data` size means the header is not finalized - but the file still holds real audio
    // (2.92 s in the live run of Task 8), so the segment must be REPAIRED, not discarded.
    //
    // Asserting the whole repair, not just "not valid as is": `dataSizeOffset` is 4092 here
    // because of the `FLLR` padding, while every synthetic fixture puts it at 40. Any regression
    // in the chunk walk would send `WAV.layout` to nil, `Recovery.action` to nil, and the last
    // segment silently into the bin - the exact defect this branch fixed.
    var bytes = [UInt8](realWriterLayout(dataSize: 0, fileSize: 382_464))
    bytes.replaceSubrange(4..<8, with: le32(4088))
    #expect(Recovery.action(bytes: 382_464, header: Data(bytes))
            == .repair(WAV.HeaderRepair(riffSize: 382_456, dataSizeOffset: 4092,
                                        dataSize: 378_368, truncatedFileSize: 382_464)))
}

@Test
func realWriterLayoutBelowTheSizeThresholdIsDiscarded() {
    // The writer created the segment but the crash landed before any audio: only the preamble is
    // on disk, there is nothing to rescue.
    #expect(Recovery.action(bytes: Recovery.minValidSegmentBytes - 1,
                            header: realWriterLayout(dataSize: 0, fileSize: 40)) == nil)
}
