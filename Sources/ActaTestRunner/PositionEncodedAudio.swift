import Foundation
import ActaKit

/// Deterministic, position-encoding PCM: every sample's value is a pure function of *where* it sits
/// — which track, which absolute frame, which channel — and an oracle that checks a finished WAV
/// against that function, frame by frame.
///
/// Why it exists. The fixture buffers `makeAudioSampleBuffer` produces are silence, and silence
/// proves nothing about crash recovery: a recovered file full of zeros decodes perfectly whether or
/// not a frame was lost, so "it decodes" would rubber-stamp a broken pipeline. Encode the position
/// into the sample itself and a dropped, duplicated or corrupted frame becomes a value that does not
/// match its own address — `verify` finds the first one and names it.
///
/// It lives in the test runner, not in `ActaKit`: nothing the app ships needs it, and the harness
/// that will use it (the child process of the crash scenario) is this same binary re-invoked.
///
/// The specification, in full — the generator and the oracle are two readings of exactly this:
///
/// - **Sample format**: signed 16-bit **little-endian** PCM, which is what `SegmentWriter` writes.
///   The channel layout is not assumed: `sample` is defined per channel index, and `verify` reads
///   the channel count out of the file's own `fmt ` chunk rather than presuming stereo.
/// - **The formula**:
///   `sample(track, frameIndex, channel) = Int16(truncatingIfNeeded: frameIndex * stride(track) + channel * 7 + salt(track))`,
///   with `stride(.system) == 3`, `stride(.mic) == 5`, `salt(.system) == 0` and `salt(.mic) == 1361`.
///   All arithmetic wraps (`&*`, `&+`) and the `Int16` conversion keeps the low 16 bits. Nothing
///   clamps or saturates — every `Int16` value, the extremes included, is a legitimate sample.
/// - **Overflow / wrap**, stated because it bounds what the oracle can catch: the encoding repeats
///   every 65536 frames (~1.37 s at 48 kHz). Both strides are odd, hence coprime to 2^16, and that
///   is the point — a shift of *k* frames changes every value unless *k* is a multiple of 65536, so
///   a single dropped frame is always caught, while a loss of exactly 65536 frames would be
///   invisible to a value check. Length is checked separately (`shorterThan` / `longerThan`), so
///   such a loss cannot slip past both.
/// - **Track separation**: the tracks differ by more than a constant. A salt alone would not be
///   enough — both tracks would be linear in the frame index with the same slope, so the mic track
///   would be, exactly, the system track shifted by 22299 frames, and the oracle would report mic
///   audio in the system track as a *discontinuity* while cheerfully confirming the values. Distinct
///   strides make one track unreachable from the other by any shift, so the mismatch is named for
///   what it is.
enum PositionEncodedAudio {
    /// How much the value moves per frame. Odd on purpose (the wrap note above), and per track (the
    /// track-separation note above).
    static func stride(for track: Track) -> Int {
        switch track {
        case .system: return 3
        case .mic: return 5
        }
    }

    /// How much the value moves per channel, so a channel swap reads as a mismatch.
    static let channelStride = 7

    /// A per-track constant, so the two tracks disagree from frame zero rather than only once the
    /// strides have pulled them apart.
    static func salt(for track: Track) -> Int {
        switch track {
        case .system: return 0
        case .mic: return 1361
        }
    }

    /// The single definition of what belongs at a position. The generator writes it, the oracle
    /// expects it; there is no second copy of the formula anywhere.
    static func sample(track: Track, frameIndex: Int, channel: Int) -> Int16 {
        let value = frameIndex &* stride(for: track) &+ channel &* channelStride &+ salt(for: track)
        return Int16(truncatingIfNeeded: value)
    }

    /// What `verify` found.
    ///
    /// A returned value rather than an assertion, deliberately: the negative control has to read the
    /// failure and check it is the *specific* one expected. An inner `#expect` failure is not
    /// something an outer test can catch, so an oracle that asserted internally could only ever be
    /// trusted, never tested.
    enum Verification: Equatable, Sendable {
        /// Every frame in the file matched its own position.
        case ok(frames: Int)
        /// Not a WAV whose `data` chunk can be located at all.
        case unreadable
        /// A WAV, but not the 16-bit PCM the encoding is defined over.
        case unexpectedFormat(bitsPerSample: Int, channels: Int)
        /// Fewer whole frames than the caller allowed.
        case shorterThan(expected: Int, actual: Int)
        /// More whole frames than the caller allowed.
        case longerThan(expected: Int, actual: Int)
        /// The value at `frame` is the one belonging to a frame `skipped` positions later: audio
        /// went missing here and everything after it slid forward.
        case discontinuity(frame: Int, skipped: Int)
        /// The tail slid *backwards* by `by` frames from `frame` on: audio was repeated rather than
        /// lost. A distinct case because it is a distinct fault, and because the arithmetic cannot
        /// honestly call it a discontinuity — under the wrap, a repeat of one frame and a skip of
        /// 65535 are the same delta, and only the sign convention decides which is meant.
        case repeated(frame: Int, by: Int)
        /// The value at `frame`/`channel` belongs to no position reachable by a clean shift —
        /// corruption rather than a loss or a repeat.
        case wrongValue(frame: Int, channel: Int, expected: Int16, actual: Int16)
    }

