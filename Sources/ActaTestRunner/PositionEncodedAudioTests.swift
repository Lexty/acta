import Testing
import AVFoundation
import CoreMedia
import Foundation
import ActaKit

// The oracle, checked against files made of literal bytes — no subprocess, no recording, no ffmpeg.
//
// Why this suite exists at all: the crash scenario's whole worth rests on the oracle being able to
// FAIL. An oracle that only ever returned `.ok` would make every later assertion a rubber stamp and
// nothing downstream would notice. So each failure it can report is provoked here, on a file built
// to provoke exactly that one. The negative control in Task 3 then proves it fails in the harness;
// this proves it can fail at all.

/// A finished 16-bit stereo 48 kHz WAV whose `data` chunk holds `frameIndices` in order, each frame
/// filled from the position it *claims* to be at.
///
/// The frames are listed rather than counted so a test can hand-build a broken stream: `0..<n` is a
/// correct file, and dropping an element from the middle of that list is a lost frame with every
/// later frame slid forward — precisely what a real loss looks like on disk.
private func positionEncodedWAV(track: Track, frameIndices: [Int], channels: Int = 2,
                                bitsPerSample: Int = 16) -> Data {
    var body: [UInt8] = []
    for index in frameIndices {
        for channel in 0..<channels {
            let value = PositionEncodedAudio.sample(track: track, frameIndex: index, channel: channel)
            body += [UInt8(UInt16(bitPattern: value) & 0xFF), UInt8(UInt16(bitPattern: value) >> 8)]
        }
    }
    return wrapAsWAV(body: body, channels: channels, bitsPerSample: bitsPerSample)
}

/// A finished, well-formed WAV around a `data` body — the sizes filled in as a closed segment's are.
private func wrapAsWAV(body: [UInt8], channels: Int = 2, bitsPerSample: Int = 16) -> Data {
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(36 + body.count)
    bytes += Array("WAVE".utf8)
    bytes += Array("fmt ".utf8)
    bytes += le32(16)
    bytes += pcmFormatBody(channels: channels, bitsPerSample: bitsPerSample)
    bytes += Array("data".utf8)
    bytes += le32(body.count)
    bytes += body
    return Data(bytes)
}

/// The raw bytes a `CMSampleBuffer` carries, as they would reach a file.
private func sampleBufferBytes(_ sampleBuffer: CMSampleBuffer) -> [UInt8]? {
    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
    let length = CMBlockBufferGetDataLength(block)
    var bytes = [UInt8](repeating: 0, count: length)
    guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                     destination: &bytes) == noErr else { return nil }
    return bytes
}

/// A correct file: every frame from 0 to `frames`, in order, nothing missing.
private func correctWAV(track: Track = .system, frames: Int) -> Data {
    positionEncodedWAV(track: track, frameIndices: Array(0..<frames))
}

/// Exactly `frames`, allowing nothing else — the range a test uses when it means "this length".
private func exactly(_ frames: Int) -> ClosedRange<Int> { frames...frames }

// MARK: - The encoding itself

@Test
func aSamplesValueIsDecidedByItsPosition() {
    // The formula, spelled out at one point so a change to it has to come here and say so.
    #expect(PositionEncodedAudio.sample(track: .system, frameIndex: 0, channel: 0) == 0)
    #expect(PositionEncodedAudio.sample(track: .system, frameIndex: 1, channel: 0) == 3)
    #expect(PositionEncodedAudio.sample(track: .system, frameIndex: 0, channel: 1) == 7)
    // The mic is not the system track plus a constant: it advances by 5 per frame, not 3.
    #expect(PositionEncodedAudio.sample(track: .mic, frameIndex: 0, channel: 0) == 1361)
    #expect(PositionEncodedAudio.sample(track: .mic, frameIndex: 1, channel: 0) == 1366)
    #expect(PositionEncodedAudio.sample(track: .mic, frameIndex: 0, channel: 1) == 1368)
}

