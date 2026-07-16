import Testing
import Foundation
import ActaKit

// Recovery and session-marker logic - pure, covered separately from the file system/ffmpeg.

// MARK: - WAV header fixtures

/// A finalized WAV header: the sizes are filled in and match the file size.
private func finalizedHeader(fileSize: Int) -> Data {
    header(riffSize: fileSize - 8, dataSize: fileSize - 44)
}

/// A header with arbitrary sizes - for the unfinalized-file cases.
private func header(riffSize: Int, dataSize: Int) -> Data {
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(riffSize)
    bytes += Array("WAVE".utf8)
    bytes += Array("fmt ".utf8)
    bytes += le32(16)
    bytes += pcmFormatBody()
    bytes += Array("data".utf8)
    bytes += le32(dataSize)
    return Data(bytes)
}

/// Headers for a set of valid segments of the same size.
///
/// Internal rather than private: `RecoveryPlanLossTests` builds the same headers.
func headers(_ names: [String], fileSize: Int) -> [String: Data] {
    Dictionary(uniqueKeysWithValues: names.map { ($0, finalizedHeader(fileSize: fileSize)) })
}

/// The names of the segments that made it into the plan (their order and set is what goes to
/// `ffmpeg`).
private func planned(_ plan: [Recovery.PlannedSegment]) -> [String] {
    plan.map(\.fileName)
}

/// The plan's action for a segment; `nil` if the segment did not make it into the plan.
private func action(_ plan: [Recovery.PlannedSegment], for name: String) -> Recovery.Action? {
    plan.first { $0.fileName == name }?.action
}

// MARK: - The assembly plan

@Test
func recoveryPlanOrdersValidSegments() {
    let names = ["0002.wav", "0000.wav", "0001.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 4096, "0002.wav": 4096]
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: headers(names, fileSize: 4096))
    #expect(planned(plan) == ["0000.wav", "0001.wav", "0002.wav"])
    #expect(plan.allSatisfy { $0.action == .include })
}

@Test
func recoveryPlanDropsEmptyLastSegment() {
    // A segment that no buffer made it into: there is nothing to salvage, we drop it.
    let names = ["0000.wav", "0001.wav", "0002.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 4096, "0002.wav": 0]
    var byName = headers(names, fileSize: 4096)
    byName["0002.wav"] = Data()
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: byName)
    #expect(planned(plan) == ["0000.wav", "0001.wav"])
}

@Test
func recoveryPlanRepairsLastSegmentWithUnfinalizedHeader() {
    // The main crash case (Task 8.1): the killed writer left kilobytes of audio behind, but the
    // sizes in the header were never filled in. Such a segment is repaired from its actual size
    // rather than discarded: previously this cost real seconds of recording.
    let names = ["0000.wav", "0001.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 8192]
    var byName = headers(names, fileSize: 4096)
    byName["0001.wav"] = header(riffSize: 0, dataSize: 0)
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: byName)
    #expect(planned(plan) == ["0000.wav", "0001.wav"])
    #expect(action(plan, for: "0000.wav") == .include)
    // The data starts at byte 44: 8192 - 44 = 8148, which is already a whole number of 4-byte
    // frames.
    #expect(action(plan, for: "0001.wav")
        == .repair(WAV.HeaderRepair(riffSize: 8184, dataSizeOffset: 40,
                                    dataSize: 8148, truncatedFileSize: 8192)))
}

@Test
func recoveryPlanDropsCorruptMiddleSegment() {
    // A corrupt segment is dropped regardless of its position: skipping one chunk is acceptable,
    // but the trailing valid segments must survive (rather than being cut off at the first
    // corrupt one).
    let names = ["0000.wav", "0001.wav", "0002.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 0, "0002.wav": 4096]
    var byName = headers(names, fileSize: 4096)
    byName["0001.wav"] = Data()
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: byName)
    #expect(planned(plan) == ["0000.wav", "0002.wav"])
}

@Test
func recoveryPlanFiltersJunkAndMissingSizes() {
    let names = ["0000.wav", ".DS_Store", "combined.wav", "0001.wav"]
    // 0001.wav is absent from the sizes -> treated as 0 -> dropped.
    let sizes = ["0000.wav": 4096]
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: headers(names, fileSize: 4096))
    #expect(planned(plan) == ["0000.wav"])
}

@Test
func recoveryPlanDropsSegmentWithUnreadableHeader() {
    // The header could not be read (the file vanished/is inaccessible) - we can neither accept
    // nor repair it: we do not even know where the audio starts in the file.
    let plan = Recovery.recoveryPlan(fromFileNames: ["0000.wav"], sizeByFileName: ["0000.wav": 4096],
                                     headerByFileName: [:])
    #expect(plan.isEmpty)
}

