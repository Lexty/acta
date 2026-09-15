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
    /// A capture restart, a device change or a format change: whatever was accumulated describes audio
    /// that no longer exists.
    func invalidate()
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
    /// The stream format each track was last measured in.
    ///
    /// ⚠️ **A format change is a discontinuity even when capture did not restart.** The sample rate,
    /// the channel count and the sample width all decide what a mean square *means*; a window that spans
    /// a change is a mixture of two different measurements, and a floor learned before it describes a
    /// signal that no longer exists. Nothing outside this class is in a position to notice, because the
    /// format arrives with the buffers.
    private var formats: [AudioActivitySummary.Track: FormatSignature] = [:]
    private let interval: TimeInterval

    /// What has to stay the same for two buffers to belong to one measurement.
    struct FormatSignature: Equatable {
        var sampleRate: Double
        var channels: UInt32
        var bits: UInt32
        var flags: UInt32
    }

    /// The epoch every summary is tagged with.
    ///
    /// ⚠️ **Globally monotonic, and emphatically not the recorder's per-instance generation.** That one
    /// starts at zero in every `AudioRecorder`, so a recording that restarted to generation 3 was
    /// followed by a fresh recorder emitting generation 1 — and a consumer that only adopts rising
    /// numbers would drop the new recording's measurements for ever, silently. A global counter cannot
    /// collide across sessions.
    private var epoch: UInt64
    private static let epochs = EpochCounter()
    private static func mintEpoch() -> UInt64 { epochs.next() }

    /// A monotonic counter, safe to reach from any queue.
    private final class EpochCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 1
        func next() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            defer { value += 1 }
            return value
        }
    }

    public init(enabled: Bool, interval: TimeInterval = 0.5, publish: @escaping Publish) {
        self.enabled = enabled
        self.interval = interval
        self.publish = publish
        self.epoch = Self.mintEpoch()
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
        formats.removeAll()
        // ⚠️ A new epoch, so measurement already under way cannot write its half-finished window back
        // after the switch and be published as current.
        epoch = Self.mintEpoch()
        lock.unlock()
    }

    /// A capture restart, a device change or a format change: the partial windows describe audio that
    /// no longer exists.
    public func invalidate() {
        _ = reserveNextEpoch()
    }

    /// Discard everything accumulated and move to a fresh epoch, returning it.
    ///
    /// ⚠️ **The return value is the point.** A consumer that only learns the new epoch when new data
    /// arrives is defenceless in the gap between the two: a summary queued by the *previous* recording
    /// still carries the epoch the consumer considers current, and warms the successor's estimate before
    /// its first real measurement lands. Reserving lets the consumer refuse that evidence immediately.
    @discardableResult
    public func reserveNextEpoch() -> UInt64 {
        lock.lock()
        accumulators.removeAll()
        formats.removeAll()
        epoch = Self.mintEpoch()
        let reserved = epoch
        lock.unlock()
        return reserved
    }

    /// Measure one buffer. Called synchronously on the capture source's per-track queue.
    public func measure(_ buffer: CMSampleBuffer,
                        track: AudioActivitySummary.Track,
                        generation: UInt64) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        // ⚠️ The epoch is captured **before** the walk and re-checked before the result is stored or
        // published. The walk happens with the lock released, so a `setEnabled(false)` or an
        // `invalidate()` can land in the middle of it; without the fence, the discarded window would be
        // written back afterwards and a quick off-on would publish it as current.
        let startingEpoch = epoch
        var accumulator = accumulators[track] ?? ActivityAccumulator(interval: interval)
        lock.unlock()

        // ⚠️ Checked before anything is accumulated, and it mints a fresh epoch: a partial window from
        // the old format must not be published as belonging to the new one.
        if let signature = Self.signature(of: buffer) {
            lock.lock()
            let previous = formats[track]
            if previous != nil, previous != signature {
                accumulator = ActivityAccumulator(interval: interval)
                accumulators[track] = nil
                epoch = Self.mintEpoch()
            }
            formats[track] = signature
            lock.unlock()
        }

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
        guard enabled, epoch == startingEpoch else {
            lock.unlock()
            return
        }
        accumulators[track] = accumulator
        let tag = epoch
        lock.unlock()

        guard let emitted else { return }
        // ⚠️ Stamped here, on the capture queue, where the audio actually was — and on the monotonic
        // timeline, because the consumer compares this against its own "now" to decide freshness and
        // how long a quiet interval has lasted. Two clocks would make a wall-clock correction look like
        // minutes of silence.
        publish(AudioActivitySummary(track: track, generation: tag,
                                     duration: emitted.duration, power: emitted.power,
                                     observedAt: MonotonicClock.now()))
    }

    /// The format a buffer declares, or `nil` when it declares none this meter can read.
    static func signature(of buffer: CMSampleBuffer) -> FormatSignature? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            return nil
        }
        return FormatSignature(sampleRate: asbd.mSampleRate,
                               channels: asbd.mChannelsPerFrame,
                               bits: asbd.mBitsPerChannel,
                               flags: asbd.mFormatFlags)
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

        // ⚠️ **Only layouts this meter positively decodes.** Endianness, packing and alignment are not
        // decoration: a valid big-endian Int16 buffer read as host-endian yields a confident number
        // about audio that was never there, and a high-aligned or padded layout reads the wrong bytes.
        // Anything else is refused as unmeasurable, which the rule treats as unknown.
        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        let isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let isPacked = flags & kAudioFormatFlagIsPacked != 0
        let isAlignedHigh = flags & kAudioFormatFlagIsAlignedHigh != 0
        let bits = asbd.mBitsPerChannel
        guard !isBigEndian, isPacked, !isAlignedHigh else { return nil }
        guard asbd.mSampleRate.isFinite else { return nil }
        // The stream must describe whole frames of the width it claims.
        let expectedChannels = Int(asbd.mChannelsPerFrame)
        guard expectedChannels > 0, bits == 32 || bits == 16 else { return nil }

        var totalPower = 0.0
        var channelsSeen = 0
        var maximumFrames = 0

        for audioBuffer in UnsafeMutableAudioBufferListPointer(listPointer) {
            // ⚠️ **A missing or empty plane is refused, not skipped.** Skipping it would let a partial
            // channel set become a confident measurement — precisely the "one bad buffer spoils the
            // window" policy, quietly violated at the level below it.
            guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { return nil }
            let interleaved = Int(audioBuffer.mNumberChannels)
            guard interleaved > 0 else { return nil }
            // The plane must hold whole frames of the declared width.
            let bytesPerSample = Int(bits) / 8
            guard bytesPerSample > 0,
                  Int(audioBuffer.mDataByteSize) % (bytesPerSample * interleaved) == 0 else {
                return nil
            }

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

        // Every channel the format promised must have been accounted for.
        guard channelsSeen == expectedChannels, maximumFrames > 0 else { return nil }
        return Measurement(meanSquare: totalPower / Double(channelsSeen),
                           frames: maximumFrames,
                           impliedDuration: Double(maximumFrames) / asbd.mSampleRate)
    }
}