@Test
func theEncodingWrapsRatherThanSaturating() {
    // 16 bits cannot hold a whole track, so the value wraps — and the wrap is part of the contract,
    // not an accident: the oracle's guarantee is stated in terms of it.
    let atWrap = PositionEncodedAudio.sample(track: .system, frameIndex: 65_536, channel: 0)
    #expect(atWrap == PositionEncodedAudio.sample(track: .system, frameIndex: 0, channel: 0))
    // Nothing clamps at the Int16 extremes: 10923 * 3 == 32769, which is -32767 truncated, not 32767.
    #expect(PositionEncodedAudio.sample(track: .system, frameIndex: 10_923, channel: 0) == -32_767)
}

@Test
func theTwoTracksAreDistinguishableAtTheSamePosition() {
    let mic = correctWAV(track: .mic, frames: 512)
    #expect(PositionEncodedAudio.verify(wav: mic, track: .mic, frames: exactly(512)) == .ok(frames: 512))
    // Read as the other track, the very first frame is already wrong — and wrong in the way that
    // says "this is not that track", not "this track lost some audio". Were the two tracks separated
    // by a salt alone they would share a slope, the mic track would be the system track shifted by
    // 22299 frames, and this would come back `.discontinuity` with every value confirming.
    let asSystem = PositionEncodedAudio.verify(wav: mic, track: .system, frames: exactly(512))
    #expect(asSystem == .wrongValue(frame: 0, channel: 0, expected: 0, actual: 1361))
}

// MARK: - The generator agrees with the oracle

@Test
func theGeneratorsBuffersSatisfyTheOracle() {
    // Closes the loop the harness will depend on: bytes the generator actually produced, wrapped in
    // a header, must pass the oracle. Both halves are written from the same formula, and this is the
    // only thing standing between "they agree" and "nobody ever checked".
    let frames = 1_024
    guard let buffer = makePositionEncodedSampleBuffer(track: .mic, startFrame: 0, pts: .zero,
                                                       frames: AVAudioFrameCount(frames)),
          let body = sampleBufferBytes(buffer) else {
        Issue.record("could not build a position-encoded sample buffer")
        return
    }
    #expect(PositionEncodedAudio.verify(wav: wrapAsWAV(body: body), track: .mic,
                                        frames: exactly(frames)) == .ok(frames: frames))
}

@Test
func aBuffersStartFrameIsItsPositionInTheTrackNotInTheBuffer() {
    // The encoding is about position within the *track*, so a buffer handed a non-zero `startFrame`
    // must carry the samples belonging to those absolute positions. Read from frame 0 it therefore
    // looks exactly like a track that lost its first 500 frames — which is the property the crash
    // scenario leans on when it counts frames across buffers.
    guard let buffer = makePositionEncodedSampleBuffer(track: .system, startFrame: 500, pts: .zero,
                                                       frames: 256),
          let body = sampleBufferBytes(buffer) else {
        Issue.record("could not build a position-encoded sample buffer")
        return
    }
    #expect(PositionEncodedAudio.verify(wav: wrapAsWAV(body: body), track: .system,
                                        frames: exactly(256)) == .discontinuity(frame: 0, skipped: 500))
}

@Test
func bothBufferLayoutsAreFilledWithTheSamePositions() {
    // The non-interleaved layout is a different `AudioBufferList` shape — one buffer per channel
    // rather than one for both — and it is exactly the fixture meant to catch format variation. A
    // generator that got that branch wrong would fill it with garbage and prove the opposite.
    for format in [FixtureAudioFormat.stereo48k, .stereo48kNonInterleaved] {
        guard let avFormat = format.avFormat,
              let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: 64) else {
            Issue.record("could not build a PCM buffer for \(format)")
            continue
        }
        pcm.frameLength = 64
        fillPositionEncoded(pcm, track: .system, startFrame: 7)

        guard let channelData = pcm.int16ChannelData else {
            Issue.record("no int16 channel data")
            continue
        }
        for frame in 0..<64 {
            for channel in 0..<2 {
                let actual = format.interleaved
                    ? channelData[0][frame * 2 + channel]
                    : channelData[channel][frame]
                #expect(actual == PositionEncodedAudio.sample(track: .system, frameIndex: 7 + frame,
                                                              channel: channel))
            }
        }
    }
}

