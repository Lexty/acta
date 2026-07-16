import ActaKit
import ActaRuntime
import CoreMedia
import Foundation
import Testing

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
@available(macOS 15.0, *)
func assertFailedStartContract(_ source: CaptureSource, label: String) async {
    await #expect(throws: StartupFailure.streamNotStarted, "\(label): a failed start did not map to .streamNotStarted") {
        try await source.start()
    }
    #expect(source.isStreaming == false, "\(label): isStreaming stayed true after a failed start()")
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

        try await source.start()
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

        try await source.start()
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

        try await source.start()
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

        try await source.start()
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

        try await source.start()
        let old = source.currentStreamToken
        // What a restart does: the old stream goes away and a new one takes its place.
        await source.stop()
        try await source.start()
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
    @Test
    @available(macOS 15.0, *)
    func baseContract() async {
        await assertCaptureSourceBaseContract(SCKCaptureSource(), label: "SCKCaptureSource")
    }

    @Test
    @available(macOS 15.0, *)
    func aStartThatCannotReachADisplayMapsToStreamNotStarted() async {
        // Gated on the permission, and read with the preflight call, which does not prompt. Without
        // screen-recording access `SCShareableContent` cannot hand back a display, so the real start
        // takes exactly the failure path this asserts. With access granted it would instead bring a
        // real capture up — which is a live recording, not a unit test, and not something this runner
        // should start behind the user's back.
        guard !SystemPermissions().hasScreenRecording else { return }
        await assertFailedStartContract(SCKCaptureSource(), label: "SCKCaptureSource")
    }
}