    /// Check a finished WAV against the encoding: does every frame hold what its position says it
    /// should, and is the file's length inside `frames`?
    ///
    /// **How the PCM is read**: by parsing the `data` chunk directly (through `WAV.layout`, the same
    /// parser recovery trusts) rather than decoding via `AVAudioFile`. The oracle then stays a pure
    /// function of bytes — no file system, no CoreAudio, no format conversion between the writer and
    /// the check — and a test can hand it a file made of literal bytes.
    ///
    /// **Chunk offset and padding**: audio starts at the `data` chunk's body offset. Its length is
    /// what the header declares when the header declares anything, bounded by what the file actually
    /// holds; when the declared size is zero — a writer killed before it finalised — everything from
    /// the body offset to the end of the file is audio. RIFF's even-boundary pad byte and any chunk
    /// after `data` fall outside that length and are never read. A trailing **partial** frame is not
    /// a frame: `kill -9` lands mid-sample and the repair cuts back to whole frames, so counting it
    /// would report corruption where there was only an unfinished write.
    ///
    /// **The tail rule** lives in `frames`, the caller's range of acceptable lengths. A tail
    /// truncated on a whole-frame boundary is accepted exactly when what survives still reaches
    /// `frames.lowerBound` — the crash scenario passes the closed segments' guaranteed prefix as the
    /// lower bound and the emitted-frame count as the upper.
    static func verify(wav: Data, track: Track, frames acceptable: ClosedRange<Int>) -> Verification {
        guard let layout = WAV.layout(wav) else { return .unreadable }
        let format = layout.format
        guard format.bitsPerSample == 16, format.channels > 0,
              format.blockAlign == format.channels * 2 else {
            return .unexpectedFormat(bitsPerSample: format.bitsPerSample, channels: format.channels)
        }

        let bytes = [UInt8](wav)
        let available = max(0, bytes.count - layout.dataBodyOffset)
        let dataSize = layout.declaredDataSize > 0
            ? min(layout.declaredDataSize, available)
            : available
        let scan = Scan(bytes: bytes, layout: layout, track: track,
                        frameCount: dataSize / format.blockAlign)

        if scan.frameCount < acceptable.lowerBound {
            return .shorterThan(expected: acceptable.lowerBound, actual: scan.frameCount)
        }
        if scan.frameCount > acceptable.upperBound {
            return .longerThan(expected: acceptable.upperBound, actual: scan.frameCount)
        }
        return scan.firstFault() ?? .ok(frames: scan.frameCount)
    }

    // MARK: - Private

    /// One file's audio, already located and measured — the state every step of the check needs, so
    /// that none of them has to be handed it a piece at a time.
    private struct Scan {
        let bytes: [UInt8]
        let layout: WAV.Layout
        let track: Track
        let frameCount: Int

        /// The first position that does not hold what it should, described; `nil` if none does.
        func firstFault() -> Verification? {
            for frame in 0..<frameCount {
                for channel in 0..<layout.format.channels {
                    let expected = sample(track: track, frameIndex: frame, channel: channel)
                    let actual = value(frame: frame, channel: channel)
                    guard actual != expected else { continue }
                    return classify(frame: frame, channel: channel, expected: expected, actual: actual)
                }
            }
            return nil
        }

        /// Tell a clean shift from corruption at the first mismatching position.
        ///
        /// Only a channel-0 mismatch can begin a shifted tail: a frame that vanished (or repeated)
        /// moves the whole tail, so the discrepancy shows up on that frame's very first sample. A
        /// mismatch that starts mid-frame is something else, and naming it a shift would be a guess.
        private func classify(frame: Int, channel: Int, expected: Int16, actual: Int16) -> Verification {
            let corrupted = Verification.wrongValue(frame: frame, channel: channel,
                                                    expected: expected, actual: actual)
            guard channel == 0 else { return corrupted }

            // `actual == sample(frame + k)` means the value moved by `k * stride` (mod 2^16). The
            // stride is odd, hence invertible mod 2^16, so `k` follows from the delta directly — one
            // candidate to check, not a search. Read as signed, because a tail can slide either way:
            // forward is loss, backward is repetition.
            let delta = (Int(actual) &- Int(expected)) & 0xFFFF
            let magnitude = (delta &* strideInverse(for: track)) & 0xFFFF
            let shift = magnitude > 0x8000 ? magnitude - 0x10000 : magnitude
            guard shift != 0, shiftHolds(from: frame, by: shift) else { return corrupted }
            return shift > 0 ? .discontinuity(frame: frame, skipped: shift)
                             : .repeated(frame: frame, by: -shift)
        }

        /// Does the candidate shift explain the frames that follow, or did the delta merely happen
        /// to factor? One position agreeing is arithmetic; a run of them agreeing across every
        /// channel is a real shift. Without this, a single corrupted sample that landed a multiple of
        /// the stride away would be misreported as a clean loss.
        private func shiftHolds(from frame: Int, by shift: Int) -> Bool {
            let end = min(frame + confirmationFrames, frameCount)
            for f in frame..<end {
                for channel in 0..<layout.format.channels
                where value(frame: f, channel: channel)
                    != sample(track: track, frameIndex: f + shift, channel: channel) {
                    return false
                }
            }
            return true
        }

        /// The little-endian signed 16-bit sample at a position — interleaved, frame-major, as the
        /// `data` chunk of a PCM WAV always is.
        private func value(frame: Int, channel: Int) -> Int16 {
            let offset = layout.dataBodyOffset + frame * layout.format.blockAlign + channel * 2
            guard offset + 2 <= bytes.count else { return 0 }
            return Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
        }
    }

    /// How many frames past the mismatch a candidate shift must keep explaining before it is
    /// reported as a shift rather than corruption.
    private static let confirmationFrames = 8

    /// The multiplicative inverse of the track's stride mod 2^16 — what turns a value delta back
    /// into a frame delta. `3 * 43691 == 1` and `5 * 52429 == 1`, both mod 2^16.
    private static func strideInverse(for track: Track) -> Int {
        switch track {
        case .system: return 43_691
        case .mic: return 52_429
        }
    }
}
