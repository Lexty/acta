import ActaKit
import ActaRuntime
import Foundation
import Testing

/// What `pmset -g assertions` currently reports.
private func pmsetAssertions() -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    proc.arguments = ["-g", "assertions"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    // Read before waiting: `pmset` output is small, but a pipe that fills while we block in
    // `waitUntilExit()` deadlocks, and a test that hangs forever is worse than one that fails.
    guard (try? proc.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Whether the OS reports *this process's* assertion, by the exact reason string a human would read.
///
/// Scoped to our own pid on purpose. `pmset -g assertions` lists every process on the machine under
/// "Listed by owning process" (`pid 7922(Safari): [0x...] PreventUserIdleDisplaySleep named: "..."`),
/// and `DisplayWakeLock.reason` is flavor-agnostic — the string a real `Acta.app` publishes while
/// recording is byte-identical to ours. An unscoped grep therefore turns "the app is recording on
/// this machine" — the normal state, and the very thing Task 10 exists to sustain for hours — into a
/// suite-wide failure blaming code that is innocent. `.serialized` cannot help: the interference is
/// cross-process.
private func systemHoldsActaAssertion() -> Bool {
    let pid = ProcessInfo.processInfo.processIdentifier
    return pmsetAssertions()
        .split(separator: "\n")
        .contains { $0.contains("pid \(pid)(") && $0.contains(DisplayWakeLock.reason) }
}

/// A lock whose `beginActivity`/`endActivity` calls are counted instead of made.
private final class CountingActivity {
    private let lock = NSLock()
    private var begun = 0
    private var ended = 0

    var beginCount: Int { lock.withLock { begun } }
    var endCount: Int { lock.withLock { ended } }

    func makeWakeLock() -> DisplayWakeLock {
        DisplayWakeLock(
            begin: { _ in
                self.lock.withLock { self.begun += 1 }
                return NSObject()
            },
            end: { _ in self.lock.withLock { self.ended += 1 } })
    }
}

// Task 10: the display must stay awake for exactly the span of a recording — no longer.
//
// These tests ask the operating system, not the object: `DisplayWakeLock.isHeld` returning `false`
// proves nothing about whether the assertion the kernel is holding actually went away, and a leaked
// assertion is invisible until someone notices their Mac has not slept for a week. `pmset -g
// assertions` is the same thing a human would run to answer "what is keeping this Mac awake?", so it
// is what the test runs.
//
// The honest limit of that, verified rather than assumed: the token from `beginActivity` ends its own
// activity when it deallocates. So `pmset` can prove the assertion was *taken*, but it cannot tell a
// proper `endActivity` from a dropped token — every "it went away" check below passes against a
// `release()` with its `endActivity` deleted. The two tests that count calls through the injected
// seam cover what `pmset` structurally cannot, and neither approach is sufficient alone: the counting
// tests would keep passing if the real API stopped behaving as we assume, which is what the live
// `pmset` tests are for.
//
// `.serialized`: an assertion is process-global state, and swift-testing runs tests in parallel by
// default — one test's `acquire()` would be seen by another's "nothing is held" check. The suite is
// the only place in the runner that touches assertions, so serializing it internally is enough.
@Suite(.serialized)
struct DisplayWakeLockTests {
    @Test
    func wakeLockIsNotHeldUntilAcquired() {
        let lock = DisplayWakeLock()
        #expect(lock.isHeld == false)
        // "Never hold it while idle": constructing the lock must not pin the display on. Only a
        // recording may.
        #expect(systemHoldsActaAssertion() == false)
    }

    @Test
    func acquireMakesTheAssertionVisibleToTheSystemAndReleaseRemovesIt() {
        let lock = DisplayWakeLock()

        lock.acquire()
        #expect(lock.isHeld)
        #expect(systemHoldsActaAssertion(),
                "pmset does not list the assertion — the display would sleep and take the capture with it")

        lock.release()
        #expect(lock.isHeld == false)
        #expect(systemHoldsActaAssertion() == false,
                "the assertion outlived the recording — the machine would never sleep again")
    }

    @Test
    func reasonNamesTheAppSoAHumanCanTellWhatIsHoldingTheDisplayOn() {
        // This string is the entire user-facing surface of the feature: it is what
        // `pmset -g assertions` prints when someone asks why their Mac will not sleep.
        #expect(DisplayWakeLock.reason.contains(AppInfo.name))
        #expect(DisplayWakeLock.reason.contains("recording"))
    }

    @Test
    func acquireIsIdempotentSoAWatchdogRestartCannotStackAssertions() {
        let lock = DisplayWakeLock()

        // The watchdog restarts the stream in place (2–3 attempts) without ending the recording. If
        // each restart took a fresh assertion, one `release()` on stop would leave the rest held
        // forever.
        lock.acquire()
        lock.acquire()
        lock.acquire()
        #expect(lock.isHeld)
        #expect(systemHoldsActaAssertion())

        lock.release()
        #expect(lock.isHeld == false)
        #expect(systemHoldsActaAssertion() == false,
                "three acquires needed more than one release — the assertion stacked")
    }

    @Test
    func releaseIsIdempotentAndSafeWithoutAnAcquire() {
        let lock = DisplayWakeLock()

        // Every exit path releases — a failed start, a clean stop, the watchdog giving up — and they
        // overlap. A double release must not trip over the already-ended token.
        lock.release()
        lock.acquire()
        lock.release()
        lock.release()
        #expect(lock.isHeld == false)
        #expect(systemHoldsActaAssertion() == false)
    }

    @Test
    func reacquireAfterReleaseWorks() {
        // A second recording in the same process must hold the display again — the lock is per
        // session, and `RecordingSession` builds a new one each time, but the object must not be
        // single-use.
        let lock = DisplayWakeLock()
        lock.acquire()
        lock.release()
        lock.acquire()
        #expect(lock.isHeld)
        #expect(systemHoldsActaAssertion())
        lock.release()
        #expect(systemHoldsActaAssertion() == false)
    }

    @Test
    func aDroppedLockDoesNotLeakTheAssertion() {
        // A `RecordingSession` released while it still holds the lock must not leave the machine
        // awake. The kernel would clean up when the process dies, but Acta is a menu-bar app that
        // runs for days — "it goes away on quit" is not a defence.
        //
        // Counted, not observed through `pmset`: the token ends its own activity when it deallocates,
        // so the OS shows the assertion gone whether `deinit` did its job or did nothing at all. Only
        // the call count can tell an empty `deinit` from a correct one.
        let activity = CountingActivity()
        do {
            let lock = activity.makeWakeLock()
            lock.acquire()
            #expect(activity.beginCount == 1)
            #expect(activity.endCount == 0)
        }
        #expect(activity.endCount == 1,
                "deinit did not end the activity — the assertion leaked with the object")
    }

    @Test
    func releaseEndsTheActivityRatherThanMerelyDroppingTheToken() {
        // `endActivity` is the documented counterpart of `beginActivity`, and the `pmset` tests above
        // cannot see it: dropping the token deallocates it, which ends the activity by itself, so
        // `release()` would look correct even with the `endActivity` call deleted. This is the one
        // test that fails if it is.
        let activity = CountingActivity()
        let lock = activity.makeWakeLock()

        lock.acquire()
        lock.release()
        #expect(activity.beginCount == 1)
        #expect(activity.endCount == 1)

        // A second release must not end an activity that is no longer held.
        lock.release()
        #expect(activity.endCount == 1, "release ended the activity twice")

        // ...and re-acquiring after a release begins exactly one more.
        lock.acquire()
        lock.acquire()
        #expect(activity.beginCount == 2, "a redundant acquire began a second, stacked activity")
        lock.release()
        #expect(activity.endCount == 2)
    }

    // The lock is worth nothing if `RecordingSession` does not actually drive it, and every test
    // above exercises the lock standalone — deleting `stop()`'s `release()` left all of them green.
    // This one asks the session, not the lock. Only the release half is reachable today: `start()`
    // needs TCC and a live audio session, so its `acquire()` waits on the backlog's capture seam.
    @Test
    @available(macOS 15.0, *)
    func recordingSessionStopReleasesTheWakeLock() async {
        let activity = CountingActivity()
        let lock = activity.makeWakeLock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-session-wakelock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = RecordingSession(directory: directory, wakeLock: lock)
        // `start()` is out of reach, so we stand in for the acquire it would have done: the point of
        // the test is that `stop()` gives the assertion back, whatever took it.
        lock.acquire()
        await session.stop()

        #expect(activity.endCount == 1, "stop() left the display assertion held — the machine would never sleep")
        #expect(!lock.isHeld)
    }
}
