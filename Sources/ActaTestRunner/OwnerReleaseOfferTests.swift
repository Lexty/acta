import ActaKit
@testable import ActaRuntime
import Foundation
import Testing

/// The words of the release stop offer, decided where a test can read them.
@Suite("Owner release offer text")
struct OwnerReleaseOfferTextTests {
    @Test("a named application is named in the headline and the detail; an unnamed one is not invented")
    func theApplicationIsNamedOnlyWhenItHasAName() {
        let named = OwnerReleaseOfferText(application: "Slack")
        #expect(named.headline == "Slack released the microphone")
        #expect(named.detail.contains("Acta saw Slack stop using the microphone input"))

        let unnamed = OwnerReleaseOfferText(application: nil)
        #expect(unnamed.headline == "The microphone was released")
        #expect(unnamed.detail.contains("the app this recording was started for"))
        #expect(unnamed != named)
    }

    /// ⚠️ **Acta saw an application release the input; it does not know that a call ended.** A word list is
    /// a blunt guard, and it is the one that catches the likeliest regression: someone "improving" the copy.
    @Test("no sentence claims the call, meeting or huddle is over")
    func theCopyNeverClaimsTheCallEnded() {
        let sentences = [OwnerReleaseOfferText(application: "Slack"), OwnerReleaseOfferText(application: nil)]
            .flatMap { [$0.headline, $0.detail] }
            + [OwnerReleaseOfferText.countdown(seconds: 12), OwnerReleaseOfferText.stopNow,
               OwnerReleaseOfferText.keepRecording]
        for sentence in sentences {
            let lowered = sentence.lowercased()
            for claim in ["ended", "is over", "finished", "hung up", "left the", "call", "meeting", "huddle"] {
                #expect(!lowered.contains(claim), "“\(sentence)” claims something Acta did not observe")
            }
        }
    }

    @Test("the countdown line renders the number it is given and never a negative one")
    func theCountdownLine() {
        #expect(OwnerReleaseOfferText.countdown(seconds: 12) == "Stopping and saving in 12 s")
        #expect(OwnerReleaseOfferText.countdown(seconds: -1) == "Stopping and saving in 0 s")
    }

    @Test("the secondary answer keeps the recording rather than cancelling anything")
    func theSecondaryAnswerIsNotCancel() {
        #expect(OwnerReleaseOfferText.keepRecording == "Keep Recording")
        #expect(OwnerReleaseOfferText.stopNow == "Stop Now")
    }

    @Test("the release offer stays answerable for longer than its countdown runs")
    @available(macOS 15.0, *)
    @MainActor
    func theLifetimeOutlastsTheCountdown() {
        let prompt = ReminderPrompt.offerToStopOnRelease(recordingID: 1, title: "t",
                                                         text: OwnerReleaseOfferText(application: nil))
        #expect(ReminderCoordinator.lifetime(of: prompt) > AcknowledgedCountdown.Configuration.default.duration)
    }
}

/// `MicrophoneOwnershipRule.discardAccumulatedRelease()`.
@Suite("Ownership rule: discarding an accumulated release")
struct OwnershipRuleDiscardTests {
    private static let origin = Date(timeIntervalSince1970: 7_000_000)
    private static let slack = AudioProcessKey.bundle("com.tinyspeck.slackmacgap")

    private static func rule() -> MicrophoneOwnershipRule? {
        let episode = MicrophoneActivityEpisode(id: 1, bundleID: "com.tinyspeck.slackmacgap", displayName: nil)
        guard let binding = OwnerBinding.bind(episode: episode, holding: [slack: .held], epoch: 1,
                                              observedAt: origin) else { return nil }
        return MicrophoneOwnershipRule(owner: binding)
    }

    private static func evidence(_ reading: MicrophoneInputReading?) -> AudioProcessReadings.Evidence {
        let observations = reading.map { reading -> [AudioProcessObservation] in
            let input: Bool? = switch reading {
            case .held: true
            case .released: false
            case .unreadable: nil
            }
            return [AudioProcessObservation(pid: 501, bundleID: "com.tinyspeck.slackmacgap", displayName: nil,
                                            processName: "Slack", isRunningInput: input)]
        } ?? []
        return AudioProcessReadings.evidence(from: AudioProcessSnapshot(processes: observations, isComplete: true),
                                             dropping: .init(bundleIDs: [], pids: []))
    }

