import ActaKit
import ActaRuntime
import CoreMedia
import Foundation
import Testing

/// `ActivityAccumulator` — the arithmetic that turns buffers into summaries.
@Suite("Activity accumulator")
struct ActivityAccumulatorTests {
    @Test("nothing is emitted until a whole window has accumulated")
    func aPartialWindowEmitsNothing() {
        var accumulator = ActivityAccumulator(interval: 0.5)
        accumulator.add(meanSquare: 0.01, frameCount: 4_800, duration: 0.1)
        #expect(accumulator.emit() == nil)
        accumulator.add(meanSquare: 0.01, frameCount: 4_800, duration: 0.3)
        #expect(accumulator.emit() == nil)
        accumulator.add(meanSquare: 0.01, frameCount: 4_800, duration: 0.2)
        let emitted = accumulator.emit()
        #expect(emitted != nil)
        #expect(emitted?.duration == 0.6000000000000001 || emitted?.duration == 0.6)
    }

    @Test("a full-scale square wave measures 0 dBFS and half amplitude measures −6")
    func theConversionIsDecibelsRelativeToFullScale() {
        var accumulator = ActivityAccumulator(interval: 0.5)
        accumulator.add(meanSquare: 1.0, frameCount: 1_000, duration: 0.5)
        #expect(abs((accumulator.emit()?.power ?? 0) - 0) < 0.001)

        var half = ActivityAccumulator(interval: 0.5)
        half.add(meanSquare: 0.25, frameCount: 1_000, duration: 0.5)
        #expect(abs((half.emit()?.power ?? 0) + 6.0206) < 0.01)
    }

    @Test("digital zero is the configured floor, not minus infinity")
    func digitalZeroIsFinite() {
        var accumulator = ActivityAccumulator(interval: 0.5, digitalSilenceFloor: -100)
        accumulator.add(meanSquare: 0, frameCount: 1_000, duration: 0.5)
        #expect(accumulator.emit()?.power == -100)
    }

    @Test("one unmeasurable buffer spoils its whole window")
    func aSpoiledWindowCarriesNoNumber() {
        // ⚠️ Averaging the half it understood would report a confident number about audio it never saw.
        var accumulator = ActivityAccumulator(interval: 0.5)
        accumulator.add(meanSquare: 0.5, frameCount: 1_000, duration: 0.25)
        accumulator.spoil(duration: 0.25)
        let emitted = accumulator.emit()
        #expect(emitted != nil)
        #expect(emitted?.power == nil)
        // ...and the next window starts clean rather than inheriting the taint.
        accumulator.add(meanSquare: 1.0, frameCount: 1_000, duration: 0.5)
        #expect(accumulator.emit()?.power == 0)
    }

    @Test("nonsense input is refused rather than averaged in")
    func malformedInputSpoilsInsteadOfCounting() {
        var accumulator = ActivityAccumulator(interval: 0.5)
        accumulator.add(meanSquare: .nan, frameCount: 1_000, duration: 0.25)
        accumulator.add(meanSquare: 1.0, frameCount: 1_000, duration: 0.25)
        #expect(accumulator.emit()?.power == nil)

        var negative = ActivityAccumulator(interval: 0.5)
        negative.add(meanSquare: -1, frameCount: 1_000, duration: 0.5)
        #expect(negative.emit()?.power == nil)

        var zeroFrames = ActivityAccumulator(interval: 0.5)
        zeroFrames.add(meanSquare: 1.0, frameCount: 0, duration: 0.5)
        #expect(zeroFrames.emit()?.power == nil)
    }

    @Test("longer buffers weigh more than shorter ones")
    func energyIsWeightedByFrames() {
        // A loud tenth of a second and a quiet nine tenths should read as mostly quiet.
        var accumulator = ActivityAccumulator(interval: 0.5)
        accumulator.add(meanSquare: 1.0, frameCount: 100, duration: 0.05)
        accumulator.add(meanSquare: 0.0001, frameCount: 900, duration: 0.45)
        let power = accumulator.emit()?.power ?? 0
        // Frame-weighted mean: (100 * 1 + 900 * 0.0001) / 1000 ≈ 0.10009 → about −10 dBFS.
        #expect(abs(power - 10 * log10(0.10009)) < 0.01)
    }

    @Test("a reset drops the partial window instead of carrying it into the next capture")
    func resetDiscardsThePartialWindow() {
        var accumulator = ActivityAccumulator(interval: 0.5)
        accumulator.add(meanSquare: 1.0, frameCount: 1_000, duration: 0.4)
        accumulator.reset()
        #expect(accumulator.isEmpty)
        accumulator.add(meanSquare: 0.0001, frameCount: 1_000, duration: 0.5)
        #expect(abs((accumulator.emit()?.power ?? 0) + 40) < 0.01)
    }
}

