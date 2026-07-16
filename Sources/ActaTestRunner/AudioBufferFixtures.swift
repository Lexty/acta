import AVFoundation
import CoreMedia
import Foundation

// Real `CMSampleBuffer`s for the capture tests. Real, and not a stand-in type: `CMSampleBuffer` is
// the seam `AudioRecorder` and `SegmentWriter` are built on, and it carries the format description
// and the presentation timestamp that drive segment rotation and WAV creation. A fake that produced
// anything else would move the boundary to the wrong place and leave all of that untested.

/// The audio format of a fixture buffer.
///
/// 48 kHz stereo, because it is **a supported, realistic format** — deliberately not "the format
/// production uses": `SCStreamConfiguration` asks for a sample rate and a channel count, it does not
/// promise a PCM layout, so claiming a match would be claiming something we cannot know.
/// `interleaved` exists for the same reason: CoreMedia format variation is exactly where fake-only
/// confidence fails, so the non-interleaved layout gets exercised too.
struct FixtureAudioFormat {
    var sampleRate: Double = 48_000
    var channels: AVAudioChannelCount = 2
    var interleaved = true

    /// 48 kHz stereo, interleaved 16-bit — what `SegmentWriter` ultimately writes into a WAV.
    static let stereo48k = FixtureAudioFormat()
    /// The same rate and channel count in a non-interleaved layout: a different `AudioBufferList`
    /// shape (one buffer per channel rather than one for both), which is what makes it worth testing.
    static let stereo48kNonInterleaved = FixtureAudioFormat(interleaved: false)

    var avFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                      channels: channels, interleaved: interleaved)
    }
}

/// Build one PCM audio `CMSampleBuffer` of `frames` frames, presented at `pts`.
///
/// The sample data is silence: a tone would buy nothing here — no test in this suite listens to the
/// audio, and a generator that could produce arbitrary waveforms at an arbitrary cadence is the
/// parked deterministic-oracle work, not this.
///
/// On the backing memory, which is the trap: `CMSampleBufferSetDataBufferFromAudioBufferList` copies
/// the samples into a block buffer it allocates itself, so the returned buffer does **not** point
/// into the `AVAudioPCMBuffer` below. That is what makes it safe for the local `pcm` to die at the
/// end of this function — with a flag that made the block buffer wrap the memory instead, every
/// fixture buffer would be a use-after-free the moment it left this scope.
func makeAudioSampleBuffer(pts: CMTime, frames: AVAudioFrameCount = 1_024,
                           format: FixtureAudioFormat = .stereo48k) -> CMSampleBuffer? {
    guard let avFormat = format.avFormat,
          let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frames) else { return nil }
    pcm.frameLength = frames

    var asbd = avFormat.streamDescription.pointee
    var formatDescription: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                         layoutSize: 0, layout: nil,
                                         magicCookieSize: 0, magicCookie: nil,
                                         extensions: nil,
                                         formatDescriptionOut: &formatDescription) == noErr,
          let formatDescription else { return nil }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
        presentationTimeStamp: pts,
        decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                               makeDataReadyCallback: nil, refcon: nil,
                               formatDescription: formatDescription,
                               sampleCount: CMItemCount(frames),
                               sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                               sampleSizeEntryCount: 0, sampleSizeArray: nil,
                               sampleBufferOut: &sampleBuffer) == noErr,
          let sampleBuffer else { return nil }

    guard CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer,
                                                         blockBufferAllocator: kCFAllocatorDefault,
                                                         blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                         flags: 0,
                                                         bufferList: pcm.audioBufferList) == noErr,
          CMSampleBufferSetDataReady(sampleBuffer) == noErr else { return nil }
    return sampleBuffer
}
