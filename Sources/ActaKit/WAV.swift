import Foundation

/// Pure reading of a WAV header: chunk layout, PCM format, duration and the repair plan for a
/// segment whose header was never finalised.
///
/// Lives apart from the file system so that everything the recovery decision rests on — "is this
/// segment usable", "how much audio does it really hold" — is unit-tested (`WAVTests`,
/// `RecoveryTests`). Runtime (`SegmentAssembler`) only supplies the file size and the first bytes.
public enum WAV {
    /// PCM parameters from the `fmt ` chunk, already validated as playable.
    public struct Format: Equatable, Sendable {
        public let channels: Int
        public let sampleRate: Int
        public let bitsPerSample: Int
        /// Bytes per frame — the granularity a truncated file must be cut to.
        public let blockAlign: Int

        /// Bytes per second, computed rather than read from the header: the killed writer leaves
        /// the `byteRate` field as unreliable as the sizes we are here to repair.
        public var byteRate: Int { sampleRate * blockAlign }
    }

    /// Where the audio sits in the file and what the header claims about it.
    public struct Layout: Equatable, Sendable {
        public let format: Format
        /// Offset of the `data` chunk's size field (little-endian `UInt32`).
        public let dataSizeOffset: Int
        /// Offset of the first audio byte.
        public let dataBodyOffset: Int
        /// Size the header declares. Zero on a segment killed before `finishWriting`.
        public let declaredDataSize: Int
    }

    /// How to rewrite an unfinalised header so `ffmpeg` reads the audio the file actually holds.
    ///
    /// Applied by the caller as three FS operations: write `dataSize` at `dataSizeOffset`, write
    /// `riffSize` at `riffSizeOffset`, truncate the file to `truncatedFileSize`.
    public struct HeaderRepair: Equatable, Sendable {
        /// RIFF size always lives at byte 4 — named so the caller states no magic numbers.
        public var riffSizeOffset: Int { 4 }
        public let riffSize: Int
        public let dataSizeOffset: Int
        public let dataSize: Int
        /// Size to cut the file to: whole frames only, so the tail never ends mid-sample.
        public let truncatedFileSize: Int

        public init(riffSize: Int, dataSizeOffset: Int, dataSize: Int, truncatedFileSize: Int) {
            self.riffSize = riffSize
            self.dataSizeOffset = dataSizeOffset
            self.dataSize = dataSize
            self.truncatedFileSize = truncatedFileSize
        }
    }

    /// Size declared by the `RIFF` chunk, or `nil` if the file is not a RIFF/WAVE at all.
    public static func riffSize(_ header: Data) -> Int? {
        let bytes = [UInt8](header)
        guard bytes.count >= 12,
              hasChunkID(bytes, at: 0, "RIFF"),
              hasChunkID(bytes, at: 8, "WAVE") else { return nil }
        return Int(uint32(bytes, at: 4))
    }

    /// Walk the chunks up to `data` and describe the layout.
    ///
    /// `nil` means the prefix gives no ground to trust the file: not a RIFF/WAVE, a `fmt ` chunk
    /// that does not describe playable PCM, or no `data` chunk within the read prefix. Such a
    /// segment can be neither included nor repaired — `ffmpeg` would reject it and take the whole
    /// track's concat down with it.
    public static func layout(_ header: Data) -> Layout? {
        let bytes = [UInt8](header)
        guard bytes.count >= 12,
              hasChunkID(bytes, at: 0, "RIFF"),
              hasChunkID(bytes, at: 8, "WAVE") else { return nil }

        var offset = 12
        var format: Format?
        while offset + 8 <= bytes.count {
            let size = Int(uint32(bytes, at: offset + 4))
            if hasChunkID(bytes, at: offset, "fmt ") {
                guard size >= 16,
                      let parsed = parseFormat(bytes, bodyAt: offset + 8, bodySize: size) else { return nil }
                format = parsed
            } else if hasChunkID(bytes, at: offset, "data") {
                guard let format else { return nil }
                return Layout(format: format, dataSizeOffset: offset + 4,
                              dataBodyOffset: offset + 8, declaredDataSize: size)
            }
            offset += 8 + size + (size % 2) // chunks are padded to an even boundary
        }
        return nil
    }

    /// Duration of the audio the file really holds, seconds.
    ///
    /// Measured from the data, not from the clock: an unfinalised header declares zero bytes while
    /// megabytes of audio follow it, and a finalised one may declare less than the file holds. Both
    /// are answered by taking the bytes that are actually there and dividing by the byte rate.
    /// `nil` = the header gives nothing to measure against.
    public static func durationSeconds(header: Data, fileSize: Int) -> Double? {
        guard let layout = layout(header), layout.format.byteRate > 0 else { return nil }
        let available = max(0, fileSize - layout.dataBodyOffset)
        let size = layout.declaredDataSize > 0 ? min(layout.declaredDataSize, available) : available
        return Double(size) / Double(layout.format.byteRate)
    }