/// The meter inside a **real** recording, which is the only place its gate can be proved.
@Suite("Activity meter in the pipeline")
struct AudioActivityMeterPipelineTests {
    private func withTemporaryDirectoryAsync(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-meter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// Wait up to a second for a condition the capture queues will satisfy.
    ///
    /// ⚠️ A bounded wait for the thing, not a yield count: "measure how patient I was" is not a test.
    private func wait(upTo seconds: Double = 1.0, for condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    /// A meter that counts being *asked*, which is the only way the gate itself can be asserted.
    ///
    /// ⚠️ A concrete meter that checks its own flag and returns publishes nothing either way, so a test
    /// over published summaries cannot tell a gated recorder from an ungated one.
    @available(macOS 15.0, *)
    final class TrapMeter: AudioActivityMetering, @unchecked Sendable {
        private let lock = NSLock()
        private var enabled: Bool
        private var calls = 0

        init(enabled: Bool) { self.enabled = enabled }

        var isEnabled: Bool {
            lock.lock(); defer { lock.unlock() }; return enabled
        }
        func setEnabled(_ newValue: Bool) {
            lock.lock(); enabled = newValue; lock.unlock()
        }
        func measure(_ buffer: CMSampleBuffer, track: AudioActivitySummary.Track,
                     generation: UInt64) {
            lock.lock(); calls += 1; lock.unlock()
        }
        func invalidate() {
            lock.lock(); invalidations += 1; lock.unlock()
        }
        private var invalidations = 0
        var callCount: Int {
            lock.lock(); defer { lock.unlock() }; return calls
        }
        var invalidationCount: Int {
            lock.lock(); defer { lock.unlock() }; return invalidations
        }
    }

    /// Counts what the meter was asked to do, and produces no summaries of its own.
    @available(macOS 15.0, *)
    final class CountingMeter: @unchecked Sendable {
        let meter: AudioActivityMeter
        private let lock = NSLock()
        private var summaries: [AudioActivitySummary] = []

        init(enabled: Bool) {
            let box = Box()
            meter = AudioActivityMeter(enabled: enabled, interval: 0.5) { summary in
                box.append(summary)
            }
            self.box = box
        }

        private let box: Box
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [AudioActivitySummary] = []
            func append(_ summary: AudioActivitySummary) {
                lock.lock(); items.append(summary); lock.unlock()
            }
            var all: [AudioActivitySummary] {
                lock.lock(); defer { lock.unlock() }; return items
            }
        }

        var published: [AudioActivitySummary] { box.all }
    }

    @available(macOS 15.0, *)
    @Test("with the reminder on the meter measures both tracks and the recording is unaffected")
    func theEnabledPathMeasuresBothTracks() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let source = FakeCaptureSource()
            let counting = CountingMeter(enabled: true)
            let recorder = AudioRecorder(directory: directory, segmentSeconds: 60,
                                         source: source, permissions: FakePermissions(),
                                         microphone: FakeCaptureMicrophoneResolver(
                                            .pinned(.usbMic(), alternatives: [])),
                                         activityMeter: counting.meter)
            try await recorder.start()
            source.enqueueBatch()
            await recorder.stop()

            let published = counting.published
            #expect(!published.isEmpty)
            #expect(published.contains { $0.track == .microphone })
            #expect(published.contains { $0.track == .system })
            // The fixture emits digital silence, so every measurement should land at the floor rather
            // than at some plausible-looking middle value.
            #expect(published.allSatisfy { ($0.power ?? 0) <= -99 })
            #expect(recorder.writtenBufferCounts.mic > 0)
        }
    }

}

/// The gate itself, asserted by counting the calls the recorder makes.
@Suite("Activity meter gate")
struct AudioActivityMeterGateTests {
    private func withTemporaryDirectoryAsync(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-gate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    @available(macOS 15.0, *)
    private func recorder(_ meter: any AudioActivityMetering,
                          in directory: URL) -> (FakeCaptureSource, AudioRecorder) {
        let source = FakeCaptureSource()
        return (source, AudioRecorder(directory: directory, segmentSeconds: 60,
                                      source: source, permissions: FakePermissions(),
                                      microphone: FakeCaptureMicrophoneResolver(
                                        .pinned(.usbMic(), alternatives: [])),
                                      activityMeter: meter))
    }

    @available(macOS 15.0, *)
    @Test("a switched-off reminder is never asked to measure anything")
    func theDisabledMeterIsNeverCalled() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let meter = AudioActivityMeterPipelineTests.TrapMeter(enabled: false)
            let (source, recorder) = self.recorder(meter, in: directory)
            try await recorder.start()
            source.enqueueBatch()
            await recorder.stop()

            #expect(meter.callCount == 0)
            // The half that makes the first assertion mean something: the recording happened anyway.
            #expect(recorder.writtenBufferCounts.mic > 0)
            #expect(recorder.writtenBufferCounts.system > 0)
        }
    }

    @available(macOS 15.0, *)
    @Test("a switched-on reminder is asked once per buffer")
    func theEnabledMeterSeesEveryBuffer() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let meter = AudioActivityMeterPipelineTests.TrapMeter(enabled: true)
            let (source, recorder) = self.recorder(meter, in: directory)
            try await recorder.start()
            source.enqueueBatch()
            await recorder.stop()

            let received = recorder.receivedBufferCounts
            #expect(meter.callCount == received.system + received.mic)
        }
    }
}