    @Test("a qualified release is forgotten, and the next offer needs a full fresh interval")
    func aQualifiedReleaseNeedsAFreshInterval() throws {
        var rule = try #require(Self.rule())
        var outcomes: [MicrophoneOwnershipRule.Outcome] = []
        for second in 1...6 {
            outcomes.append(rule.observe(Self.evidence(.released), at: Self.origin.addingTimeInterval(TimeInterval(second))))
        }
        #expect(outcomes.contains(.releaseQualified))
        #expect(rule.phase == .releasedQualified)

        rule.discardAccumulatedRelease()
        #expect(rule.phase == .unknown(since: Self.origin.addingTimeInterval(6)))
        var fresh: [MicrophoneOwnershipRule.Outcome] = []
        for second in 7...11 {
            fresh.append(rule.observe(Self.evidence(.released), at: Self.origin.addingTimeInterval(TimeInterval(second))))
        }
        #expect(!fresh.contains(.releaseQualified), "the release requalified on evidence gathered before the discard")
        let twelfth = rule.observe(Self.evidence(.released), at: Self.origin.addingTimeInterval(12))
        #expect(twelfth == .releaseQualified)
    }

    @Test("a held owner has nothing to forget")
    func aHeldOwnerIsLeftAlone() throws {
        var rule = try #require(Self.rule())
        rule.discardAccumulatedRelease()
        #expect(rule.phase == .held(since: Self.origin))
    }
}

/// The release stop offer through the coordinator, over a real recording started from a real prompt.
///
/// ⚠️ **The machine is the measured one, not a one-holder fake.** `com.apple.CoreSpeech` holds the input
/// throughout, and once recording `com.apple.replayd` — Acta's own capture — does too. A fixture where the
/// owner's release was the only input change would let a rule that reads "nothing holds the microphone"
/// pass here and never fire on the Mac it was measured on.
///
/// ⚠️ **What this cannot reach**: the panel drawing the countdown, and whether it is acknowledged only when
/// really visible. The presenter is the injected fake from `ReminderPresenterTests`.
///
/// ⚠️ **Adding this suite pushed the full run over the edge described in
/// `docs/backlog/segment-finalisation-waits-under-parallel-tests.md`.** It passed on its own; in the full run its
/// first recording stopped inside the opening burst of other suites' finalisations, `sample` showed all
/// thirteen cooperative threads blocked in `SegmentWriter.finish`'s 30-second wait, and the socket suites
/// timed out at 62 s. Serializing it (nested here, under `ReminderCoordinatorTests`' `.serialized`) and
/// freezing its clocks did **not** fix that; an 8-second delay before each start did, which located it as
/// overlap. What restored the gate was serializing the two meter suites that still stopped recordings in
/// parallel. The nesting and the freezing are kept because they lower the load, not because they cured it.
extension ReminderCoordinatorTests {
@Suite("Owner release stop offer")
@MainActor
struct OwnerReleaseOfferTests {
    typealias ScriptedReader = ReminderCoordinatorTests.ScriptedReader
    typealias ManualClock = ReminderCoordinatorTests.ManualClock
    @available(macOS 15.0, *)
    typealias FakePresenter = ReminderPresenterTests.FakePresenter

    private static let slack = "com.tinyspeck.slackmacgap"

    private static func process(_ pid: Int32, _ bundle: String, _ name: String?, holding: Bool?)
        -> AudioProcessObservation {
        AudioProcessObservation(pid: pid, bundleID: bundle, displayName: name, processName: name ?? bundle,
                                isRunningInput: holding)
    }

    private static let coreSpeech = process(90, "com.apple.CoreSpeech", nil, holding: true)
    private static let replayd = process(91, "com.apple.replayd", nil, holding: true)