    /// What to rewrite so an unfinalised segment becomes a readable WAV, or `nil` if there is no
    /// audio to save (empty `data`, unparseable header).
    ///
    /// The sizes are derived from the real file size and rounded **down** to whole frames: a
    /// `kill -9` lands mid-buffer, and half a sample at the end is what makes `ffmpeg` complain
    /// about a truncated file rather than just play the tail.
    public static func headerRepair(header: Data, fileSize: Int) -> HeaderRepair? {
        guard let layout = layout(header) else { return nil }
        let align = layout.format.blockAlign
        guard align > 0 else { return nil }
        let available = fileSize - layout.dataBodyOffset
        guard available >= align else { return nil }

        let dataSize = (available / align) * align
        let truncated = layout.dataBodyOffset + dataSize
        return HeaderRepair(riffSize: truncated - 8, dataSizeOffset: layout.dataSizeOffset,
                            dataSize: dataSize, truncatedFileSize: truncated)
    }

    /// Little-endian `UInt32` bytes — the caller patches header fields with them.
    public static func le32(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    // MARK: - Private

    /// Parse the `fmt ` body, accepting only what `ffmpeg` can concat with `-c copy`.
    ///
    /// Chunk size alone is not enough: a 16-byte `fmt ` with a zero body is formally "present" yet
    /// `ffmpeg` dies on it (`Invalid sample rate: 0`) and takes the whole track's concat with it.
    /// Fields are checked for sanity, not for an exact match with our writer's settings: a segment
    /// in a different but valid format is readable, and dropping it would lose data for nothing.
    private static func parseFormat(_ bytes: [UInt8], bodyAt offset: Int, bodySize: Int) -> Format? {
        // The body did not fit into the read prefix — nothing to confirm the format with.
        guard offset + 16 <= bytes.count else { return nil }
        let format = uint16(bytes, at: offset)
        let channels = Int(uint16(bytes, at: offset + 2))
        let sampleRate = Int(uint32(bytes, at: offset + 4))
        let blockAlign = Int(uint16(bytes, at: offset + 12))
        let bitsPerSample = Int(uint16(bytes, at: offset + 14))

        switch format {
        case wavFormatPCM: break
        case wavFormatExtensible:
            guard isValidExtensibleTail(bytes, bodyAt: offset, bodySize: bodySize) else { return nil }
        default: return nil
        }
        guard channels > 0, sampleRate > 0 else { return nil }
        guard bitsPerSample > 0, bitsPerSample % 8 == 0 else { return nil }
        guard blockAlign == channels * bitsPerSample / 8 else { return nil }
        return Format(channels: channels, sampleRate: sampleRate,
                      bitsPerSample: bitsPerSample, blockAlign: blockAlign)
    }

    /// Is `WAVE_FORMAT_EXTENSIBLE` spelled out to the end and does it describe PCM?
    ///
    /// The `0xFFFE` tag alone is not enough: with a 16-byte PCM-shaped body the format is
    /// unfinished — there is no actual codec in it, and `ffmpeg` rejects such a segment (`Codec
    /// none not supported in WAVE format`), taking the whole track's concat with it. A real
    /// extensible carries `cbSize` ≥ 22 and a subformat GUID; only the PCM GUID is accepted —
    /// others (IEEE float, say) our `-c copy` could not concat with 16-bit segments anyway.
    private static func isValidExtensibleTail(_ bytes: [UInt8], bodyAt offset: Int,
                                              bodySize: Int) -> Bool {
        guard bodySize >= 40, offset + 40 <= bytes.count else { return false }
        guard Int(uint16(bytes, at: offset + 16)) >= 22 else { return false }
        return Array(bytes[(offset + 24)..<(offset + 40)]) == pcmSubformatGUID
    }

    /// `WAVE_FORMAT_PCM` — the only format our writer produces.
    private static let wavFormatPCM: UInt16 = 1

    /// `WAVE_FORMAT_EXTENSIBLE` — the same PCM spelled out for multichannel audio; `ffmpeg` reads
    /// it (when the body is complete, see `isValidExtensibleTail`), so there is no reason to drop
    /// such a segment.
    private static let wavFormatExtensible: UInt16 = 0xFFFE

    /// `KSDATAFORMAT_SUBTYPE_PCM` — GUID `00000001-0000-0010-8000-00AA00389B71` in WAV layout
    /// (first three fields little-endian, last eight bytes as-is).
    private static let pcmSubformatGUID: [UInt8] = [
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
    ]

    /// Does the four-byte ASCII chunk ID at `offset` match?
    private static func hasChunkID(_ bytes: [UInt8], at offset: Int, _ expected: String) -> Bool {
        guard offset + 4 <= bytes.count else { return false }
        return Array(bytes[offset..<(offset + 4)]) == Array(expected.utf8)
    }

    /// Little-endian `UInt16` at `offset` (the field layout inside `fmt `).
    private static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    /// Little-endian `UInt32` at `offset` (the RIFF size field layout).
    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
