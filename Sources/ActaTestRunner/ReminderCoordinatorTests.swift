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
    ///
    /// ⚠️ **It counts its reads**, because "the HAL was not touched" is otherwise only asserted by
    /// reading the production code. Codex made this point about a heartbeat test of mine that checked
    /// the *payload* said `notObserved` and would have stayed green beside an illicit `readSnapshot()`.
    final class ScriptedReader: AudioProcessReading, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot = AudioProcessSnapshot(processes: [], isComplete: true)
        private var reads = 0
        var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
        func set(_ next: AudioProcessSnapshot) { lock.lock(); snapshot = next; lock.unlock() }
        func readSnapshot() -> AudioProcessSnapshot {
            lock.lock(); defer { lock.unlock() }; reads += 1; return snapshot
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

    /// ⚠️ **The offer's own deadline outranks the panel's timer.** The view arms a `Timer` to take a
    /// prompt down; a timer can be late or fail to fire, and one was observed leaving a panel on screen
    /// forty-three seconds after a twenty-second offer. A late dismissal must never be able to *admit*
    /// a click — so the deadline is recorded when the prompt is published and checked again here, where
    /// it does not depend on the view having done anything.
    @Test("a click after the offer's deadline is refused however long the panel stayed up")
    @available(macOS 15.0, *)
    func anExpiredOfferCannotBeClicked() async {
        let (harness, coordinator, reader, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        guard let token = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }
        // The application is still holding the input, so nothing but the deadline can refuse this.
        #expect(coordinator.isEpisodeActionableForTesting(token),
                "the episode went stale on its own; this fixture would prove nothing")

        // Past the twenty seconds the offer is answerable for, with the panel still showing it.
        clock.advance(25)
        coordinator.acceptStart(episodeID: token)

        let told = await awaitCondition {
            MainActor.assumeIsolated {
                if case .startNoLongerAvailable = coordinator.prompt { return true }
                return false
            }
        }
        #expect(told, "an expired click said nothing")
        let started = await awaitCondition(timeoutMilliseconds: forbiddenOutcomeWindow) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        #expect(!started, "a click after the deadline started a recording")
    }

    /// ⚠️ **A press must always leave something on screen.** The whole defect the user reported was
    /// that it did not: the acceptance path took the prompt down, awaited the settings barrier, found
    /// the episode stale and returned — so the button vanished, nothing recorded, and the app said
    /// nothing at all about why.
    @Test("a click parked at the barrier reports staleness instead of disappearing")
    @available(macOS 15.0, *)
    func aParkedClickThatGoesStaleSaysSo() async {
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
        devices.setWritesTakeEffect(false)
        gate.hold()
        manager.applySettings(wanted)

        coordinator.acceptStart(episodeID: token)
        // The click is acknowledged the instant it is taken, before anything is known about it.
        #expect(coordinator.prompt.map { if case .checkingStart = $0 { true } else { false } } == true,
                "the click produced no feedback while it was being checked")

        let parked = await awaitCondition { gate.isHoldingSleeper }
        #expect(parked, "the barrier was never held, so nothing was parked to test")

        // The application releases the input while the click waits: the offer is now stale.
        reader.set(Self.quiet)
        clock.advance(1)
        coordinator.tick()

        gate.release()
        let told = await awaitCondition {
            MainActor.assumeIsolated {
                if case .startNoLongerAvailable = coordinator.prompt { return true }
                return false
            }
        }
        #expect(told, "a stale click said nothing")
        // And it started nothing.
        let started = await awaitCondition(timeoutMilliseconds: forbiddenOutcomeWindow) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        #expect(!started, "a stale click started a recording")
        await stopAndSettle(harness)
    }

    /// ⚠️ **A late answer must not speak over a newer one.** The acceptance path suspends, so a refusal
    /// belonging to an old press can arrive after a fresh offer is already on screen. It must be
    /// dropped, not drawn.
    @Test("a stale result cannot overwrite a newer prompt")
    @available(macOS 15.0, *)
    func aLateRefusalDoesNotOverwriteWhatCameAfterIt() async {
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
        devices.setWritesTakeEffect(false)
        gate.hold()
        manager.applySettings(wanted)

        coordinator.acceptStart(episodeID: token)
        let parked = await awaitCondition { gate.isHoldingSleeper }
        #expect(parked, "the barrier was never held, so nothing was parked to test")

        // While that press is parked, its episode dies and a **new** call raises a fresh offer.
        reader.set(Self.quiet)
        clock.advance(1)
        coordinator.tick()
        // ⚠️ The re-arm has to expire **while the input is still quiet**. A held reading returns
        // `.releasing` straight to `.spent`, so jumping the clock and only then presenting a hold
        // revives the old episode instead of closing it — and no second offer is ever minted. The
        // first version of this test did exactly that and failed on its own premise.
        clock.advance(40)
        coordinator.tick()
        reader.set(Self.holding(Self.slack))
        var fresh: UInt64?
        for _ in 0..<8 {
            coordinator.tick()
            if case .offerToRecord(let episodeID, _, _, _, _) = coordinator.prompt {
                fresh = episodeID
                break
            }
            clock.advance(1)
        }
        guard let fresh else {
            Issue.record("no second offer was raised, so there is nothing to overwrite"); return
        }
        #expect(fresh != token, "the second offer reused the first offer's identity")

        gate.release()
        // The parked refusal now resolves. It must not replace the offer standing on screen.
        let overwritten = await awaitCondition(timeoutMilliseconds: forbiddenOutcomeWindow) {
            MainActor.assumeIsolated {
                if case .offerToRecord = coordinator.prompt { return false }
                return true
            }
        }
        #expect(!overwritten, "a late refusal replaced a newer offer")
        await stopAndSettle(harness)
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

    /// Park an acceptance at the microphone barrier and return once it is held there.
    @available(macOS 15.0, *)
    private func acceptParkedAtTheBarrier(_ token: UInt64, _ harness: ControllerHarness,
                                          _ coordinator: ReminderCoordinator, _ gate: GatedClock,
                                          _ manager: MicrophoneManager,
                                          _ devices: FakeAudioDeviceDirectory) async -> Bool {
        var wanted = harness.controller.settings
        wanted.microphonePriority = ["BuiltInMicrophoneDevice"]
        wanted.managesSystemDefaultInput = true
        harness.controller.settings = wanted
        harness.controller.saveSettings()
        // ⚠️ **The write must not take**, or the application finishes without sleeping and nothing parks.
        devices.setWritesTakeEffect(false)
        gate.hold()
        manager.applySettings(wanted)
        coordinator.acceptStart(episodeID: token)
        return await awaitCondition { gate.isHoldingSleeper }
    }

    private static let dictation = "com.aaa.dictation"

    @Test("a candidate that changes while the barrier is parked does not become the owner")
    @available(macOS 15.0, *)
    func theAdmittedBindingIsTheRecheckedOne() async throws {
        // ⚠️ **The binding instant is the contract.** The prompt was about Slack. While the click waits
        // on the barrier a dictation service acquires the input too — the counterexample's newer
        // candidate — and time moves on. What is admitted is Slack, re-checked against the evidence read
        // *after* the barrier: its time and epoch, not the ones current when the click arrived.
        let (harness, coordinator, reader, clock, gate, manager, devices) = makeGatedCoordinator()
        defer { harness.tearDown() }
        guard let token = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }
        let clickedAt = clock.now
        let parked = await acceptParkedAtTheBarrier(token, harness, coordinator, gate, manager, devices)
        #expect(parked, "the barrier was never held, so nothing was parked to test")

        clock.advance(2)
        reader.set(AudioProcessSnapshot(processes: [
            AudioProcessObservation(pid: 501, bundleID: Self.slack, displayName: "Slack",
                                    processName: "Slack", isRunningInput: true),
            AudioProcessObservation(pid: 777, bundleID: Self.dictation, displayName: nil,
                                    processName: "dictation", isRunningInput: true),
        ], isComplete: true))
        coordinator.tick()
        let recheckedAt = clock.now
        let epoch = try #require(coordinator.releaseEvidence?.epoch)

        gate.release()
        let started = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        #expect(started, "a valid acceptance never reached the recorder")
        let binding = try #require(harness.controller.ownerAdmission?.binding,
                                   "a prompt start was admitted unbound: \(String(describing: harness.controller.ownerAdmission))")
        #expect(binding.key == .bundle(Self.slack), "the admitted owner is not the prompt's application")
        #expect(binding.observedAt == recheckedAt, "the binding carries evidence from before the barrier")
        #expect(binding.observedAt != clickedAt)
        #expect(binding.epoch == epoch)
        await stopAndSettle(harness)
    }

    @Test("an owner the evidence cannot see after the barrier starts the recording unbound, not refused")
    @available(macOS 15.0, *)
    func anUnseenOwnerAfterTheBarrierStartsUnbound() async {
        // ⚠️ **A withheld binding is never a refused start.** An unreadable moment keeps the episode
        // actionable — the activity rule's oldest tolerance — so the click is admitted; but nothing now
        // shows Slack holding, so no application is handed the authority to stop this recording.
        let (harness, coordinator, reader, clock, gate, manager, devices) = makeGatedCoordinator()
        defer { harness.tearDown() }
        guard let token = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }
        let parked = await acceptParkedAtTheBarrier(token, harness, coordinator, gate, manager, devices)
        #expect(parked, "the barrier was never held, so nothing was parked to test")

        clock.advance(1)
        reader.set(AudioProcessSnapshot(processes: [
            AudioProcessObservation(pid: 501, bundleID: Self.slack, displayName: "Slack",
                                    processName: "Slack", isRunningInput: nil),
        ], isComplete: false))
        coordinator.tick()
        #expect(coordinator.isEpisodeActionableForTesting(token), "the fixture no longer keeps the episode actionable")

        gate.release()
        let started = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        #expect(started, "a start whose owner could not be re-checked was refused instead of started unbound")
        #expect(harness.controller.ownerAdmission == .unbound(.ownerNotHeld))
        await stopAndSettle(harness)
    }

    @Test("with the release reminder off a prompt start is admitted unbound, and says why")
    @available(macOS 15.0, *)
    func aPromptStartWithoutReleaseObservationIsUnbound() async {
        let (harness, coordinator, reader, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        var settings = harness.controller.settings
        settings.offersStopWhenOwnerReleases = false
        harness.controller.settings = settings
        guard let token = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }
        #expect(coordinator.releaseEvidence == nil)
        coordinator.acceptStart(episodeID: token)
        let started = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        #expect(started)
        #expect(harness.controller.ownerAdmission == .unbound(.releaseNotObserved))
        await stopAndSettle(harness)
    }

    @Test("evidence older than an observation gap does not bind, even inside its epoch")
    @available(macOS 15.0, *)
    func staleEvidenceAtAdmissionStartsUnbound() async {
        // ⚠️ **The epoch moves only when a tick notices the gap.** An acceptance resuming after a polling
        // gap but before that tick still sees the old epoch, and the last `.held` reading in it would
        // otherwise hand stop authority to a picture nobody has refreshed.
        let (harness, coordinator, reader, clock, gate, manager, devices) = makeGatedCoordinator()
        defer { harness.tearDown() }
        guard let token = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }
        let parked = await acceptParkedAtTheBarrier(token, harness, coordinator, gate, manager, devices)
        #expect(parked, "the barrier was never held, so nothing was parked to test")
        #expect(coordinator.releaseEvidence?.evidence.readings[.bundle(Self.slack)] == .held,
                "the precondition is evidence that would bind")

        let threshold = coordinator.rebaselineThreshold.components
        clock.advance(TimeInterval(threshold.seconds) + 1)

        gate.release()
        let started = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        #expect(started, "stale evidence refused the start instead of leaving it unbound")
        #expect(harness.controller.ownerAdmission == .unbound(.evidenceStale))
        await stopAndSettle(harness)
    }

    @Test("switching the release reminder off during the barrier admits unbound before any tick")
    @available(macOS 15.0, *)
    func releasePreferenceIsRecheckedAtAdmission() async {
        // ⚠️ **The evidence is cleared only on the next tick.** Binding from it would let a later re-enable
        // offer to stop a recording that was admitted while the user had the offer switched off.
        let (harness, coordinator, reader, clock, gate, manager, devices) = makeGatedCoordinator()
        defer { harness.tearDown() }
        guard let token = offered(coordinator, reader, clock) else {
            Issue.record("no offer to accept"); return
        }
        let parked = await acceptParkedAtTheBarrier(token, harness, coordinator, gate, manager, devices)
        #expect(parked, "the barrier was never held, so nothing was parked to test")

        var settings = harness.controller.settings
        settings.offersStopWhenOwnerReleases = false
        harness.controller.settings = settings
        #expect(coordinator.releaseEvidence != nil, "the precondition is evidence no tick has discarded yet")

        gate.release()
        let started = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        #expect(started, "a preference switched off refused the start instead of leaving it unbound")
        #expect(harness.controller.ownerAdmission == .unbound(.releaseNotObserved))
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

    // MARK: - The heartbeat

    /// ⚠️ **These assert a property, not a log line.** `ReminderCoordinator.log` is a private `let` and
    /// the runner has no seam that captures `os_log`; a test that could only read the unified log would
    /// be testing Apple's logging rather than this schedule.

    @Test("the heartbeat fires on its own schedule, and not between beats")
    @available(macOS 15.0, *)
    func theHeartbeatFiresOnSchedule() async {
        let (harness, coordinator, reader, _) = makeClockedCoordinator()
        defer { harness.tearDown() }
        coordinator.heartbeatInterval = 3
        reader.set(Self.quiet)

        coordinator.tick()
        #expect(coordinator.heartbeatCount == 1, "the first tick left no record that this instance ran")
        #expect(coordinator.lastHeartbeat?.tick == 1)
        coordinator.tick()
        #expect(coordinator.heartbeatCount == 1, "a beat was emitted between two due ticks")
        coordinator.tick()
        #expect(coordinator.heartbeatCount == 1, "a beat was emitted between two due ticks")
        coordinator.tick()
        #expect(coordinator.heartbeatCount == 2, "the fourth tick was due a beat and did not emit one")
        #expect(coordinator.lastHeartbeat?.tick == 4)
        #expect(coordinator.tickCount == 4)
        #expect((coordinator.lastHeartbeat?.uptime ?? .zero) > .zero)
    }

    /// ⚠️ **The one that matters.** The existing holder diagnostic logs only when the set of holders
    /// changes, which is why a stopped tick and an idle machine were indistinguishable in the log for
    /// the 2026-09-12 silence. An unchanging picture is the normal state of an idle Mac, and it is
    /// exactly the state the beat has to survive.
    @Test("an unchanging picture still produces heartbeats")
    @available(macOS 15.0, *)
    func anUnchangingPictureStillBeats() async {
        let (harness, coordinator, reader, _) = makeClockedCoordinator()
        defer { harness.tearDown() }
        coordinator.heartbeatInterval = 2
        reader.set(Self.quiet)                      // the same snapshot on every tick, never replaced

        var beats: [ReminderHeartbeat] = []
        for _ in 0..<8 {
            let before = coordinator.heartbeatCount
            coordinator.tick()
            if coordinator.heartbeatCount > before, let beat = coordinator.lastHeartbeat {
                beats.append(beat)
            }
        }
        #expect(beats.count == 4, "eight ticks at an interval of two owed four beats")
        let expected = ReminderHeartbeat.Observation.observed(processes: 0, isComplete: true,
                                                              holders: 0)
        #expect(beats.allSatisfy { $0.observation == expected },
                "the fixture was supposed to hold the picture still")
        #expect(beats.map(\.tick) == [1, 3, 5, 7])
    }

    /// ⚠️ **Every reminder off, and the two that consume process observations named explicitly.** The
    /// quiet reminder does not govern the read at all — it measures audio, not processes — so "both
    /// preferences off" was never the gate. The gate is the start reminder *or* the release reminder,
    /// and the durable matrix is: neither of those two → zero reads for either value of the quiet one;
    /// the release one on → a read even from idle, which is what Task 6 introduces.
    ///
    /// ⚠️ Codex caught this after the commit: an earlier version left `offersStopWhenOwnerReleases` at
    /// its default `true` and claimed to be the case that *survives* Task 6. It was the case Task 6
    /// breaks — the same objection I had just used to decline a test of his.
    @Test("with every reminder off the heartbeat reports that nothing was observed")
    @available(macOS 15.0, *)
    func noReminderEnabledBeatsNotObserved() async {
        let (harness, coordinator, reader, _) = makeClockedCoordinator()
        defer { harness.tearDown() }
        var settings = harness.controller.settings
        settings.offersRecordingWhenMicrophoneBusy = false   // consumes the snapshot today
        settings.offersStopWhenOwnerReleases = false         // will consume it from Task 6
        settings.offersStopWhenQuiet = false                 // consumes audio summaries, never the HAL
        harness.controller.settings = settings
        harness.controller.saveSettings()
        reader.set(Self.holding(Self.slack))        // held, and deliberately never looked at

        coordinator.tick()
        #expect(coordinator.lastHeartbeat?.observation == .notObserved)
        #expect(coordinator.lastHeartbeat?.offersRecordingWhenMicrophoneBusy == false)
        #expect(coordinator.lastHeartbeat?.offersStopWhenQuiet == false)
        #expect(coordinator.lastHeartbeat?.offersStopWhenOwnerReleases == false)
        // ⚠️ **The assertion that makes the payload mean something.** Without it the test passes beside
        // a diagnostic read the design refuses, because `notObserved` describes the payload rather than
        // the reader.
        #expect(reader.readCount == 0, "the process list was read for a feature nobody enabled")
    }

    /// ⚠️ **Each switch reported from its own field.** The beat above has all three off, so a release field
    /// hard-coded to `false`, or read from the quiet switch, passed it.
    @Test("the beat reports each reminder switch from its own setting")
    @available(macOS 15.0, *)
    func theBeatReportsEachSwitchFromItsOwnSetting() async {
        let (harness, coordinator, _, _) = makeClockedCoordinator()
        defer { harness.tearDown() }
        coordinator.heartbeatInterval = 1       // a beat on every tick, so each case reads its own
        for (start, quiet, release) in [(false, false, true), (true, false, false), (false, true, false)] {
            var settings = harness.controller.settings
            settings.offersRecordingWhenMicrophoneBusy = start
            settings.offersStopWhenQuiet = quiet
            settings.offersStopWhenOwnerReleases = release
            harness.controller.settings = settings
            harness.controller.saveSettings()

            coordinator.tick()
            #expect(coordinator.lastHeartbeat?.offersRecordingWhenMicrophoneBusy == start)
            #expect(coordinator.lastHeartbeat?.offersStopWhenQuiet == quiet)
            #expect(coordinator.lastHeartbeat?.offersStopWhenOwnerReleases == release)
        }
    }

    /// ⚠️ **Every other beat in these tests carries an empty, complete snapshot**, so a payload
    /// hard-coded to `processes: 0, isComplete: true, holders: 0` would satisfy them all. Codex spotted
    /// that; this is the case that refuses it.
    @Test("the beat reports what was actually in the snapshot, holders and completeness alike")
    @available(macOS 15.0, *)
    func theBeatReportsTheSnapshotItRead() async {
        let (harness, coordinator, reader, _) = makeClockedCoordinator()
        defer { harness.tearDown() }
        // Three processes, two of them holding input, one whose input property could not be read — the
        // shape the real machine produces, where `isRunningInput` is `nil` for a process the HAL would
        // not answer for.
        reader.set(AudioProcessSnapshot(
            processes: [
                AudioProcessObservation(pid: 501, bundleID: Self.slack, displayName: "Slack",
                                        processName: "Slack", isRunningInput: true),
                AudioProcessObservation(pid: 502, bundleID: "com.apple.CoreSpeech", displayName: nil,
                                        processName: "corespeechd", isRunningInput: true),
                AudioProcessObservation(pid: 503, bundleID: "com.apple.Music", displayName: "Music",
                                        processName: "Music", isRunningInput: false),
                AudioProcessObservation(pid: 504, bundleID: nil, displayName: nil, processName: nil,
                                        isRunningInput: nil),
            ],
            isComplete: false))

        coordinator.tick()
        #expect(coordinator.lastHeartbeat?.observation
                == .observed(processes: 4, isComplete: false, holders: 2))
        #expect(reader.readCount == 1, "one tick must read the process list exactly once")
    }

    // MARK: - One snapshot per tick

    private static let slackHelper = "com.tinyspeck.slackmacgap.helper"

    /// The measured machine during a huddle: the Slack helper and CoreSpeech both holding, plus a
    /// process of Acta's own holding too, which the release side must never see.
    private static let huddle = AudioProcessSnapshot(
        processes: [
            AudioProcessObservation(pid: 601, bundleID: slackHelper, displayName: nil,
                                    processName: "Slack Helper", isRunningInput: true),
            AudioProcessObservation(pid: 602, bundleID: "com.apple.CoreSpeech", displayName: nil,
                                    processName: "corespeechd", isRunningInput: true),
            AudioProcessObservation(pid: 603, bundleID: "dev.personal.acta-dev", displayName: "Acta",
                                    processName: "Acta", isRunningInput: true),
        ],
        isComplete: true)

    @available(macOS 15.0, *)
    private func apply(_ harness: ControllerHarness, start: Bool, release: Bool, quiet: Bool,
                       excluding excluded: [String] = []) {
        var settings = harness.controller.settings
        settings.offersRecordingWhenMicrophoneBusy = start
        settings.offersStopWhenOwnerReleases = release
        settings.offersStopWhenQuiet = quiet
        settings.reminderExcludedBundleIDs = excluded
        harness.controller.settings = settings
        harness.controller.saveSettings()
    }

    /// ⚠️ **The test the plan's negative control names.** Gating the read on the start reminder would
    /// make the release offer depend on a preference the user can switch off separately, and a binding
    /// could then never be re-checked against anything.
    @Test("with the start reminder off and the release one on, the process list is observed from idle")
    @available(macOS 15.0, *)
    func releaseStopObservesFromIdleWithTheStartReminderOff() async {
        let (harness, coordinator, reader, clock) = makeClockedCoordinator()
        defer { harness.tearDown() }
        apply(harness, start: false, release: true, quiet: false)
        reader.set(Self.huddle)
        #expect(harness.controller.phase == .idle, "the precondition is an idle recorder")

        coordinator.tick()
        #expect(reader.readCount == 1, "the release side read nothing from idle")
        #expect(coordinator.lastHeartbeat?.observation
                == .observed(processes: 3, isComplete: true, holders: 3))
        guard let seen = coordinator.releaseEvidence else {
            Issue.record("the release side kept no evidence from the read"); return
        }
        #expect(seen.observedAt == clock.now, "the evidence was stamped with a different clock")
        #expect(seen.evidence.isComplete)
        #expect(seen.evidence.reading(of: .bundle(Self.slackHelper)) == .held)
        #expect(seen.evidence.reading(of: .bundle("com.apple.CoreSpeech")) == .held)

        // Enough held ticks to qualify a start offer, and none appears. ⚠️ **This pins the outcome, not
        // the gate.** Feeding the start rule regardless of its preference was run as a control and
        // stayed green: while that preference is off the rule is replaced on every tick and its context
        // is disabled, so whether it was fed is not observable from here.
        for _ in 0..<8 {
            clock.advance(1)
            coordinator.tick()
        }
        #expect(coordinator.prompt == nil, "the release preference raised a start offer")
        #expect(reader.readCount == 9, "one tick must read the process list exactly once")
    }

    /// ⚠️ **The whole matrix, both directions.** Zero reads for either quiet value when neither
    /// process-consuming reminder is on; exactly one read per tick for any other combination — a
    /// second read per tick for the second rule would be the cost this task exists to avoid.
    @Test("the process list is read once per tick when either consumer is on, and never otherwise")
    @available(macOS 15.0, *)
    func theReadMatrix() async {
        let (harness, coordinator, reader, _) = makeClockedCoordinator()
        defer { harness.tearDown() }
        reader.set(Self.huddle)
        for start in [false, true] {
            for release in [false, true] {
                for quiet in [false, true] {
                    apply(harness, start: start, release: release, quiet: quiet)
                    let before = reader.readCount
                    coordinator.tick()
                    coordinator.tick()
                    let expected = (start || release) ? 2 : 0
                    #expect(reader.readCount - before == expected,
                            "start=\(start) release=\(release) quiet=\(quiet): two ticks read \(reader.readCount - before) times")
                    #expect((coordinator.releaseEvidence != nil) == release,
                            "start=\(start) release=\(release) quiet=\(quiet): release evidence did not follow its preference")
                }
            }
        }
    }

    /// ⚠️ **Evidence the release side was not allowed to keep gathering is not evidence of the
    /// present.** Switched off after a read, the last picture must go rather than linger for whatever
    /// consumes it next.
    @Test("switching the release preference off discards what it saw")
    @available(macOS 15.0, *)
    func switchingReleaseOffDiscardsItsEvidence() async {
        let (harness, coordinator, reader, _) = makeClockedCoordinator()
        defer { harness.tearDown() }
        apply(harness, start: true, release: true, quiet: false)
        reader.set(Self.huddle)
        coordinator.tick()
        #expect(coordinator.releaseEvidence != nil, "the precondition is evidence to discard")

        apply(harness, start: true, release: false, quiet: false)
        coordinator.tick()
        #expect(reader.readCount == 2, "the start reminder still reads")
        #expect(coordinator.releaseEvidence == nil, "evidence outlived the preference that gathered it")
    }

    /// ⚠️ **The release side drops Acta's own processes and nothing else.** "Do not offer to record
    /// Slack" is not consent to disregard Slack while deciding who may stop a recording — the exclusion
    /// list stays scoped to start offers.
    @Test("the release side ignores Acta's own capture but not the start reminder's exclusions")
    @available(macOS 15.0, *)
    func releaseEvidenceDropsOnlyActaItself() async {
        let (harness, coordinator, reader, _) = makeClockedCoordinator()
        defer { harness.tearDown() }
        apply(harness, start: true, release: true, quiet: false, excluding: [Self.slackHelper])
        reader.set(Self.huddle)
        coordinator.tick()
        guard let seen = coordinator.releaseEvidence else {
            Issue.record("no evidence to inspect"); return
        }
        #expect(seen.evidence.readings[.bundle("dev.personal.acta-dev")] == nil,
                "Acta's own capture reached the release side")
        #expect(seen.evidence.reading(of: .bundle(Self.slackHelper)) == .held,
                "the start reminder's exclusion list reached the release side")
    }
}