    /// Before the recording: CoreSpeech alone.
    private static let idleMachine = AudioProcessSnapshot(processes: [coreSpeech], isComplete: true)
    /// Slack in a huddle, CoreSpeech, and — once recording — Acta's own capture.
    private static func inCall(recording: Bool) -> AudioProcessSnapshot {
        AudioProcessSnapshot(processes: [process(501, slack, "Slack", holding: true), coreSpeech]
                                + (recording ? [replayd] : []),
                             isComplete: true)
    }
    /// The huddle over: Slack still running and idle, CoreSpeech and replayd still holding.
    private static let afterCall = AudioProcessSnapshot(
        processes: [process(501, slack, "Slack", holding: false), coreSpeech, replayd], isComplete: true)

    @available(macOS 15.0, *)
    struct Fixture {
        let harness: ControllerHarness
        let coordinator: ReminderCoordinator
        let reader: ScriptedReader
        let clock: ManualClock
        let presenter: FakePresenter

        /// One tick per second of the coordinator's clock.
        @MainActor
        func run(seconds: Int) {
            for _ in 0..<seconds {
                clock.advance(1)
                coordinator.tick()
            }
        }

        @MainActor
        var releaseOffer: (recordingID: UInt64, text: OwnerReleaseOfferText)? {
            guard case .offerToStopOnRelease(let id, _, let text)? = coordinator.prompt else { return nil }
            return (id, text)
        }
    }

    @available(macOS 15.0, *)
    private func makeFixture(acknowledging: Bool = true, quietMinutes: Int? = nil) -> Fixture {
        let harness = ControllerHarness(label: "owner-release")
        var settings = harness.controller.settings
        settings.offersRecordingWhenMicrophoneBusy = true
        settings.offersStopWhenOwnerReleases = true
        settings.offersStopWhenQuiet = quietMinutes != nil
        if let quietMinutes { settings.quietMinutesBeforeStopOffer = quietMinutes }
        harness.controller.settings = settings
        harness.controller.saveSettings()
        let (_, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                          defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        let api = ControlAPI(controller: harness.controller, microphone: manager)
        let reader = ScriptedReader()
        let clock = ManualClock()
        let coordinator = ReminderCoordinator(service: api, reader: reader, now: { clock.now })
        let presenter = FakePresenter()
        presenter.acknowledgesOnShow = acknowledging
        presenter.coordinator = coordinator
        coordinator.presenter = presenter
        return Fixture(harness: harness, coordinator: coordinator, reader: reader, clock: clock,
                       presenter: presenter)
    }

    /// Slack takes the microphone, the start offer is accepted, and the recording comes up bound to Slack.
    @available(macOS 15.0, *)
    private func startBound(_ fixture: Fixture, freezing: Bool = true) async -> Bool {
        let (harness, coordinator, reader) = (fixture.harness, fixture.coordinator, fixture.reader)
        reader.set(Self.idleMachine)
        coordinator.tick()                           // baseline: CoreSpeech is already holding
        reader.set(Self.inCall(recording: false))
        var token: UInt64?
        for _ in 0..<8 {
            fixture.run(seconds: 1)
            if case .offerToRecord(let offered, _, _, _, _)? = coordinator.prompt { token = offered; break }
        }
        guard let token else { Issue.record("no start offer was raised"); return false }

        harness.source.setFormat(FixtureAudioFormat(sampleRate: 48_000, channels: 1))
        harness.clock.onSleep { _ in harness.source.emitBatch() }
        coordinator.acceptStart(episodeID: token)
        let started = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        // ⚠️ **Frozen, not rationed.** These tests need the state of a recording, never its bytes; a frozen
        // clock emits nothing more and lets no watchdog fire, so nothing is written between the start and
        // the stop. The one test that must start a second recording on the same harness passes
        // `freezing: false`, because a frozen clock never advances again.
        if freezing {
            harness.clock.freeze()
        } else {
            let count = ReminderCoordinatorTests.Counter()
            harness.clock.onSleep { _ in
                if count.next().isMultiple(of: 5) { harness.source.emitBatch() }
            }
        }
        guard started else { Issue.record("the prompt start never reached .recording"); return false }
        reader.set(Self.inCall(recording: true))
        fixture.run(seconds: 1)
        // The confirmation the panel would have taken down after three seconds.
        coordinator.dismiss()
        guard harness.controller.ownerAdmission?.binding?.key == .bundle(Self.slack) else {
            Issue.record("the recording was not bound to Slack: \(String(describing: harness.controller.ownerAdmission))")
            return false
        }
        guard coordinator.ownerWatch != nil else { Issue.record("no owner watch was built"); return false }
        return true
    }

    /// Slack lets go; tick until the release offer is up. Returns how many seconds that took.
    @available(macOS 15.0, *)
    @discardableResult
    private func releaseUntilOffered(_ fixture: Fixture, limit: Int = 10) -> Int? {
        fixture.reader.set(Self.afterCall)
        for second in 1...limit {
            fixture.run(seconds: 1)
            if fixture.releaseOffer != nil { return second }
        }
        return nil
    }

    /// Whether a stop has begun.
    ///
    /// ⚠️ **Asked synchronously, never waited for.** `RecordingController.stop()` latches `isStopping` in
    /// the calling turn, so the answer is already there. And a wait would cost more than time: the harness
    /// emits audio from `TestClock.onSleep`, whose sleep returns at once, so every real millisecond spent
    /// with a recording open is a hot loop on the shared pool.
    @available(macOS 15.0, *)
    private func stopBegan(_ harness: ControllerHarness) -> Bool {
        harness.controller.isSaving || harness.controller.phase != .recording
    }

    @available(macOS 15.0, *)
    private func settle(_ harness: ControllerHarness) async {
        if harness.controller.phase == .recording { harness.controller.stop() }
        _ = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .idle
        }
    }

