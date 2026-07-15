import Testing
import Foundation
import ActaKit

// Applying a repair plan to a real file on disk. `WAVTests` proves the plan is right; these prove
// the bytes end up right - the step that actually gets the audio of a killed segment back.

/// Bytes per second for the `SegmentWriter` format: 48 kHz, stereo, 16-bit.
private let repairByteRate = 48_000 * 4

/// A segment in the layout a live `AVAssetWriter(fileType: .wav)` leaves after `kill -9`: the
/// `FLLR` padding puts the `data` size field at 4092 (not at 40, as in the synthetic fixtures), and
/// both sizes were never written. Followed by `audioBytes` of actual audio.
private func killedSegment(audioBytes: Int) -> Data {
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(4088) // the preamble size the killed writer leaves behind
    bytes += Array("WAVE".utf8)
    bytes += Array("JUNK".utf8)
    bytes += le32(28)
    bytes += [UInt8](repeating: 0, count: 28)
    bytes += Array("fmt ".utf8)
    bytes += le32(40)
    bytes += extensibleFormatBody()
    bytes += Array("FLLR".utf8)
    bytes += le32(3984)
    bytes += [UInt8](repeating: 0, count: 3984)
    bytes += Array("data".utf8)
    bytes += le32(0) // never filled in: the writer died before `finishWriting`
    bytes += [UInt8](repeating: 0x7F, count: audioBytes)
    return Data(bytes)
}

/// Write `data` to a unique temp file and hand its URL to `body`.
private func withTempFile(_ data: Data, _ body: (URL) throws -> Void) rethrows {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acta-repair-\(UUID().uuidString).wav")
    FileManager.default.createFile(atPath: url.path, contents: data)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}

@Test
func repairMakesAKilledSegmentReadBackWithItsRealDuration() throws {
    // The whole point of Task 8.1, end to end on real bytes: a segment killed mid-write holds
    // 2.92 s of audio and a header that claims zero. After the repair the file on disk must
    // describe exactly those 2.92 s.
    let audioBytes = (Int(2.92 * Double(repairByteRate)) / 4) * 4
    let file = killedSegment(audioBytes: audioBytes)
    try withTempFile(file) { url in
        let header = file.prefix(Recovery.headerProbeBytes)
        guard let repair = WAV.headerRepair(header: header, fileSize: file.count) else {
            Issue.record("A killed segment with audio must be repairable")
            return
        }
        #expect(SegmentRepair.apply(repair, to: url))

        let patched = try Data(contentsOf: url)
        let duration = WAV.durationSeconds(header: patched.prefix(Recovery.headerProbeBytes),
                                           fileSize: patched.count)
        #expect(duration.map { abs($0 - 2.92) < 0.001 } == true)
        // Repaired in place, not rewritten: the audio itself must survive byte for byte.
        #expect(patched.count == file.count)
        #expect(Array(patched.suffix(audioBytes)) == [UInt8](repeating: 0x7F, count: audioBytes))
    }
}

@Test
func repairedSegmentIsAcceptedAsIsOnTheNextPass() throws {
    // Recovery is retried after a failed assembly, so a segment it already repaired must come back
    // as `.include`. If the repair left the header inconsistent, the second pass would try to
    // repair it again - and truncate real audio each time round.
    let file = killedSegment(audioBytes: repairByteRate)
    try withTempFile(file) { url in
        let repair = WAV.headerRepair(header: file.prefix(Recovery.headerProbeBytes),
                                      fileSize: file.count)
        #expect(SegmentRepair.apply(try #require(repair), to: url))

        let patched = try Data(contentsOf: url)
        #expect(Recovery.action(bytes: patched.count,
                                header: patched.prefix(Recovery.headerProbeBytes)) == .include)
    }
}

@Test
func repairCutsThePartialTrailingFrame() throws {
    // `kill -9` lands mid-frame: the file must come back cut to whole frames, otherwise ffmpeg
    // reports a torn sample instead of just playing the tail out.
    let file = killedSegment(audioBytes: repairByteRate + 3)
    try withTempFile(file) { url in
        let repair = WAV.headerRepair(header: file.prefix(Recovery.headerProbeBytes),
                                      fileSize: file.count)
        #expect(SegmentRepair.apply(try #require(repair), to: url))

        let size = try #require(try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size == file.count - 3)
    }
}

@Test
func repairOfAMissingFileFails() {
    // The caller drops the segment from the assembly on `false` - it must not be told the file was
    // repaired when there is no file.
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("acta-absent-\(UUID().uuidString).wav")
    let repair = WAV.HeaderRepair(riffSize: 100, dataSizeOffset: 40,
                                  dataSize: 64, truncatedFileSize: 108)
    #expect(SegmentRepair.apply(repair, to: missing) == false)
}
