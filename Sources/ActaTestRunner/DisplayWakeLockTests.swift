import ActaKit
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

/// Whether the OS reports our assertion, by the exact reason string a human would read.
private func systemHoldsActaAssertion() -> Bool {
    pmsetAssertions().contains(DisplayWakeLock.reason)
}

// Task 10: the display must stay awake for exactly the span of a recording — no longer.
//
// These tests ask the operating system, not the object: `DisplayWakeLock.isHeld` returning `false`
// proves nothing about whether the assertion the kernel is holding actually went away, and a leaked
// assertion is invisible until someone notices their Mac has not slept for a week. `pmset -g
// assertions` is the same thing a human would run to answer "what is keeping this Mac awake?", so it
// is what the test runs.
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
        do {
            let lock = DisplayWakeLock()
            lock.acquire()
            #expect(systemHoldsActaAssertion())
        }
        #expect(systemHoldsActaAssertion() == false,
                "deinit did not end the activity — the assertion leaked with the object")
    }
}