    // MARK: - The four outcomes

    @Test("a countdown that runs its full acknowledged duration stops the recording, and not a second sooner")
    @available(macOS 15.0, *)
    func aCompletedCountdownStops() async {
        let fixture = makeFixture()
        defer { fixture.harness.tearDown() }
        guard await startBound(fixture) else { return }

        guard let seconds = releaseUntilOffered(fixture), let offer = fixture.releaseOffer else {
            Issue.record("no release offer was raised"); return
        }
        #expect(seconds >= 5, "the offer was raised before a full five seconds of release")
        #expect(offer.text == OwnerReleaseOfferText(application: "Slack"))
        #expect(fixture.presenter.shown.last?.secondsRemaining == 20)

        fixture.run(seconds: 19)
        #expect(fixture.releaseOffer != nil)
        #expect(!stopBegan(fixture.harness), "the recording stopped before the countdown ended")

        fixture.run(seconds: 1)
        #expect(fixture.coordinator.prompt == nil)
        #expect(stopBegan(fixture.harness), "a completed countdown did not stop the recording")
        await settle(fixture.harness)
    }

    @Test("Stop Now stops at once")
    @available(macOS 15.0, *)
    func stopNowStops() async {
        let fixture = makeFixture()
        defer { fixture.harness.tearDown() }
        guard await startBound(fixture) else { return }
        guard releaseUntilOffered(fixture) != nil, let offer = fixture.releaseOffer else {
            Issue.record("no release offer was raised"); return
        }
        fixture.run(seconds: 2)
        fixture.coordinator.acceptReleaseStop(recordingID: offer.recordingID)
        #expect(fixture.coordinator.prompt == nil)
        #expect(stopBegan(fixture.harness), "Stop Now did not stop the recording")
        await settle(fixture.harness)
    }

