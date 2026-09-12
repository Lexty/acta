import ActaKit
import ActaRuntime
import Foundation
import Testing

/// `ReminderCoordinator` — the admission rules between a prompt and a recording.
///
/// ⚠️ **These belong in a test, not behind the panel's human-acceptance disclaimer.** The coordinator
/// lives in ActaRuntime with its service and reader injected; only the `NSPanel` drawing is manual. An
/// earlier commit message of mine claimed otherwise and Codex was right to correct it.
/// ⚠️ **Serialized.** These drive a real controller and a real recording; run in parallel with the rest
/// of the suite they starve the timing-sensitive socket tests, which is a property of the machine rather
/// than of either test.
@Suite("Reminder coordinator", .serialized)
@MainActor
struct ReminderCoordinatorTests {
    /// A reader whose snapshots are scripted.
    final class ScriptedReader: AudioProcessReading, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot = AudioProcessSnapshot(processes: [], isComplete: true)
        func set(_ next: AudioProcessSnapshot) { lock.lock(); snapshot = next; lock.unlock() }
        func readSnapshot() -> AudioProcessSnapshot {
            lock.lock(); defer { lock.unlock() }; return snapshot
        }
    }

    private static let slack = "com.tinyspeck.slackmacgap"

    private static func holding(_ bundle: String) -> AudioProcessSnapshot {
        AudioProcessSnapshot(processes: [AudioProcessObservation(pid: 501, bundleID: bundle,
                                                                 displayName: "Slack",
                                                                 processName: "Slack",
                                                                 isRunningInput: true)],
                             isComplete: true)
    }

    private static let quiet = AudioProcessSnapshot(processes: [], isComplete: true)

    /// Drive the coordinator to the point where a start offer is on screen.
    /// ⚠️ **The hold is simulated, not slept through.** The qualification hold is three seconds of
    /// *observed* time; a test that waits for it in real time is slow and timing-dependent for no gain,
    /// and on a loaded machine it starves the suites that genuinely measure time.
    @available(macOS 15.0, *)
    private func offered(_ coordinator: ReminderCoordinator, _ reader: ScriptedReader,
                         _ clock: ManualClock) -> UInt64? {
        reader.set(Self.quiet)
        coordinator.tick()                       // baseline
        reader.set(Self.holding(Self.slack))
        for _ in 0..<8 {
            coordinator.tick()
            if case .offerToRecord(let episodeID, _, _, _, _) = coordinator.prompt {
                return episodeID
            }
            clock.advance(1)
        }
        return nil
    }

    /// A counter safe to reach from the clock's callback.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

    /// A clock the test moves, shared by the summaries and the coordinator.
    final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = Date(timeIntervalSince1970: 8_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return instant }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); instant = instant.addingTimeInterval(seconds); lock.unlock()
        }
    }

    @available(macOS 15.0, *)
    private func makeClockedCoordinator()
        -> (ControllerHarness, ReminderCoordinator, ScriptedReader, ManualClock) {
        let harness = ControllerHarness(label: "reminders-clocked")
        let (_, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                          defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        let api = ControlAPI(controller: harness.controller, microphone: manager)
        let reader = ScriptedReader()
        let clock = ManualClock()
        let coordinator = ReminderCoordinator(service: api, reader: reader, now: { clock.now })
        return (harness, coordinator, reader, clock)
    }

    @Test("an offer appears for an application that holds the input")
    @available(macOS 15.0, *)
    func anOfferIsRaised() async {
        let (harness, coordinator, reader, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        let episodeID = offered(coordinator, reader, clock)
        #expect(episodeID != nil)
        if case .offerToRecord(_, let application, let bundleID, _, _) = coordinator.prompt {
            #expect(application == "Slack")
            #expect(bundleID == Self.slack)
        } else {
            Issue.record("no offer was raised")
        }
    }

    @Test("a quit already begun refuses a start and takes the prompt down")
    @available(macOS 15.0, *)
    func closingRefusesAStart() async {
        // ⚠️ The window the socket teardown exists to close: `applicationShouldTerminate` begins a
        // `.terminateLater` finalisation, and a prompt still on screen must not admit work into it.
        let (harness, coordinator, reader, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        guard let episodeID = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }
        coordinator.beginClosing()
        #expect(coordinator.prompt == nil)
        coordinator.acceptStart(episodeID: episodeID)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(harness.controller.phase == .idle)
    }

    @Test("a quit that begins while the barrier is being awaited still refuses the start")
    @available(macOS 15.0, *)
    func closingDuringTheBarrierRefusesAStart() async {
        // ⚠️ **The gate that matters is the one after the await.** `acceptStart` waits on the same
        // microphone barrier a socket `start` waits on, and quit can begin inside that wait — which is
        // precisely the window `applicationShouldTerminate` exists to close. Clearing the prompt at
        // `beginClosing` is not enough on its own, because by then the click has already been accepted.
        let (harness, coordinator, reader, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        guard let episodeID = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }
        coordinator.acceptStart(episodeID: episodeID)
        // Same turn, before the awaiting task resumes.
        coordinator.beginClosing()
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(harness.controller.phase == .idle)
    }

    @Test("a click carrying the wrong episode starts nothing")
    @available(macOS 15.0, *)
    func aMismatchedIdentityIsRefused() async {
        let (harness, coordinator, reader, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        guard let episodeID = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }
        coordinator.acceptStart(episodeID: episodeID &+ 99)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(harness.controller.phase == .idle)
        // The real prompt is still standing: a stray click answered nothing and cancelled nothing.
        #expect(coordinator.prompt != nil)
    }

    @Test("an expiry for an old prompt does not dismiss the one that replaced it")
    @available(macOS 15.0, *)
    func dismissalIsIdentityScoped() async {
        let (harness, coordinator, reader, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        guard let episodeID = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }
        let stale = ReminderPrompt.offerToRecord(episodeID: episodeID &+ 1, application: nil,
                                                 bundleID: nil, suggestedTitle: "x", microphone: "y")
        coordinator.dismiss(stale)
        #expect(coordinator.prompt != nil)
    }

    @Test("switching the reminder off takes its prompt down without acting")
    @available(macOS 15.0, *)
    func aPreferenceChangeDismissesWithoutActing() async {
        let (harness, coordinator, reader, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        guard offered(coordinator, reader, clock) != nil else {
            Issue.record("no offer to accept"); return
        }
        var settings = harness.controller.settings
        settings.offersRecordingWhenMicrophoneBusy = false
        harness.controller.settings = settings
        harness.controller.saveSettings()

        coordinator.tick()
        #expect(coordinator.prompt == nil)
        #expect(harness.controller.phase == .idle)
    }

    /// A coordinator whose microphone application can be **held open**, so an acceptance can be caught
    /// mid-barrier rather than before its task has begun.
    ///
    /// ⚠️ The Mac's default input is deliberately the *other* device: with the default already at the
    /// head of the list there is nothing to enforce, the application finishes immediately, and there is
    /// no barrier to park on. This is the same fixture shape the dispatcher's barrier test uses.
    @available(macOS 15.0, *)
    private func makeGatedCoordinator()
        -> (ControllerHarness, ReminderCoordinator, ScriptedReader, ManualClock, GatedClock,
            MicrophoneManager, FakeAudioDeviceDirectory) {
        let harness = ControllerHarness(label: "reminders-gated")
        let directory = FakeAudioDeviceDirectory(devices: [.builtInMic(), .airPods()],
                                                 defaultInput: "00-00-5E-00-53-01:input")
        let gate = GatedClock()
        let manager = MicrophoneManager(wiring: MicrophoneWiring(makeDirectory: { directory },
                                                                 makeClock: { gate },
                                                                 makeWakeCenter: { NotificationCenter() }))
        manager.start()
        manager.refreshInventory()
        let api = ControlAPI(controller: harness.controller, microphone: manager)
        let reader = ScriptedReader()
        let clock = ManualClock()
        let coordinator = ReminderCoordinator(service: api, reader: reader, now: { clock.now })
        return (harness, coordinator, reader, clock, gate, manager, directory)
    }

    @Test("an acceptance parked at the barrier is refused if its rule was replaced meanwhile")
    @available(macOS 15.0, *)
    func aResetDuringTheParkedBarrierRefusesTheStart() async {
        // ⚠️ **The collision an ordinary sequence produces.** Episode ids restart at one in a fresh rule.
        // An acceptance parked on the microphone barrier holds episode 1; a preference toggle replaces
        // the rule; another application already holding the input is minted spent episode 1 at the new
        // baseline; the parked acceptance resumes and its actionability check passes — against a
        // different call. Numeric equality inside a fresh rule is not identity.
        let (harness, coordinator, reader, clock, gate, manager, devices) = makeGatedCoordinator()
        defer { harness.tearDown() }
        guard let token = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }

        // Give the manager something to apply, so the acceptance has a barrier to wait on.
        var wanted = harness.controller.settings
        wanted.microphonePriority = ["BuiltInMicrophoneDevice"]
        wanted.managesSystemDefaultInput = true
        harness.controller.settings = wanted
        harness.controller.saveSettings()
        // ⚠️ **The write must not take.** A write that succeeds is verified immediately and the
        // application finishes without ever sleeping — so there is nothing to park on, and the test
        // would be measuring its own optimism.
        devices.setWritesTakeEffect(false)
        gate.hold()
        manager.applySettings(wanted)

        coordinator.acceptStart(episodeID: token)
        // The acceptance is now inside `settleMicrophoneSettings`; the gate holds the application open.
        let parked = await awaitCondition { gate.isHoldingSleeper }
        #expect(parked, "the barrier was never held, so nothing was parked to test")

        // ⚠️ The rule is replaced while the acceptance waits — by a **wake rebaseline**, not by the
        // preference. Switching the reminder off would be refused by its own guard, and the test would
        // then prove nothing about identity.
        coordinator.rebaselineThreshold = .milliseconds(50)
        try? await Task.sleep(nanoseconds: 120_000_000)
        coordinator.tick()

        gate.release()
        let started = await awaitCondition(timeoutMilliseconds: forbiddenOutcomeWindow) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        #expect(!started, "an acceptance survived the rule that minted its episode")
    }

    @Test("an acceptance parked at the barrier still starts when nothing invalidated it")
    @available(macOS 15.0, *)
    func aParkedAcceptanceStillStarts() async {
        // ⚠️ The positive half: refusing everything is not a passing admission check.
        let (harness, coordinator, reader, clock, gate, manager, devices) = makeGatedCoordinator()
        defer { harness.tearDown() }
        guard let token = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }
        var wanted = harness.controller.settings
        wanted.microphonePriority = ["BuiltInMicrophoneDevice"]
        wanted.managesSystemDefaultInput = true
        harness.controller.settings = wanted
        harness.controller.saveSettings()
        // ⚠️ **The write must not take.** A write that succeeds is verified immediately and the
        // application finishes without ever sleeping — so there is nothing to park on, and the test
        // would be measuring its own optimism.
        devices.setWritesTakeEffect(false)
        gate.hold()
        manager.applySettings(wanted)

        coordinator.acceptStart(episodeID: token)
        let parked = await awaitCondition { gate.isHoldingSleeper }
        #expect(parked, "the barrier was never held, so nothing was parked to test")
        gate.release()

        let started = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        #expect(started, "a valid acceptance never reached the recorder")
        await stopAndSettle(harness)
    }

    @Test("evidence from a finished recording cannot warm its successor")
    @available(macOS 15.0, *)
    func queuedEvidenceIsRefusedAfterAReplacement() async {
        // ⚠️ The gap the epoch alone did not close: until the successor's first summary announces a
        // newer epoch, a queued summary from the predecessor carries exactly the epoch the coordinator
        // considers current.
        let (harness, coordinator, _, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        await startRecording(harness)
        coordinator.tick()
        feedQuiet(coordinator, clock, seconds: 80, generation: 5)
        #expect(coordinator.trackStateForTesting(.microphone) != .unknown,
                "the fixture never got any evidence in")

        // The recording ends; everything measured describes audio that is no longer being recorded.
        harness.controller.stop()
        _ = await awaitCondition {
            MainActor.assumeIsolated { harness.controller.activeRecordingDirectory } == nil
        }
        coordinator.tick()

        // A straggler from the finished capture, carrying the epoch that was current when it was made.
        feedQuiet(coordinator, clock, seconds: 5, generation: 5)
        #expect(coordinator.trackStateForTesting(.microphone) == .unknown,
                "a finished recording's audio was accepted as evidence about its successor")
    }

    // MARK: - The stop reminder through the coordinator

    /// Feed both tracks at 1 Hz with fabricated observation times, which is what the summaries carry.
    @available(macOS 15.0, *)
    /// ⚠️ **The window ends at *now*.** Summaries carry the time the audio was measured, and the rule
    /// asks whether that evidence is fresh at the moment it is evaluated — so a fabricated origin in
    /// 1970 makes every track read as stale and nothing is ever quiet. That was a defect in the first
    /// version of this fixture, not in the rule.
    private func feedQuiet(_ coordinator: ReminderCoordinator, _ clock: ManualClock,
                           seconds: Int, generation: UInt64 = 1, power: Double = -100) {
        for _ in 0..<seconds {
            clock.advance(1)
            let at = clock.now
            for track in [AudioActivitySummary.Track.microphone, .system] {
                coordinator.ingest(AudioActivitySummary(track: track, generation: generation,
                                                        duration: 1, power: power, observedAt: at))
            }
        }
    }

    /// Start a recording and then **stop the audio**.
    ///
    /// ⚠️ **The harness wires `TestClock.onSleep` to emit a batch**, and a fake clock's sleep returns at
    /// once — so every millisecond a test spends awaiting anything in real time, with a recording open,
    /// pours another buffer of 48 kHz audio onto the disk. Tests that held a recording open across
    /// ordinary bounded waits wrote several gigabytes each and filled this machine's disk. These tests
    /// need the *state* of a recording, never its bytes.
    /// Stop a recording and wait for the assembly to finish.
    ///
    /// ⚠️ **Required before a test ends.** `tearDown()` removes the archive root, but a recording still
    /// finalising recreates it — so a test that walks away from a live recording leaves gigabyte-shaped
    /// litter in the system temp directory. Leaving it to the harness is not enough.
    @available(macOS 15.0, *)
    private func stopAndSettle(_ harness: ControllerHarness) async {
        guard harness.controller.phase != .idle else { return }
        harness.controller.stop()
        _ = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .idle
        }
    }

    @available(macOS 15.0, *)
    private func startRecording(_ harness: ControllerHarness) async {
        // ⚠️ Mono rather than stereo: the fixture's buffer size is a frame count, so the only axis a
        // test can cheaply shrink is the channel count. It halves what every batch writes.
        harness.source.setFormat(FixtureAudioFormat(sampleRate: 48_000, channels: 1))
        // Audio has to flow for the start to pass its own self-check...
        harness.clock.onSleep { _ in harness.source.emitBatch() }
        harness.controller.start()
        _ = await awaitCondition { MainActor.assumeIsolated { harness.controller.phase } == .recording }
        // ...and must then be **rationed**. ⚠️ The harness drives emission from `TestClock.onSleep`, and
        // a fake clock's sleep returns at once — so every millisecond a test spends awaiting anything,
        // with a recording open, pours another buffer of 48 kHz audio onto the disk. Tests that held a
        // recording open across ordinary bounded waits wrote several gigabytes each and filled this
        // machine's disk. Silencing it entirely is not the answer either: the flow watchdog exists to
        // notice a recording that has stopped receiving audio, and it correctly stops one that has. So
        // the fixture keeps feeding it, one batch in five, which is enough to stay alive and two
        // orders of magnitude less to write. These tests need the *state* of a recording, not its bytes.
        let tick = Counter()
        harness.clock.onSleep { _ in
            if tick.next().isMultiple(of: 5) { harness.source.emitBatch() }
        }
    }

    @Test("a stop offer is raised for a quiet recording")
    @available(macOS 15.0, *)
    func aStopOfferIsRaised() async {
        let (harness, coordinator, _, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        var settings = harness.controller.settings
        settings.quietMinutesBeforeStopOffer = 2
        harness.controller.settings = settings
        harness.controller.saveSettings()
        await startRecording(harness)
        #expect(harness.controller.phase == .recording, "the fixture never got a recording going")
        coordinator.tick()

        feedQuiet(coordinator, clock, seconds: 200)
        if case .offerToStop(_, _, _) = coordinator.prompt {
            // as intended
        } else {
            Issue.record("""
                no stop offer: microphone=\(coordinator.trackStateForTesting(.microphone)) \
                system=\(coordinator.trackStateForTesting(.system)) \
                recording=\(harness.controller.phase)
                """)
        }
    }

    @Test("a stop offer cannot stop the recording that replaced the one it names")
    @available(macOS 15.0, *)
    func aStaleStopOfferCannotStopItsSuccessor() async {
        // ⚠️ The replacement case: A stops and B starts, and an old prompt is still on screen. The
        // sampled "is recording" flag is true throughout, so a counter driven by it never moves — the
        // folder being written into is what distinguishes them.
        let (harness, coordinator, _, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        var settings = harness.controller.settings
        settings.quietMinutesBeforeStopOffer = 2
        harness.controller.settings = settings
        harness.controller.saveSettings()
        await startRecording(harness)
        coordinator.tick()
        feedQuiet(coordinator, clock, seconds: 200)
        guard case .offerToStop(let staleID, _, _) = coordinator.prompt else {
            Issue.record("no stop offer to go stale"); return
        }

        // ⚠️ `stop()` rather than `stopAndWait()`: this test is about identity, and waiting for the
        // assembly of a fixture recording costs tens of seconds for nothing it asserts.
        harness.controller.stop()
        // ⚠️ Wait for **idle**, not merely for the folder to clear: stopping is asynchronous and the
        // assembly that follows it refuses a start, so a second recording begun too early never comes
        // up — and the test then fails for a reason that has nothing to do with what it asserts.
        let settled = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .idle
        }
        #expect(settled, "the first recording never finished, so there was no successor to protect")
        await startRecording(harness)
        coordinator.tick()

        #expect(harness.controller.phase == .recording, "the successor was not running to begin with")
        coordinator.acceptStop(recordingID: staleID)
        let stopped = await awaitCondition(timeoutMilliseconds: 500) {
            MainActor.assumeIsolated { harness.controller.phase } != .recording
        }
        let ended = harness.controller.phase
        #expect(!stopped, "the successor left .recording for \(ended) after a prompt about its predecessor")
        await stopAndSettle(harness)
    }

    @Test("quit fences summaries already queued for delivery")
    @available(macOS 15.0, *)
    func closingFencesQueuedEvidence() async {
        // ⚠️ Removing the sink handler does not unqueue what is already on the main actor's queue, and
        // the panel observer lives until `applicationWillTerminate` — so without a fence a burst of
        // deliveries could raise a fresh prompt inside the quit finalisation.
        let (harness, coordinator, _, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        var settings = harness.controller.settings
        settings.quietMinutesBeforeStopOffer = 2
        harness.controller.settings = settings
        harness.controller.saveSettings()
        await startRecording(harness)
        coordinator.tick()

        coordinator.beginClosing()
        feedQuiet(coordinator, clock, seconds: 300)
        #expect(coordinator.prompt == nil)
        await stopAndSettle(harness)
    }

    @Test("a stop prompt refuses a successor the observer has not even noticed yet")
    @available(macOS 15.0, *)
    func aStaleStopOfferIsRefusedWithoutAnyObservation() async {
        // ⚠️ **The case the counter cannot catch.** If A stops and B starts with no observation in
        // between, the coordinator's own recording counter has not moved and its "is recording" flag was
        // never false — so every identity it minted itself still matches. The folder being written into
        // is the only thing that differs, and it is asked of the recorder rather than of the observer.
        let (harness, coordinator, _, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        var settings = harness.controller.settings
        settings.quietMinutesBeforeStopOffer = 2
        harness.controller.settings = settings
        harness.controller.saveSettings()
        await startRecording(harness)
        coordinator.tick()
        feedQuiet(coordinator, clock, seconds: 200)
        guard case .offerToStop(let staleID, _, _) = coordinator.prompt else {
            Issue.record("no stop offer to go stale"); return
        }

        // A ends and B begins, and nothing observes it: no tick, no state event consumed.
        harness.controller.stop()
        // ⚠️ Wait for **idle**, not merely for the folder to clear: stopping is asynchronous and the
        // assembly that follows it refuses a start, so a second recording begun too early never comes
        // up — and the test then fails for a reason that has nothing to do with what it asserts.
        let settled = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .idle
        }
        #expect(settled, "the first recording never finished, so there was no successor to protect")
        await startRecording(harness)

        #expect(harness.controller.phase == .recording, "the successor was not running to begin with")
        coordinator.acceptStop(recordingID: staleID)
        // ⚠️ A bounded wait for the **forbidden** outcome: `stop()` is asynchronous, so checking the
        // phase on the next line would pass even if the stop had been admitted.
        let stopped = await awaitCondition(timeoutMilliseconds: 500) {
            MainActor.assumeIsolated { harness.controller.phase } != .recording
        }
        let ended = harness.controller.phase
        #expect(!stopped, "the successor left .recording for \(ended) after a prompt about its predecessor")
        await stopAndSettle(harness)
    }

    @Test("the two reminders are independent switches")
    @available(macOS 15.0, *)
    func thePreferencesAreIndependent() async {
        // ⚠️ An early return when the *start* reminder was off left the quiet evaluation depending
        // entirely on summaries arriving — so with a stalled meter a standing stop offer would never
        // notice it had gone stale.
        let (harness, coordinator, _, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        var settings = harness.controller.settings
        settings.offersRecordingWhenMicrophoneBusy = false
        settings.quietMinutesBeforeStopOffer = 2
        harness.controller.settings = settings
        harness.controller.saveSettings()
        await startRecording(harness)
        coordinator.tick()

        feedQuiet(coordinator, clock, seconds: 200)
        if case .offerToStop = coordinator.prompt {
            // The stop reminder works with the start reminder switched off.
        } else {
            Issue.record("the stop reminder was disabled by the other preference")
        }
        await stopAndSettle(harness)
    }

    @Test("a gap in which nothing was observed rebaselines instead of counting as elapsed time")
    @available(macOS 15.0, *)
    func anUnobservedGapRebaselines() async {
        // ⚠️ Sleep, suspension and a corrected clock all move wall time without anything being watched.
        let (harness, coordinator, reader, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        guard offered(coordinator, reader, clock) != nil else {
            Issue.record("no offer to lose"); return
        }
        // A gap longer than the rebaseline threshold: the standing prompt goes, and the application
        // still holding the input is treated as a baseline rather than as a fresh call.
        coordinator.rebaselineThreshold = .milliseconds(50)
        try? await Task.sleep(nanoseconds: 120_000_000)
        coordinator.tick()
        #expect(coordinator.prompt == nil)
        for _ in 0..<5 {
            coordinator.tick()
            #expect(coordinator.prompt == nil, "waking re-offered a call that was already running")
        }
    }
}