@Test
func theSilenceGeneratorStillProducesSilence() {
    // The position-encoding generator is additive: fixtures elsewhere rest on `makeAudioSampleBuffer`
    // producing zeros, so the refactor that gave the two a shared body must not have leaked a fill
    // into the silent path.
    guard let buffer = makeAudioSampleBuffer(pts: .zero, frames: 128, format: .stereo48k),
          let body = sampleBufferBytes(buffer) else {
        Issue.record("could not build a silent sample buffer")
        return
    }
    #expect(body.allSatisfy { $0 == 0 })
}

// MARK: - A correct file passes

@Test
func aCorrectFilePasses() {
    let wav = correctWAV(frames: 4_096)
    #expect(PositionEncodedAudio.verify(wav: wav, track: .system, frames: exactly(4_096)) == .ok(frames: 4_096))
}

@Test
func aCorrectFilePassesAcrossTheWrap() {
    // Past 65536 frames the values repeat; the oracle compares against the same wrapped formula, so
    // a long file must still pass. If it did not, every recording over ~1.37 s would "fail".
    let frames = 70_000
    let wav = correctWAV(frames: frames)
    #expect(PositionEncodedAudio.verify(wav: wav, track: .system, frames: exactly(frames)) == .ok(frames: frames))
}

// MARK: - A dropped frame is caught, and named

@Test
func oneFrameDroppedMidStreamFailsAtItsPosition() {
    // The hole the negative control will provoke through the fake source: frame 100 never reaches
    // disk, so frame 101's samples sit where 100's belong and everything after slides forward.
    var indices = Array(0..<1_000)
    indices.remove(at: 100)
    let wav = positionEncodedWAV(track: .system, frameIndices: indices)

    // The range must admit the short file, or the length check would answer first and the point —
    // that the CONTENT gives the loss away — would go untested.
    let result = PositionEncodedAudio.verify(wav: wav, track: .system, frames: exactly(999))
    #expect(result == .discontinuity(frame: 100, skipped: 1))
}

@Test
func aRunOfDroppedFramesReportsHowManyWentMissing() {
    var indices = Array(0..<1_000)
    indices.removeSubrange(400..<450)
    let wav = positionEncodedWAV(track: .system, frameIndices: indices)
    #expect(PositionEncodedAudio.verify(wav: wav, track: .system, frames: exactly(950))
            == .discontinuity(frame: 400, skipped: 50))
}

@Test
func aDuplicatedFrameIsReportedAsARepeatNotALoss() {
    // The other way a tail can slide. It matters that this is not called a discontinuity: recovery
    // duplicating audio and recovery dropping audio are different bugs, and a file one frame too
    // long would otherwise be described as one frame short.
    var indices = Array(0..<1_000)
    indices.insert(200, at: 201)
    let wav = positionEncodedWAV(track: .system, frameIndices: indices)

    let result = PositionEncodedAudio.verify(wav: wav, track: .system, frames: exactly(1_001))
    #expect(result == .repeated(frame: 201, by: 1))
}

// MARK: - Corruption is caught, and told apart from a loss

@Test
func aCorruptedSampleFails() {
    var wav = correctWAV(frames: 1_000)
    // Frame 500, channel 0 — patch the low byte to a value no position produces there.
    let offset = 44 + 500 * 4
    wav[offset] = wav[offset] ^ 0x01

    let result = PositionEncodedAudio.verify(wav: wav, track: .system, frames: exactly(1_000))
    #expect(result == .wrongValue(frame: 500, channel: 0, expected: 1_500, actual: 1_501))
}

@Test
func corruptionThatMimicsAShiftIsStillNotADiscontinuity() {
    // A single sample nudged by exactly `frameStride` looks, at that one position, like a frame went
    // missing. It is not — the frames after it are still where they belong. This is the confirmation
    // window earning its keep: without it the oracle would mislabel corruption as a clean loss.
    var wav = correctWAV(frames: 1_000)
    let offset = 44 + 300 * 4
    wav[offset] = wav[offset] &+ UInt8(PositionEncodedAudio.stride(for: .system))

    let result = PositionEncodedAudio.verify(wav: wav, track: .system, frames: exactly(1_000))
    #expect(result == .wrongValue(frame: 300, channel: 0, expected: 900, actual: 903))
}