    @Test("Keep Recording keeps it, and nothing more is offered until the owner holds the input again")
    @available(macOS 15.0, *)
    func keepRecordingSuppressesUntilTheOwnerReturns() async {
        let fixture = makeFixture()
        defer { fixture.harness.tearDown() }
        guard await startBound(fixture) else { return }
        guard releaseUntilOffered(fixture) != nil, let offer = fixture.releaseOffer,
              let first = fixture.presenter.shown.last?.id else {
            Issue.record("no release offer was raised"); return
        }
        fixture.coordinator.keepRecordingAfterRelease(recordingID: offer.recordingID)
        #expect(fixture.coordinator.prompt == nil)

        fixture.run(seconds: 40)
        #expect(fixture.coordinator.prompt == nil, "a kept recording was offered again while the owner stayed released")
        #expect(!stopBegan(fixture.harness), "a kept recording stopped")

        // Slack holds the input again, then lets it go: a new release, a new offer, a full countdown.
        fixture.reader.set(Self.inCall(recording: true))
        fixture.run(seconds: 2)
        guard let seconds = releaseUntilOffered(fixture) else {
            Issue.record("the owner returned and released again, and nothing was offered"); return
        }
        #expect(seconds >= 5)
        #expect(fixture.presenter.shown.last?.id != first)
        #expect(fixture.presenter.shown.last?.secondsRemaining == 20)
        await settle(fixture.harness)
    }

    @Test("the owner returning withdraws a running countdown silently and keeps recording")
    @available(macOS 15.0, *)
    func theOwnerReturningCancelsSilently() async {
        let fixture = makeFixture()
        defer { fixture.harness.tearDown() }
        guard await startBound(fixture) else { return }
        guard releaseUntilOffered(fixture) != nil, let id = fixture.presenter.shown.last?.id else {
            Issue.record("no release offer was raised"); return
        }
        fixture.run(seconds: 5)
        let shownBefore = fixture.presenter.shown.count

        fixture.reader.set(Self.inCall(recording: true))
        fixture.run(seconds: 1)
        #expect(fixture.coordinator.prompt == nil)
        #expect(fixture.coordinator.countdown?.phase == .revoked(.ownerReturned))
        #expect(fixture.presenter.withdrawn.contains(id))
        #expect(fixture.presenter.shown.count == shownBefore, "the return was announced rather than silent")

        fixture.run(seconds: 30)
        #expect(fixture.coordinator.prompt == nil)
        #expect(!stopBegan(fixture.harness), "a withdrawn countdown stopped the recording")
        await settle(fixture.harness)
    }

    /// ⚠️ **Awaiting, not running**: a late acknowledgement starts a full countdown, so revocation cannot
    /// wait for one to have begun.
    @Test("lost evidence withdraws a countdown still awaiting acknowledgement, and a late acknowledgement revives nothing")
    @available(macOS 15.0, *)
    func lostEvidenceWithdrawsAnAwaitingCountdown() async {
        let fixture = makeFixture(acknowledging: false)
        defer { fixture.harness.tearDown() }
        guard await startBound(fixture) else { return }
        guard releaseUntilOffered(fixture) != nil, let id = fixture.presenter.shown.last?.id else {
            Issue.record("no release offer was raised"); return
        }
        #expect(fixture.coordinator.countdown?.phase == .awaitingAcknowledgement)

        fixture.reader.set(AudioProcessSnapshot(
            processes: [Self.process(501, Self.slack, "Slack", holding: nil), Self.coreSpeech, Self.replayd],
            isComplete: false))
        fixture.run(seconds: 1)
        #expect(fixture.coordinator.prompt == nil)
        #expect(fixture.coordinator.countdown?.phase == .revoked(.evidenceLost))

        fixture.coordinator.acknowledgePresentation(id)
        fixture.run(seconds: 30)
        #expect(!stopBegan(fixture.harness))
        await settle(fixture.harness)
    }

    // MARK: - Displacement and arbitration