// MARK: - The sink

/// Where a capture's activity summaries go, and the one place the reminder's preference reaches the
/// meter.
///
/// ⚠️ **A shared sink rather than an injected callback, for one reason: lifetimes.** A meter belongs to
/// one capture and is minted per session, several layers below anything that knows a coordinator exists;
/// threading a closure down through `RecordingDependencies`, `RecordingController` and
/// `RecordingSession` would mean every one of them carrying a reference to a feature that can be
/// switched off. The sink is the seam instead, and it is inert until a coordinator registers.
///
/// ⚠️ **Inert by default and off by default.** With nobody registered, or with the preference off,
/// `isWanted` is false, the meter the session builds is disabled, and `AudioRecorder` never calls into
/// it at all.
@available(macOS 15.0, *)
public final class ActivitySink: @unchecked Sendable {
    public static let shared = ActivitySink()

    private let lock = NSLock()
    private var handler: (@Sendable (AudioActivitySummary) -> Void)?
    private var enabled = false
    private weak var currentMeter: AudioActivityMeter?

    private init() {}

    /// Registered by the coordinator, once, for the life of the app.
    public func setHandler(_ handler: (@Sendable (AudioActivitySummary) -> Void)?) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    /// Follows the preference. Applied to the live meter as well as to the next one built.
    public func setEnabled(_ newValue: Bool) {
        lock.lock()
        let changed = enabled != newValue
        enabled = newValue
        let meter = currentMeter
        lock.unlock()
        if changed { meter?.setEnabled(newValue) }
    }

    public var isWanted: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && handler != nil
    }

    /// Revoke whatever the live meter had accumulated and reserve the epoch the next summaries will
    /// carry, so a consumer can refuse everything older at once. Returns `nil` when no meter exists.
    @discardableResult
    public func reserveNextEpoch() -> UInt64? {
        lock.lock(); let meter = currentMeter; lock.unlock()
        return meter?.reserveNextEpoch()
    }

    /// Build the meter for one capture, and remember it so the preference can reach it mid-recording.
    public func makeMeter() -> AudioActivityMeter {
        let meter = AudioActivityMeter(enabled: isWanted) { [weak self] summary in
            guard let handler = self?.currentHandler else { return }
            handler(summary)
        }
        lock.lock(); currentMeter = meter; lock.unlock()
        return meter
    }

    private var currentHandler: (@Sendable (AudioActivitySummary) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return handler
    }
}
