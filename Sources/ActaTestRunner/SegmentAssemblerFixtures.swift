import Foundation
import ActaKit
import ActaRuntime

// Fixture WAVs and recording folders for `SegmentAssemblerTests`. They live in their own file
// because the assembly suite is where the byte-level shapes matter, and the suite itself is long
// enough without them.
//
// Everything here writes real bytes rather than faking a seam: `SegmentAssembler` takes a directory,
// so a fixture segment is the honest input — the plan, the header repair and `ffmpeg` all read it
// the way they would read a crashed recording.

/// Build a valid, finalized PCM WAV: RIFF/WAVE + `fmt ` + `data` with `frames` frames of silence.
/// The sizes are written through, so `Recovery.action` returns `.include` and `ffmpeg` reads it.
///
/// The `fmt ` fields can be overridden to build a file that passes the segment plan but that
/// `ffmpeg` refuses — the plan only checks the RIFF/`data` sizes, not whether the format makes
/// sense.
func writeWAV(to url: URL, frames: Int = 480, format: Int = 1, channels: Int = 2,
              sampleRate: Int = 48_000, bitsPerSample: Int = 16) throws {
    let align = max(1, channels * bitsPerSample / 8)
    let fmtBody = pcmFormatBody(format: format, channels: channels, sampleRate: sampleRate,
                                bitsPerSample: bitsPerSample)
    let audio = [UInt8](repeating: 0, count: frames * align)

    var body: [UInt8] = Array("WAVE".utf8)
    body += Array("fmt ".utf8) + le32(fmtBody.count) + fmtBody
    body += Array("data".utf8) + le32(audio.count) + audio

    let bytes = Array("RIFF".utf8) + le32(body.count) + body
    try Data(bytes).write(to: url)
}

/// Build the segment a `kill -9` leaves behind: valid RIFF/WAVE and `fmt `, real audio in `data` —
/// and both sizes still unwritten, because `AVAssetWriter` sets them only in `finishWriting`.
///
/// This is the one shape `Recovery.action` answers with `.repair`, and the only way to drive the
/// repair path from a fixture: `writeWAV` writes its sizes through, so every segment it makes takes
/// the `.include` branch instead.
func writeUnfinalizedWAV(to url: URL, frames: Int = 24_000) throws {
    let fmtBody = pcmFormatBody()
    let audio = [UInt8](repeating: 0, count: frames * 4) // 2 ch x 16 bit

    var body: [UInt8] = Array("WAVE".utf8)
    body += Array("fmt ".utf8) + le32(fmtBody.count) + fmtBody
    body += Array("data".utf8) + le32(0) + audio // the `data` size never made it to disk

    // The RIFF size keeps the length of the preamble, exactly as a killed writer leaves it: it
    // declares *less* than the file holds, which is why `Recovery` leans on the `data` size instead.
    let bytes = Array("RIFF".utf8) + le32(body.count - audio.count) + body
    try Data(bytes).write(to: url)
}

/// A segment whose `data` chunk sits past `Recovery.headerProbeBytes`, pushed there by an oversized
/// padding chunk — every size written through, real audio inside, and still invisible to the plan.
///
/// This is not a hypothetical shape: `Recovery.headerProbeBytes` documents it as the live risk it
/// was widened for. A real `AVAssetWriter` puts `data` at 4088..4096 behind an `FLLR` chunk, so a
/// different `sourceFormatHint` or an alignment change in a new macOS moves it — and the plan then
/// discards whole segments of audio without a word. The probe is a fixed window; this is what lies
/// beyond it.
func writeWAVWithDataBeyondProbe(to url: URL, frames: Int = 24_000) throws {
    let fmtBody = pcmFormatBody()
    let audio = [UInt8](repeating: 0, count: frames * 4) // 2 ch x 16 bit
    let padding = [UInt8](repeating: 0, count: Recovery.headerProbeBytes + 4_096)

    var body: [UInt8] = Array("WAVE".utf8)
    body += Array("fmt ".utf8) + le32(fmtBody.count) + fmtBody
    body += Array("FLLR".utf8) + le32(padding.count) + padding
    body += Array("data".utf8) + le32(audio.count) + audio

    let bytes = Array("RIFF".utf8) + le32(body.count) + body
    try Data(bytes).write(to: url)
}