    /// ⚠️ **The named test for the plan's negative control** — remove the revocation on displacement.
    ///
    /// The quiet offer is raised while the release countdown runs. It takes the panel; the countdown is
    /// revoked, not inherited, so its deadline passes with nothing stopped; the quiet prompt's expiry acts on
    /// nothing; and the release, still standing, is then offered afresh with a full countdown.
    @Test("a quiet offer displacing the countdown revokes it, expires without acting, and the release is offered afresh")
    @available(macOS 15.0, *)
    func displacementByTheQuietOfferRevokesTheCountdown() async throws {
        let fixture = makeFixture(quietMinutes: 2)
        defer { fixture.harness.tearDown() }
        guard await startBound(fixture) else { return }
        let coordinator = fixture.coordinator

        /// One second: both tracks measured at the digital floor, then a tick.
        let generation: UInt64 = 1 << 40
        func second() {
            fixture.clock.advance(1)
            for track in [AudioActivitySummary.Track.microphone, .system] {
                coordinator.ingest(AudioActivitySummary(track: track, generation: generation, duration: 1,
                                                        power: -100, observedAt: fixture.clock.now))
            }
            coordinator.tick()
        }
        var warm = false
        for _ in 0..<120 {
            second()
            if coordinator.trackStateForTesting(.microphone) == .quiet,
               coordinator.trackStateForTesting(.system) == .quiet { warm = true; break }
        }
        #expect(warm, "the quiet rule never saw both tracks quiet")
        // Quiet has begun; the quiet offer is due 120 s from here. Slack lets go 100 s in.
        for _ in 0..<100 { second() }
        #expect(coordinator.prompt == nil, "an offer appeared before the owner released")

        fixture.reader.set(Self.afterCall)
        var released = false
        for _ in 0..<10 {
            second()
            if fixture.releaseOffer != nil { released = true; break }
        }
        guard released, let countdownID = fixture.presenter.shown.last?.id else {
            Issue.record("no release offer was raised before the quiet one"); return
        }
        var displaced = false
        for _ in 0..<19 {
            second()
            if case .offerToStop? = coordinator.prompt { displaced = true; break }
        }
        guard displaced, let quietPrompt = coordinator.prompt else {
            Issue.record("the quiet offer never displaced the countdown: \(String(describing: coordinator.prompt))"); return
        }
        #expect(coordinator.countdown == nil, "the quiet offer inherited the countdown it replaced")

        // Well past the displaced countdown's deadline, with the quiet prompt still standing.
        for _ in 0..<25 { second() }
        #expect(coordinator.prompt == quietPrompt)
        #expect(!stopBegan(fixture.harness), "a displaced countdown stopped the recording")

        // The quiet prompt expires. That is never an action.
        coordinator.dismiss(quietPrompt)
        #expect(!stopBegan(fixture.harness), "the quiet offer's expiry stopped the recording")

        fixture.run(seconds: 1)
        let fresh = try #require(fixture.presenter.shown.last, "nothing was shown after the quiet prompt expired")
        guard case .offerToStopOnRelease = fresh.prompt else {
            Issue.record("the release was not offered again after the quiet prompt went: \(fresh.prompt)"); return
        }
        #expect(fresh.id != countdownID)
        #expect(fresh.secondsRemaining == 20, "the fresh offer did not carry a full countdown")
        fixture.run(seconds: 20)
        #expect(stopBegan(fixture.harness), "the freshly offered countdown did not stop the recording")
        await settle(fixture.harness)
    }

    @Test("while the menu is open the release offer waits, spends nothing, and is raised once the menu closes")
    @available(macOS 15.0, *)
    func theMenuDefersTheOffer() async {
        let fixture = makeFixture()
        defer { fixture.harness.tearDown() }
        guard await startBound(fixture) else { return }
        fixture.coordinator.isMenuOpen = true
        #expect(releaseUntilOffered(fixture, limit: 15) == nil, "an offer was raised over the open menu")
        fixture.coordinator.isMenuOpen = false
        fixture.run(seconds: 1)
        #expect(fixture.releaseOffer != nil, "the deferred offer was spent rather than deferred")
        await settle(fixture.harness)
    }

    @Test("a lost presentation needs a freshly observed release before the offer returns")
    @available(macOS 15.0, *)
    func aLostPresentationNeedsFreshEvidence() async {
        let fixture = makeFixture()
        defer { fixture.harness.tearDown() }
        guard await startBound(fixture) else { return }
        guard releaseUntilOffered(fixture) != nil, let id = fixture.presenter.shown.last?.id else {
            Issue.record("no release offer was raised"); return
        }
        fixture.run(seconds: 3)
        fixture.coordinator.presentationLost(id)
        #expect(fixture.coordinator.prompt == nil)

        fixture.run(seconds: 4)
        #expect(fixture.coordinator.prompt == nil, "the offer returned on the evidence gathered before it was lost")
        guard let seconds = releaseUntilOffered(fixture) else {
            Issue.record("the offer never returned"); return
        }
        #expect(4 + seconds >= 5)
        #expect(fixture.presenter.shown.last?.id != id)
        await settle(fixture.harness)
    }

