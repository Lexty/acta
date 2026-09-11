import ActaKit
import AVFoundation
import CoreMedia
import Foundation
import os

/// The seam the recorder calls through.
///
/// ⚠️ **It exists so the gate can be *counted*.** With only a concrete meter, a test can observe that a
/// switched-off meter publishes nothing — which is also true of a meter that parses every buffer and
/// throws the answer away. The claim worth making is that the recorder does not call in at all, and only
/// a counting implementation can establish it.
@available(macOS 15.0, *)
public protocol AudioActivityMetering: AnyObject, Sendable {
    /// Whether measuring is wanted. Read once per buffer, so it is a flag and not a question for an
    /// actor.
    var isEnabled: Bool { get }
    /// Measure one buffer. Called synchronously on the capture source's per-track queue.
    func measure(_ buffer: CMSampleBuffer,
                 track: AudioActivitySummary.Track,
                 generation: UInt64)
}

/// Measures how loud each capture track is, coarsely, for the stop reminder.
///
/// ⚠️ **It is a passenger on the recording, never a passenger the recording waits for.** Everything here
/// runs on the capture source's own per-track queue, inside the same call that hands the buffer to the
/// writer; it allocates nothing per buffer beyond one audio buffer list, keeps no audio, starts no
/// tasks, and publishes at most one small value per track per `interval`. If any of that were untrue it
/// would be trading the thing the app exists for against a hint.
///
/// ⚠️ **Gated at the entry point.** With the stop reminder switched off, `isEnabled` is false and the
/// recorder does not call in at all — no format parsing, no sample walk, no publication. The gate is a
/// lock-protected flag rather than a main-actor read precisely because it is consulted per buffer.
@available(macOS 15.0, *)
public final class AudioActivityMeter: AudioActivityMetering, @unchecked Sendable {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "AudioActivityMeter")

    /// Where finished summaries go. Called on the capture queue: it must not block.
    public typealias Publish = @Sendable (AudioActivitySummary) -> Void

    private let publish: Publish
    private let lock = NSLock()
    private var enabled: Bool
    private var accumulators: [AudioActivitySummary.Track: ActivityAccumulator] = [:]
    private let interval: TimeInterval

    public init(enabled: Bool, interval: TimeInterval = 0.5, publish: @escaping Publish) {
        self.enabled = enabled
        self.interval = interval
        self.publish = publish
    }

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    /// Switch measuring on or off while a recording is running.
    ///
    /// ⚠️ **Switching off discards the partial windows.** Re-enabling then starts from a fresh warm-up
    /// rather than resuming an estimate built from audio nobody was allowed to look at in between.
    public func setEnabled(_ newValue: Bool) {
        lock.lock()
        enabled = newValue
        accumulators.removeAll()
        lock.unlock()
    }

    /// A capture restart, a device change or a format change: the partial windows describe audio that
    /// no longer exists.
    public func invalidate() {
        lock.lock()
        accumulators.removeAll()
        lock.unlock()
    }

    /// Measure one buffer. Called synchronously on the capture source's per-track queue.
    public func measure(_ buffer: CMSampleBuffer,
                        track: AudioActivitySummary.Track,
                        generation: UInt64) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        var accumulator = accumulators[track] ?? ActivityAccumulator(interval: interval)
        lock.unlock()

        let duration = CMSampleBufferGetDuration(buffer).seconds
        let span = duration.isFinite && duration > 0 ? duration : 0
        switch Self.meanSquare(of: buffer) {
        case .some(let measurement):
            accumulator.add(meanSquare: measurement.meanSquare,
                            frameCount: measurement.frames,
                            duration: span > 0 ? span : measurement.impliedDuration)
        case .none:
            // ⚠️ Unmeasurable is not quiet. The window is spoiled, the summary will carry `nil`, and the
            // rule treats that as unknown — while the writer, which never consulted any of this, keeps
            // writing.
            accumulator.spoil(duration: span > 0 ? span : interval)
        }

        let emitted = accumulator.emit()
        lock.lock()
        accumulators[track] = accumulator
        let stillEnabled = enabled
        lock.unlock()

        guard stillEnabled, let emitted else { return }
        publish(AudioActivitySummary(track: track, generation: generation,
                                     duration: emitted.duration, power: emitted.power))
    }

    // MARK: - Buffer arithmetic

    struct Measurement {
        var meanSquare: Double
        var frames: Int
        var impliedDuration: TimeInterval
    }

    /// Mean square over the buffer, averaged **across channels as powers**.
    ///
    /// ⚠️ Powers, never signed amplitudes: averaging the channels of an out-of-phase stereo pair before
    /// squaring reports silence for a perfectly loud recording.
    ///
    /// Returns `nil` for anything it does not positively understand — a compressed format, a layout it
    /// cannot walk, an empty buffer. Guessing is what produces a confident number about audio the meter
    /// never saw.
    static func meanSquare(of buffer: CMSampleBuffer) -> Measurement? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mChannelsPerFrame > 0,
              asbd.mSampleRate > 0 else {
            return nil
        }

        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil) == noErr, listSize > 0 else {
            return nil
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize,
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer,
            bufferListSize: listSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer) == noErr else {
            return nil
        }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bits = asbd.mBitsPerChannel

        var totalPower = 0.0
        var channelsSeen = 0
        var maximumFrames = 0

        for audioBuffer in UnsafeMutableAudioBufferListPointer(listPointer) {
            guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }
            let interleaved = Int(audioBuffer.mNumberChannels)
            guard interleaved > 0 else { continue }

            if isFloat, bits == 32 {
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                let samples = data.bindMemory(to: Float.self, capacity: count)
                var sum = 0.0
                for index in 0..<count {
                    let value = Double(samples[index])
                    sum += value * value
                }
                totalPower += sum / Double(count) * Double(interleaved)
                channelsSeen += interleaved
                maximumFrames = max(maximumFrames, count / interleaved)
            } else if isSignedInteger, bits == 16 {
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                guard count > 0 else { continue }
                let samples = data.bindMemory(to: Int16.self, capacity: count)
                var sum = 0.0
                let scale = Double(Int16.max)
                for index in 0..<count {
                    let value = Double(samples[index]) / scale
                    sum += value * value
                }
                totalPower += sum / Double(count) * Double(interleaved)
                channelsSeen += interleaved
                maximumFrames = max(maximumFrames, count / interleaved)
            } else {
                // A layout this meter does not positively understand.
                return nil
            }
        }

        guard channelsSeen > 0, maximumFrames > 0 else { return nil }
        return Measurement(meanSquare: totalPower / Double(channelsSeen),
                           frames: maximumFrames,
                           impliedDuration: Double(maximumFrames) / asbd.mSampleRate)
    }
}
