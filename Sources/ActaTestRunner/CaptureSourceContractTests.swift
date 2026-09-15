import ActaKit
import ActaRuntime
import CoreMedia
import Foundation
import Testing


// ⚠️ **What this contract does not reach, since Task 5 added a parameter to `start`.**
// `microphoneDeviceID` is checked here only for being *passed through*: `FakeCaptureSource` accepts
// any string, records it, and can be scripted to refuse one. Whether `SCKCaptureSource` accepts a
// given uid — and whether the resulting stream records from **that** microphone rather than the system
// default — is unverified in-process, for the same reason its teardown is: it needs a live `SCStream`,
// a TCC-authorised build, an audio device and a human listening to the result. A uid ScreenCaptureKit
// rejects is as broken as one it misroutes, and neither shows up here. Both are in the plan's manual
// section.

// The `CaptureSource` contract, as tests.
//
// This is what makes the fake worth anything. A fake that quietly delivers on the test thread, or
// keeps calling back after `stop()`, is not a cheaper `SCKCaptureSource` — it is a different one,
// and every conclusion drawn through it is about code that does not ship. So the contract is written
// once and asserted, rather than described in a doc comment and hoped for.
//
// What is asked of which implementation, and why the split is not laziness:
//
// * **The fake** answers all of it, delivery included: only a source whose emissions a test can
//   script can be asked "did anything arrive after stop returned?".
// * **The real source** answers the named subset that needs neither TCC nor a successful start —
//   `isStreaming` before a start, the failure mapping, and a `stop()` with nothing to stop. Anything
//   past that needs a live `SCStream`, i.e. screen-recording access and a display, which this runner
//   has neither of. Demanding it here would leave only bad options: fake the test, delete it, or
//   reopen the extraction. The two-stream identity guarantee in particular is fake-only **by
//   design** — reproducing it for real means two successfully created streams plus an injected
//   delayed delegate failure. For `SCKCaptureSource` that guarantee is covered by review of the
//   moved code, not by a test that cannot run.

// MARK: - The reusable part

/// The part of the contract every implementation must satisfy and any of them can be asked about
/// with no capture running at all.
@available(macOS 15.0, *)
func assertCaptureSourceBaseContract(_ source: CaptureSource, label: String) async {
    #expect(source.isStreaming == false, "\(label): isStreaming was true before start()")
    // Nothing to stop is not an error: every failure path calls `stop()`, including ones that never
    // reached a start.
    await source.stop()
    #expect(source.isStreaming == false, "\(label): stop() before start() left isStreaming true")
}

/// A `start()` that cannot bring capture up must surface as `.streamNotStarted` — the one failure
/// `SelfCheck` spends its restart attempts on. Any other error, raw or mapped, silently turns a
/// healable failure into a fatal one.
///
/// It must also leave the delivery gate shut. Both implementations open the gate *before* the call
/// that can fail (a start must never drop the first buffer), so "the start threw" and "nothing can
/// arrive" are two separate claims — and a buffer from a stream that reported failure would land in
/// a writer that `AudioRecorder.restart()` is concurrently finalizing.
@available(macOS 15.0, *)
func assertFailedStartContract(_ source: CaptureSource, label: String) async {
    let delivered = Delivered()
    source.setBufferHandler { _, _ in delivered.record() }
    await #expect(throws: StartupFailure.streamNotStarted, "\(label): a failed start did not map to .streamNotStarted") {
        try await source.start(microphoneDeviceID: "BuiltInMicrophoneDevice")
    }
    #expect(source.isStreaming == false, "\(label): isStreaming stayed true after a failed start()")
    // Give a straggler from a partially-started stream every chance to appear; none may.
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(delivered.count == 0, "\(label): a failed start() delivered a buffer — the gate was left open")
}

/// A thread-safe delivery counter: the handler runs on the source's own queues, so the test's
/// bookkeeping needs its own lock.
private final class Delivered: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = 0

    func record() { lock.lock(); delivered += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return delivered }
}

// MARK: - Against the fake: the whole contract

@Suite
struct FakeCaptureSourceContractTests {
    @Test
    @available(macOS 15.0, *)
    func baseContract() async {
        await assertCaptureSourceBaseContract(FakeCaptureSource(), label: "fake")
    }

    @Test
    @available(macOS 15.0, *)
    func failedStartMapsToStreamNotStarted() async {
        let source = FakeCaptureSource()
        source.failAllStarts()
        await assertFailedStartContract(source, label: "fake")
    }