    @Test("an acknowledgement later than the prompt's lifetime still leaves Stop Now answerable to the end")
    @available(macOS 15.0, *)
    func aLateAcknowledgementKeepsTheOfferAnswerable() async {
        let fixture = makeFixture(acknowledging: false)
        defer { fixture.harness.tearDown() }
        guard await startBound(fixture) else { return }
        guard releaseUntilOffered(fixture) != nil, let offer = fixture.releaseOffer,
              let id = fixture.presenter.shown.last?.id else {
            Issue.record("no release offer was raised"); return
        }
        fixture.run(seconds: 15)
        fixture.coordinator.acknowledgePresentation(id)
        fixture.run(seconds: 19)            // 34 s after publication, past the 30 s lifetime
        #expect(fixture.releaseOffer != nil)
        fixture.coordinator.acceptReleaseStop(recordingID: offer.recordingID)
        #expect(stopBegan(fixture.harness), "a Stop Now inside the countdown was refused by the lifetime")
        await settle(fixture.harness)
    }

    // MARK: - Identity

    @Test("a countdown whose recording was replaced under it stops neither recording")
    @available(macOS 15.0, *)
    func aReplacedRecordingIsNotStopped() async {
        let fixture = makeFixture()
        defer { fixture.harness.tearDown() }
        let harness = fixture.harness
        guard await startBound(fixture, freezing: false) else { return }
        guard releaseUntilOffered(fixture) != nil, let offer = fixture.releaseOffer else {
            Issue.record("no release offer was raised"); return
        }
        fixture.run(seconds: 19)

        // A ends and B begins from the menu, with no tick in between: the coordinator has not noticed.
        harness.controller.stop()
        let idle = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .idle
        }
        #expect(idle, "the first recording never finished, so there was no successor to protect")
        harness.clock.onSleep { _ in harness.source.emitBatch() }
        harness.controller.start()
        let startedB = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        harness.clock.freeze()
        #expect(startedB, "the successor never started")
        #expect(harness.controller.ownerAdmission == .unbound(.notStartedFromPrompt))

        // Stop Now on the stale offer, before any observation.
        #expect(fixture.releaseOffer != nil, "the fixture lost the stale offer before it could be clicked")
        fixture.coordinator.acceptReleaseStop(recordingID: offer.recordingID)
        #expect(!stopBegan(harness), "Stop Now on A's offer stopped B")

        // And the countdown's own deadline, which the next tick reaches.
        fixture.run(seconds: 25)
        #expect(fixture.coordinator.ownerWatch == nil)
        #expect(!stopBegan(harness), "A's countdown stopped B")
        await settle(harness)
    }

    @Test("a recording started from the menu is never offered a release stop, whoever lets the input go")
    @available(macOS 15.0, *)
    func anUnboundRecordingIsNeverOffered() async {
        let fixture = makeFixture()
        defer { fixture.harness.tearDown() }
        let harness = fixture.harness
        fixture.reader.set(Self.inCall(recording: true))
        fixture.coordinator.tick()
        harness.source.setFormat(FixtureAudioFormat(sampleRate: 48_000, channels: 1))
        harness.clock.onSleep { _ in harness.source.emitBatch() }
        harness.controller.start()
        let started = await awaitCondition(timeoutMilliseconds: 6000) {
            MainActor.assumeIsolated { harness.controller.phase } == .recording
        }
        harness.clock.freeze()
        #expect(started)
        fixture.run(seconds: 2)
        fixture.coordinator.dismiss()
        #expect(releaseUntilOffered(fixture, limit: 30) == nil)
        #expect(fixture.coordinator.ownerWatch == nil)
        await settle(harness)
    }
}
}