@Test
func corruptionInASecondChannelIsCaughtToo() {
    // Only channel 0 can begin a dropped frame, so a mismatch that starts mid-frame is reported as
    // what it is. Checking every channel is what makes that distinction sound.
    var wav = correctWAV(frames: 1_000)
    let offset = 44 + 700 * 4 + 2 // frame 700, channel 1
    wav[offset] = wav[offset] ^ 0x02

    let result = PositionEncodedAudio.verify(wav: wav, track: .system, frames: exactly(1_000))
    #expect(result == .wrongValue(frame: 700, channel: 1, expected: 2_107, actual: 2_105))
}

// MARK: - The tail rule

@Test
func aTailTruncatedOnAFrameBoundaryIsAcceptedWhenTheRangeAllowsIt() {
    // What a survived `SIGKILL` leaves: a whole-frame prefix of what was emitted. The frames that
    // are there are correct, and the range says how much loss the caller is willing to call success.
    let wav = correctWAV(frames: 900)
    #expect(PositionEncodedAudio.verify(wav: wav, track: .system, frames: 800...1_000) == .ok(frames: 900))
}

@Test
func aTailTruncatedBelowTheGuaranteedPrefixFails() {
    // Below the lower bound the loss is no longer the crash tail — it ate into the closed segments,
    // which are supposed to be guaranteed.
    let wav = correctWAV(frames: 700)
    #expect(PositionEncodedAudio.verify(wav: wav, track: .system, frames: 800...1_000)
            == .shorterThan(expected: 800, actual: 700))
}

@Test
func moreFramesThanWereEverEmittedFails() {
    // The upper bound is the emitted count: audio that was never produced cannot be recovered, so a
    // longer file means duplication somewhere in the pipeline.
    let wav = correctWAV(frames: 1_200)
    #expect(PositionEncodedAudio.verify(wav: wav, track: .system, frames: 800...1_000)
            == .longerThan(expected: 1_000, actual: 1_200))
}

@Test
func aPartialTrailingFrameIsNotCountedAsAFrame() {
    // `kill -9` lands mid-sample. The half-written frame is not audio, and counting it would report
    // corruption where there was only an interrupted write.
    var wav = correctWAV(frames: 500)
    wav.append(contentsOf: [0x11, 0x22]) // half a frame: one channel of the next one
    #expect(PositionEncodedAudio.verify(wav: wav, track: .system, frames: exactly(500)) == .ok(frames: 500))
}

@Test
func anUnfinalisedHeaderIsMeasuredFromTheFileNotFromItsClaim() {
    // A writer killed before `finishWriting` leaves `data` declaring zero while the audio sits right
    // there. The oracle reads the same way recovery does — from what the file holds.
    var wav = correctWAV(frames: 600)
    wav.replaceSubrange(40..<44, with: le32(0)) // the `data` size field
    #expect(PositionEncodedAudio.verify(wav: wav, track: .system, frames: exactly(600)) == .ok(frames: 600))
}

// MARK: - Files the oracle cannot speak about

@Test
func bytesThatAreNotAWAVAreUnreadableRatherThanOK() {
    #expect(PositionEncodedAudio.verify(wav: Data(repeating: 0x41, count: 512), track: .system,
                                        frames: exactly(0)) == .unreadable)
}

@Test
func aFormatTheEncodingIsNotDefinedOverIsRejected() {
    // 8-bit mono is a perfectly valid WAV — just not one whose samples this encoding describes.
    // Verifying it would be checking nothing while reporting success.
    let wav = positionEncodedWAV(track: .system, frameIndices: [0], channels: 1, bitsPerSample: 8)
    #expect(PositionEncodedAudio.verify(wav: wav, track: .system, frames: exactly(1))
            == .unexpectedFormat(bitsPerSample: 8, channels: 1))
}
