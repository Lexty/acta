import Foundation

// WAV byte fixtures shared by the header/recovery/repair tests. They live here rather than in
// whichever test file happened to need them first: several files build headers out of these, and a
// helper reachable across files should be declared where that is the intent, not by accident.

/// Little-endian `UInt32` bytes - the size fields inside a RIFF header.
func le32(_ value: Int) -> [UInt8] {
    let v = UInt32(truncatingIfNeeded: value)
    return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

/// Little-endian `UInt16` bytes - the field layout inside `fmt `.
func le16(_ value: Int) -> [UInt8] {
    let v = UInt16(truncatingIfNeeded: value)
    return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
}

/// The body of the `fmt ` chunk: 16-bit stereo PCM 48 kHz - what `SegmentWriter` writes.
/// The fields can be overridden to build a deliberately broken format.
func pcmFormatBody(format: Int = 1, channels: Int = 2, sampleRate: Int = 48_000,
                   bitsPerSample: Int = 16, blockAlign: Int? = nil) -> [UInt8] {
    let align = blockAlign ?? channels * bitsPerSample / 8
    var bytes: [UInt8] = []
    bytes += le16(format)
    bytes += le16(channels)
    bytes += le32(sampleRate)
    bytes += le32(sampleRate * align) // byteRate
    bytes += le16(align)
    bytes += le16(bitsPerSample)
    return bytes
}

/// The `fmt ` body for WAVE_FORMAT_EXTENSIBLE: the PCM layout + cbSize/validBits/channelMask/GUID.
/// This is what a live `AVAssetWriter(fileType: .wav)` actually writes.
func extensibleFormatBody(cbSize: Int = 22, subformat: [UInt8] = pcmSubformatGUID) -> [UInt8] {
    var bytes = pcmFormatBody(format: 0xFFFE)
    bytes += le16(cbSize)
    bytes += le16(16) // wValidBitsPerSample
    bytes += le32(3)  // dwChannelMask: FRONT_LEFT | FRONT_RIGHT
    bytes += subformat
    return bytes
}

/// KSDATAFORMAT_SUBTYPE_PCM.
let pcmSubformatGUID: [UInt8] = [
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
]
