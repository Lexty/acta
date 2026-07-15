import Testing
import Foundation
import ActaKit

// Reading the WAV header: duration from the actual data (Task 8.3) and the repair plan for an
// unfinalized header (Task 8.1). Pure logic - no file system, no ffmpeg.

/// Bytes per second for the `SegmentWriter` format: 48 kHz, stereo, 16-bit.
private let byteRate = 48_000 * 4

/// A 16-bit stereo PCM 48 kHz header with arbitrary sizes. The data starts at byte 44, and the
/// `data` size field is at offset 40.
private func wavHeader(riffSize: Int, dataSize: Int) -> Data {
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(riffSize)
    bytes += Array("WAVE".utf8)
    bytes += Array("fmt ".utf8)
    bytes += le32(16)
    bytes += le16(1)            // WAVE_FORMAT_PCM
    bytes += le16(2)            // channels
    bytes += le32(48_000)       // sample rate
    bytes += le32(byteRate)
    bytes += le16(4)            // blockAlign
    bytes += le16(16)           // bits per sample
    bytes += Array("data".utf8)
    bytes += le32(dataSize)
    return Data(bytes)
}

/// The header of a closed segment: the sizes are filled in and match the file.
private func closedHeader(fileSize: Int) -> Data {
    wavHeader(riffSize: fileSize - 8, dataSize: fileSize - 44)
}

/// The header of a segment killed by `kill -9`: the sizes were never filled in.
private func killedHeader() -> Data {
    wavHeader(riffSize: 0, dataSize: 0)
}

private func le16(_ value: Int) -> [UInt8] {
    let v = UInt16(truncatingIfNeeded: value)
    return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
}

// MARK: - Duration

@Test
func durationComesFromDataNotFromTheClock() {
    // Exactly one second of audio: the duration is computed from the bytes, not from the
    // interval between start and stop.
    let size = 44 + byteRate
    #expect(WAV.durationSeconds(header: closedHeader(fileSize: size), fileSize: size) == 1.0)
}

@Test
func durationOfUnfinalizedSegmentUsesActualFileSize() {
    // The header declares zero, but 2.92 s of audio sit in the file - that is what we measure
    // (the case seen in a live run).
    let size = 44 + Int(2.92 * Double(byteRate))
    let duration = WAV.durationSeconds(header: killedHeader(), fileSize: size)
    #expect(duration.map { abs($0 - 2.92) < 0.001 } == true)
}

@Test
func durationIgnoresBytesBeyondDeclaredData() {
    // The header declares less than the physical size (trailing junk) - we trust the header.
    let size = 44 + byteRate * 2
    #expect(WAV.durationSeconds(header: wavHeader(riffSize: size - 8, dataSize: byteRate),
                                fileSize: size) == 1.0)
}

@Test
func durationClampedToWhatTheFileHolds() {
    // The header promises more than the file holds: we measure what is there, not what was
    // promised.
    #expect(WAV.durationSeconds(header: wavHeader(riffSize: 0, dataSize: byteRate * 10),
                                fileSize: 44 + byteRate) == 1.0)
}

@Test
func durationOfEmptyOrUnreadableHeaderIsNil() {
    #expect(WAV.durationSeconds(header: Data(), fileSize: 4096) == nil)
    #expect(WAV.durationSeconds(header: Data("not a wav at all, just bytes".utf8),
                                fileSize: 4096) == nil)
}

@Test
func durationOfHeaderOnlyFileIsZero() {
    #expect(WAV.durationSeconds(header: killedHeader(), fileSize: 44) == 0)
}

// MARK: - Header repair

@Test
func repairFillsSizesFromActualFileSize() {
    let size = 44 + byteRate
    let repair = WAV.headerRepair(header: killedHeader(), fileSize: size)
    #expect(repair == WAV.HeaderRepair(riffSize: size - 8, dataSizeOffset: 40,
                                       dataSize: byteRate, truncatedFileSize: size))
    #expect(repair?.riffSizeOffset == 4)
}

@Test
func repairTruncatesToWholeFrames() {
    // `kill -9` lands in the middle of a frame: we truncate to a whole one, otherwise ffmpeg
    // complains about a torn sample instead of simply playing out the tail.
    let repair = WAV.headerRepair(header: killedHeader(), fileSize: 44 + byteRate + 3)
    #expect(repair?.dataSize == byteRate)
    #expect(repair?.truncatedFileSize == 44 + byteRate)
}

@Test
func repairedHeaderReadsBackWithTheSameDuration() {
    // End-to-end check: after the repair the header describes exactly the audio left in the file.
    let size = 44 + Int(2.92 * Double(byteRate))
    guard let repair = WAV.headerRepair(header: killedHeader(), fileSize: size) else {
        Issue.record("A segment with audio should be repairable")
        return
    }
    let patched = wavHeader(riffSize: repair.riffSize, dataSize: repair.dataSize)
    let duration = WAV.durationSeconds(header: patched, fileSize: repair.truncatedFileSize)
    #expect(duration.map { abs($0 - 2.92) < 0.001 } == true)
}

@Test
func nothingToRepairWhenThereIsNoAudio() {
    // A file consisting of just the preamble (the writer created the segment but never accepted
    // a single buffer) and a file that does not even hold one full frame - there is nothing to
    // repair, the segment is discarded.
    #expect(WAV.headerRepair(header: killedHeader(), fileSize: 44) == nil)
    #expect(WAV.headerRepair(header: killedHeader(), fileSize: 46) == nil)
    #expect(WAV.headerRepair(header: Data(), fileSize: 8192) == nil)
    #expect(WAV.headerRepair(header: Data(repeating: 0, count: 128), fileSize: 8192) == nil)
}

// MARK: - Layout

@Test
func layoutRejectsUnparseableHeaders() {
    // Not RIFF/WAVE; RIFF without a `data` chunk in the prefix that was read; `data` without a
    // preceding `fmt `.
    #expect(WAV.layout(Data("RIFX....WAVEfmt ".utf8)) == nil)
    #expect(WAV.layout(Data(Array("RIFF".utf8) + le32(4088) + Array("WAVE".utf8))) == nil)
    var noFormat: [UInt8] = Array("RIFF".utf8) + le32(4088) + Array("WAVE".utf8)
    noFormat += Array("data".utf8) + le32(1024)
    #expect(WAV.layout(Data(noFormat)) == nil)
}

@Test
func layoutFindsDataAfterPaddingChunk() {
    // A live `AVAssetWriter` inserts an aligning `FLLR` chunk before `data` - the layout parser
    // must step over it, otherwise no segment would ever be valid.
    var bytes: [UInt8] = Array("RIFF".utf8) + le32(4088) + Array("WAVE".utf8)
    bytes += Array("fmt ".utf8) + le32(16)
    bytes += le16(1) + le16(2) + le32(48_000) + le32(byteRate) + le16(4) + le16(16)
    bytes += Array("FLLR".utf8) + le32(64) + [UInt8](repeating: 0, count: 64)
    bytes += Array("data".utf8) + le32(1024)

    let layout = WAV.layout(Data(bytes))
    #expect(layout?.declaredDataSize == 1024)
    #expect(layout?.dataBodyOffset == bytes.count)
    #expect(layout?.format.byteRate == byteRate)
}