/// The file a real `AVAssetWriter` leaves between `startWriting` and the first `append`: the whole
/// preamble — `FLLR` padding included, so the `data` header lands at exactly 4088..4096, the shape
/// `Recovery.headerProbeBytes` documents — and not one frame of audio behind it.
///
/// A byte cutoff cannot tell this from a segment full of audio: at 4096 bytes it is two orders of
/// magnitude above `minValidSegmentBytes`, which is why the retention guard parses the header rather
/// than weighing the file. A crash between a segment rollover and its first buffer leaves exactly
/// this, and reading it as lost audio condemns a whole meeting to a false "partially assembled".
func writeEmptyPreambleWAV(to url: URL) throws {
    let fmtBody = pcmFormatBody()
    let padding = [UInt8](repeating: 0, count: 4_044) // sized so `data` starts at 4088

    var body: [UInt8] = Array("WAVE".utf8)
    body += Array("fmt ".utf8) + le32(fmtBody.count) + fmtBody
    body += Array("FLLR".utf8) + le32(padding.count) + padding
    body += Array("data".utf8) + le32(0) // the size is unset and the body is genuinely empty

    // The RIFF size holds the preamble length, exactly as a killed writer leaves it.
    let bytes = Array("RIFF".utf8) + le32(body.count) + body
    try Data(bytes).write(to: url)
}

/// A recording folder with the requested number of valid segments per track. A track given `nil`
/// still gets its (empty) directory — that is what the writers create before the first buffer.
func makeRecording(in directory: URL, systemSegments: Int?, micSegments: Int?) throws {
    for (dirName, count) in [(SegmentLayout.systemDirName, systemSegments),
                             (SegmentLayout.micDirName, micSegments)] {
        let trackDir = directory.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)
        for index in 0..<(count ?? 0) {
            try writeWAV(to: trackDir.appendingPathComponent(String(format: "%04d.wav", index)))
        }
    }
}

func withRecordingDirectory(_ body: (URL) throws -> Void) rethrows {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acta-assembler-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}

func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// Seconds of audio an assembled track really holds, read off its header (`WAV.durationSeconds` is
/// the same pure function `SegmentAssembler` measures with).
func durationOfWAV(at url: URL) -> Double? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return WAV.durationSeconds(header: data.prefix(Recovery.headerProbeBytes), fileSize: data.count)
}

/// The names of the final files sitting in the recording folder (the track directories and the
/// concat lists are not final files).
func finalFileNames(in directory: URL) -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return Set(names.filter { $0.hasSuffix(".wav") })
}

/// Two segments the plan accepts and `ffmpeg` cannot concat under `-c copy`: the second declares a
/// different sample rate and channel count, which `WAV.layout` has no reason to refuse (it is
/// perfectly playable PCM) but which makes the muxer reject the packet stream mid-write.
///
/// This is the only fixture shape that drives a *real* `ffmpeg` failure. Blocking the output path
/// instead would no longer fail at all, now that the concat writes under a temp name — and it never
/// reproduced the thing that makes this failure dangerous: `ffmpeg` muxes the first segment before
/// it dies, so the failure comes with a short, playable file attached.
func makeConcatFailingSystemTrack(in directory: URL) throws {
    let systemDir = directory.appendingPathComponent(SegmentLayout.systemDirName)
    try writeWAV(to: systemDir.appendingPathComponent("0000.wav"), frames: 96_000) // 2 s @ 48 kHz
    try writeWAV(to: systemDir.appendingPathComponent("0001.wav"), frames: 11_025,
                 channels: 1, sampleRate: 22_050)
}