@Test
func recoveryPlanEmptyWhenNothingValid() {
    let plan = Recovery.recoveryPlan(fromFileNames: ["0000.wav"], sizeByFileName: ["0000.wav": 10],
                                     headerByFileName: ["0000.wav": finalizedHeader(fileSize: 10)])
    #expect(plan.isEmpty)
}

@Test
func recoveryPlanKeepsEveryLiveRunSegment() {
    // Task 8.1 acceptance based on the facts of a live run (2026-07-15): at the moment of
    // `kill -9` the system track held 12 segments - 11 closed ones of 15 s each and a final
    // unfinalized one with 2.92 s of audio. The former rule kept 11 (165.0 s); all 12 give
    // approximately 167.9 s.
    let rate = 48_000 * 4 // 16-bit stereo: bytes per second
    let closedSize = 44 + 15 * rate
    let killedSize = 44 + Int(2.92 * Double(rate))
    let names = (0..<12).map { SegmentLayout.segmentFileName(index: $0) }
    var sizes: [String: Int] = [:]
    var byName: [String: Data] = [:]
    for (index, name) in names.enumerated() {
        let killed = index == 11
        sizes[name] = killed ? killedSize : closedSize
        byName[name] = killed ? header(riffSize: 0, dataSize: 0) : finalizedHeader(fileSize: closedSize)
    }

    let plan = Recovery.recoveryPlan(fromFileNames: names.shuffled(), sizeByFileName: sizes,
                                     headerByFileName: byName)
    #expect(planned(plan) == names)
    #expect(plan.filter { $0.action == .include }.count == 11)

    let duration = plan.reduce(0.0) { total, segment in
        let size = sizes[segment.fileName] ?? 0
        return total + (WAV.durationSeconds(header: byName[segment.fileName] ?? Data(),
                                            fileSize: size) ?? 0)
    }
    #expect(abs(duration - 167.92) < 0.01)
}

// MARK: - Segment validation

@Test
func segmentSizeThreshold() {
    let size = Recovery.minValidSegmentBytes
    #expect(Recovery.action(bytes: size, header: finalizedHeader(fileSize: size)) == .include)
    // Below the threshold there is not even a header's worth of file: nothing to include and
    // nothing to repair.
    #expect(Recovery.action(bytes: size - 1, header: finalizedHeader(fileSize: size - 1)) == nil)
    #expect(Recovery.action(bytes: 0, header: Data()) == nil)
}

@Test
func finalizedHeaderAccepted() {
    #expect(Recovery.isFinalizedWAVHeader(finalizedHeader(fileSize: 4096), fileSize: 4096))
}

@Test
func headerWithoutRIFFMagicRejected() {
    #expect(Recovery.isFinalizedWAVHeader(Data(repeating: 0, count: 128), fileSize: 4096) == false)
    #expect(Recovery.isFinalizedWAVHeader(Data("free-form garbage padded".utf8),
                                          fileSize: 4096) == false)
}

@Test
func headerWithUnsetSizesRejected() {
    // An unfinalized AVAssetWriter: the magic is in place, the sizes are placeholders.
    #expect(Recovery.isFinalizedWAVHeader(header(riffSize: 0, dataSize: 0), fileSize: 8192) == false)
    #expect(Recovery.isFinalizedWAVHeader(header(riffSize: 4, dataSize: 0), fileSize: 8192) == false)
}

@Test
func headerPromisingMoreThanFileHasRejected() {
    // The size is declared, but the file is truncated midway - there is less data than promised.
    #expect(Recovery.isFinalizedWAVHeader(finalizedHeader(fileSize: 65_536),
                                          fileSize: 8192) == false)
    // The RIFF size adds up, but the data chunk runs past the end of the file.
    #expect(Recovery.isFinalizedWAVHeader(header(riffSize: 4088, dataSize: 65_536),
                                          fileSize: 4096) == false)
}

@Test
func headerWithoutChunksRejected() {
    // RIFF/WAVE + a plausible size, but no meaningful chunks: ffmpeg rejects such a file, so the
    // RIFF size alone cannot be trusted - there is nothing to confirm the integrity with.
    var bare: [UInt8] = []
    bare += Array("RIFF".utf8)
    bare += le32(4088)
    bare += Array("WAVE".utf8)
    #expect(Recovery.isFinalizedWAVHeader(Data(bare), fileSize: 4096) == false)

    // The same case, but the tail is filled with zeros/junk instead of chunks.
    #expect(Recovery.isFinalizedWAVHeader(Data(bare + [UInt8](repeating: 0, count: 512)),
                                          fileSize: 4096) == false)
    #expect(Recovery.isFinalizedWAVHeader(Data(bare + Array("junk padding not a chunk".utf8)),
                                          fileSize: 4096) == false)
}

@Test
func headerWithDataButWithoutFormatRejected() {
    // data without fmt is an undescribed stream: ffmpeg does not know how to read it.
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(4088)
    bytes += Array("WAVE".utf8)
    bytes += Array("data".utf8)
    bytes += le32(4052)
    #expect(Recovery.isFinalizedWAVHeader(Data(bytes), fileSize: 4096) == false)
}

