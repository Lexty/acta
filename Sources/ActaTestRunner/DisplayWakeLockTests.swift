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
    // `nullDevice`, not a second `Pipe()`: nothing ever reads stderr, so a pipe there is a buffer
    // that can only fill — and one that filled would deadlock `waitUntilExit()` for the exact reason
    // stdout is drained early below. `pmset` writes nothing to stderr today; this makes that not
    // matter.
    proc.standardError = FileHandle.nullDevice
    // Read before waiting: `pmset` output is small, but a pipe that fills while we block in
    // `waitUntilExit()` deadlocks, and a test that hangs forever is worse than one that fails.
    guard (try? proc.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// The assertion type that keeps the *display* on — the one Task 10 exists for. Its absence is the
/// 2026-07-15 failure: the display slept, ScreenCaptureKit lost its display, the capture died.
private let displaySleepAssertion = "PreventUserIdleDisplaySleep"
/// The assertion type that keeps the *system* awake. Held alongside the display one, because idle
/// system sleep kills a recording just as dead.
private let systemSleepAssertion = "PreventUserIdleSystemSleep"

/// Whether the OS reports *this process's* assertion of `type`, by the exact reason string a human
/// would read.
///
/// Scoped to our own pid on purpose. `pmset -g assertions` lists every process on the machine under
/// "Listed by owning process" (`pid 7922(Safari): [0x...] PreventUserIdleDisplaySleep named: "..."`),
/// and `DisplayWakeLock.reason` is flavor-agnostic — the string a real `Acta.app` publishes while
/// recording is byte-identical to ours. An unscoped grep therefore turns "the app is recording on
/// this machine" — the normal state, and the very thing Task 10 exists to sustain for hours — into a
/// suite-wide failure blaming code that is innocent. `.serialized` cannot help: the interference is
/// cross-process.
///
/// Matching the assertion *type* and not just pid + reason is what makes this test able to fail for
/// the right reason. `pmset` prints one line per type, so a check that accepted any line passed on
/// `PreventUserIdleSystemSleep` alone — verified by mutation: dropping `.idleDisplaySleepDisabled`
/// from the options, which deletes the entire point of Task 10, kept the suite green.
private func systemHoldsActaAssertion(_ type: String) -> Bool {
    let pid = ProcessInfo.processInfo.processIdentifier
    return pmsetAssertions()
        .split(separator: "\n")
        .contains { $0.contains("pid \(pid)(") && $0.contains(type) && $0.contains(DisplayWakeLock.reason) }
}

/// Whether the OS reports our recording assertion at all, in either of the two types it holds.
private func systemHoldsAnyActaAssertion() -> Bool {
    systemHoldsActaAssertion(displaySleepAssertion) || systemHoldsActaAssertion(systemSleepAssertion)
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
        #expect(systemHoldsAnyActaAssertion() == false)
    }

    @Test
    func acquireMakesTheAssertionVisibleToTheSystemAndReleaseRemovesIt() {
        let lock = DisplayWakeLock()

        lock.acquire()
        #expect(lock.isHeld)
        // Asserted by type, not merely by presence: the display-sleep assertion is the whole feature.
        // A recording that only prevents *system* idle sleep still dies exactly the way it died on
        // 2026-07-15, because ScreenCaptureKit loses its display the moment the screen goes dark.
        #expect(systemHoldsActaAssertion(displaySleepAssertion),
                "pmset does not list PreventUserIdleDisplaySleep — the display would sleep and take the capture with it")
        #expect(systemHoldsActaAssertion(systemSleepAssertion),
                "pmset does not list PreventUserIdleSystemSleep — idle system sleep would end the recording")

        lock.release()
        #expect(lock.isHeld == false)
        #expect(systemHoldsAnyActaAssertion() == false,
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
        #expect(systemHoldsActaAssertion(displaySleepAssertion))

        lock.release()
        #expect(lock.isHeld == false)
        #expect(systemHoldsAnyActaAssertion() == false,
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
        #expect(systemHoldsAnyActaAssertion() == false)
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
        #expect(systemHoldsActaAssertion(displaySleepAssertion))
        lock.release()
        #expect(systemHoldsAnyActaAssertion() == false)
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
    // These two ask the session, not the lock.
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
        // Stands in for the acquire a real `start()` would have done: the point of this test is that
        // `stop()` gives the assertion back, whatever took it. That `start()` is what takes it is the
        // next test's job.
        lock.acquire()
        await session.stop()

        #expect(activity.endCount == 1, "stop() left the display assertion held — the machine would never sleep")
        #expect(!lock.isHeld)
        // This session never started, so `stop()` must not leave a marker behind. Inventing one would
        // be a `status=recording` folder with no segments, which `Recovery` reads as an interrupted
        // recording and retries — failing — on every launch for the rest of the archive's life.
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(SessionManifest.fileName).path),
                "stop() on a session that never started wrote a marker — recovery would retry this folder forever")
    }

    @Test
    @available(macOS 15.0, *)
    func recordingSessionStartAcquiresTheWakeLockAndAFailedStartReleasesIt() async {
        // The acquire call site used to be unproven: deleting `wakeLock.acquire()` from `start()`
        // disables Task 10 outright and left the whole suite green. It was thought to need TCC and a
        // live audio session — it does not. `start()` takes the assertion and *then* creates the
        // folder, so an un-creatable directory throws before ScreenCaptureKit is ever involved and
        // drives both halves: the acquire, and the `defer` that releases it when a start never became
        // a recording. A leaked assertion after a failed start is the bug that pins a Mac awake with
        // nothing recording.
        let activity = CountingActivity()
        let lock = activity.makeWakeLock()
        // `/dev/null` is not a directory, so creating anything beneath it fails with ENOTDIR.
        let unusable = URL(fileURLWithPath: "/dev/null/acta-cannot-exist-\(UUID().uuidString)")
        let session = RecordingSession(directory: unusable, wakeLock: lock)

        await #expect(throws: (any Error).self) {
            try await session.start()
        }

        #expect(activity.beginCount == 1, "start() never took the assertion — the display would sleep mid-recording")
        #expect(activity.endCount == 1, "a failed start leaked the assertion — the Mac would never sleep again")
        #expect(!lock.isHeld)
    }
}