    @Test
    @available(macOS 15.0, *)
    func deliveryIsOrderedPerTrack() async throws {
        let source = FakeCaptureSource()
        let recorded = Recorded()
        source.setBufferHandler { track, buffer in
            recorded.append(track, CMSampleBufferGetPresentationTimeStamp(buffer))
        }

        try await source.start(microphoneDeviceID: "BuiltInMicrophoneDevice")
        source.emitBatch()
        source.emitBatch()
        await source.stop()

        for track in Track.allCases {
            let stamps = recorded.timestamps(for: track)
            #expect(stamps.count == 9, "\(track.title): expected three batches of three buffers")
            #expect(stamps == stamps.sorted { CMTimeCompare($0, $1) < 0 },
                    "\(track.title): buffers arrived out of order — the writer would see a rewound timeline")
        }
    }

    @Test
    @available(macOS 15.0, *)
    func nothingIsDeliveredAfterAnAwaitedStop() async throws {
        let source = FakeCaptureSource()
        let recorded = Recorded()
        source.setBufferHandler { track, buffer in
            recorded.append(track, CMSampleBufferGetPresentationTimeStamp(buffer))
        }

        try await source.start(microphoneDeviceID: "BuiltInMicrophoneDevice")
        source.emitBatch()
        await source.stop()
        let atStop = recorded.count

        // A stopped source that is asked for more must produce none of it: `AudioRecorder` finalizes
        // its writers the instant `stop()` returns, and a late buffer there deletes the segment being
        // closed — the tail of the recording, silently replaced by a stub.
        source.emitBatch()
        #expect(recorded.count == atStop, "the source delivered after an awaited stop()")
    }

    @Test
    @available(macOS 15.0, *)
    func stopDrainsAnAlreadyQueuedDeliveryBeforeReturning() async throws {
        let source = FakeCaptureSource()
        let recorded = Recorded()
        source.setBufferHandler { track, buffer in
            recorded.append(track, CMSampleBufferGetPresentationTimeStamp(buffer))
        }

        try await source.start(microphoneDeviceID: "BuiltInMicrophoneDevice")
        // Enqueued and deliberately not waited for: this is the callback that is mid-flight when the
        // caller decides to stop. `stop()` owes two things here — it must let the in-flight callback
        // finish (the drain) and it must swallow the rest (the gate). Draining alone would leave the
        // window the real `SCStream` shows in practice: `stopCapture()` does not stop the callbacks.
        source.enqueueBatch(count: 64)
        await source.stop()
        let atStop = recorded.count

        // Whatever the drain let through, it happened *before* stop() returned. Give any straggler
        // every chance to appear; none may.
        source.drain()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorded.count == atStop,
                "a delivery landed after stop() returned — it would append into a writer being finalized")
    }

    @Test
    @available(macOS 15.0, *)
    func isStreamingReflectsAnAsynchronousFailureNotMerelyWhetherStartReturned() async throws {
        let source = FakeCaptureSource()

        try await source.start(microphoneDeviceID: "BuiltInMicrophoneDevice")
        #expect(source.isStreaming, "a successful start() left isStreaming false")

        // The stream dies on its own, long after start() returned. If `isStreaming` kept saying
        // "true", the self-diagnosis would explain a dead capture to the user as a broken audio
        // device and never restart the stream.
        source.failStreamAsynchronously()
        #expect(source.isStreaming == false, "isStreaming survived an asynchronous stream failure")

        await source.stop()
    }

    @Test
    @available(macOS 15.0, *)
    func aDelayedFailureFromAnOldStreamDoesNotClearItsReplacement() async throws {
        let source = FakeCaptureSource()

        try await source.start(microphoneDeviceID: "BuiltInMicrophoneDevice")
        let old = source.currentStreamToken
        // What a restart does: the old stream goes away and a new one takes its place.
        await source.stop()
        try await source.start(microphoneDeviceID: "BuiltInMicrophoneDevice")
        let replacement = source.currentStreamToken
        #expect(replacement != old, "the restart reused the old stream's identity")

        // The old stream's failure arrives late — after the restart already succeeded. Acting on it
        // would tear down a capture that is working, and the self-diagnosis would restart a stream
        // that never broke.
        source.failStream(old)
        #expect(source.isStreaming, "a dead stream's delayed failure took its replacement down with it")

        // ...while the live stream's own failure must still land.
        source.failStream(replacement)
        #expect(source.isStreaming == false, "the live stream's failure was ignored")
    }
}

/// Thread-safe record of what the handler was called with. The handler runs on the source's two
/// queues, so the test's own bookkeeping needs its own lock — anything less is the data race the
/// contract exists to make visible.
private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [Track: [CMTime]] = [:]

    func append(_ track: Track, _ pts: CMTime) {
        lock.lock()
        stamps[track, default: []].append(pts)
        lock.unlock()
    }

    func timestamps(for track: Track) -> [CMTime] {
        lock.lock()
        defer { lock.unlock() }
        return stamps[track] ?? []
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stamps.values.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Against the real source: the named subset only

@Suite
struct SCKCaptureSourceContractTests {
    // Only the contract that touches no capture: `isStreaming` before a start, and that a `stop()`
    // with nothing to stop is a no-op. Both read state without ever calling `start()`, so neither
    // prompts for anything.
    @Test
    @available(macOS 15.0, *)
    func baseContract() async {
        await assertCaptureSourceBaseContract(SCKCaptureSource(), label: "SCKCaptureSource")
    }

    // The real source's *failed-start* mapping (raw ScreenCaptureKit error -> `StartupFailure`) is
    // deliberately NOT exercised here. It once was, gated on "screen recording denied" on the
    // assumption that `SCShareableContent` then returns no display and `start()` short-circuits before
    // `startCapture()`. That assumption is false on macOS 26: the display is handed back, `start()`
    // reaches `startCapture()`, and the microphone TCC prompt fires — in the user's face, from a test
    // run. There is no way to drive the real `start()` to its failure path without that side effect,
    // so the failure-mapping contract is covered against the fake (`assertFailedStartContract` in
    // `FakeCaptureSourceContractTests`), and the real source's start path is proven only by live
    // recording. See docs/backlog.
}