@Test
func headerWithChunkBeforeFormatAccepted() {
    // A foreign chunk (LIST) before fmt /data is skipped by its size, the segment stays valid.
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(4088)
    bytes += Array("WAVE".utf8)
    bytes += Array("LIST".utf8)
    bytes += le32(8)
    bytes += [UInt8](repeating: 0, count: 8)
    bytes += Array("fmt ".utf8)
    bytes += le32(16)
    bytes += pcmFormatBody()
    bytes += Array("data".utf8)
    bytes += le32(4032)
    #expect(Recovery.isFinalizedWAVHeader(Data(bytes), fileSize: 4096))
}

// MARK: - Validating the fmt chunk

/// A header whose `fmt ` body is assembled from arbitrary format fields.
private func headerWithFormat(_ body: [UInt8], fileSize: Int = 4096) -> Data {
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(fileSize - 8)
    bytes += Array("WAVE".utf8)
    bytes += Array("fmt ".utf8)
    bytes += le32(body.count)
    bytes += body
    bytes += Array("data".utf8)
    // The data tail takes up everything left of the file after the header (the fmt body has a
    // variable length).
    bytes += le32(fileSize - (bytes.count + 4))
    return Data(bytes)
}

@Test
func headerWithZeroedFormatBodyRejected() {
    // fmt is in place and 16 bytes long, but its body is zeros: ffmpeg fails with
    // `Invalid sample rate: 0` and takes down the assembly of the entire track. The chunk size
    // alone is not enough.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat([UInt8](repeating: 0, count: 16)),
                                          fileSize: 4096) == false)
}

@Test
func headerWithNonsenseFormatFieldsRejected() {
    // Each field on its own renders the stream unreadable.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(sampleRate: 0)),
                                          fileSize: 4096) == false)
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(channels: 0)),
                                          fileSize: 4096) == false)
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(bitsPerSample: 0)),
                                          fileSize: 4096) == false)
    // The bit depth is not a multiple of a byte.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(bitsPerSample: 12)),
                                          fileSize: 4096) == false)
    // blockAlign does not match channels * bits / 8 - the header contradicts itself.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(blockAlign: 3)),
                                          fileSize: 4096) == false)
    // Not a PCM tag (for example 0 - an unfilled field).
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(format: 0)),
                                          fileSize: 4096) == false)
}

@Test
func headerWithExtensiblePCMAccepted() {
    // A fully specified WAVE_FORMAT_EXTENSIBLE is the same PCM layout; ffmpeg reads it, so there
    // is no reason to discard it.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(extensibleFormatBody()), fileSize: 4096))
}

@Test
func headerWithUnderspecifiedExtensibleRejected() {
    // Tag 0xFFFE with a 16-byte PCM body: the format is under-specified - it names no codec,
    // ffmpeg rejects it (`Codec none not supported in WAVE format`) and takes down the assembly
    // of the entire track.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(format: 0xFFFE)),
                                          fileSize: 4096) == false)
    // The body is of the right length, but cbSize is not set - the extension is not declared.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(extensibleFormatBody(cbSize: 0)),
                                          fileSize: 4096) == false)
    // The subformat is not PCM (IEEE float here) - `-c copy` will not assemble it together with
    // the 16-bit segments.
    var float = pcmSubformatGUID
    float[0] = 0x03
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(extensibleFormatBody(subformat: float)),
                                          fileSize: 4096) == false)
    // The GUID is truncated: the body falls short of 40 bytes.
    #expect(Recovery.isFinalizedWAVHeader(
        headerWithFormat(Array(extensibleFormatBody().prefix(32))), fileSize: 4096) == false)
}

@Test
func headerWithFormatBodyOutsideProbeRejected() {
    // fmt is declared, but its body did not fit into the prefix that was read - there is nothing
    // to confirm the format with.
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(4088)
    bytes += Array("WAVE".utf8)
    bytes += Array("fmt ".utf8)
    bytes += le32(16)
    bytes += [UInt8](repeating: 0, count: 8) // the body is truncated midway
    #expect(Recovery.isFinalizedWAVHeader(Data(bytes), fileSize: 4096) == false)
}

// MARK: - The session marker

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
    // ISO-8601 for 1_700_000_000 = 2023-11-14T22:13:20Z.
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
    // This payload predates `assembly_attempts`, and markers like it are sitting in real archives
    // right now. A missing key must read as "no attempt spent yet", not throw: the synthesized
    // `Codable` would have thrown, and an unreadable marker is an unrecoverable recording.
    // The round-trip of a non-zero counter lives next to the retry it bounds, in
    // `RecoveryManagerRetryTests`.
    #expect(manifest.assemblyAttempts == 0)
}
