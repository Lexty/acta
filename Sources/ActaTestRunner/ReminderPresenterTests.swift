import ActaKit
@testable import ActaRuntime
import Foundation
import Testing

/// The presenter contract: a countdown that may act runs only from an acknowledged presentation.
///
/// ⚠️ **What these tests cannot reach.** `ReminderPanelController` lives in the executable and draws with
/// AppKit; whether it acknowledges only once the panel is really visible, and whether an update leaves
/// the panel where it was, is human acceptance. What is decided here is everything the coordinator does
/// with what a presenter tells it — and what it does when a presenter tells it nothing.
///
/// ⚠️ **The carrier is not the production prompt.** These tests attach a countdown to `.startedRecording`
/// to exercise the contract on its own; the release stop offer that carries one in production, and what its
/// completion does, is tested in `OwnerReleaseOfferTests`.
@Suite("Reminder presenter contract", .serialized)
@MainActor
struct ReminderPresenterTests {
    typealias Countdown = AcknowledgedCountdown
    typealias ScriptedReader = ReminderCoordinatorTests.ScriptedReader
    typealias ManualClock = ReminderCoordinatorTests.ManualClock

    private static let origin = Date(timeIntervalSince1970: 9_000_000)
    private static func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }
    private static let carrier = ReminderPrompt.startedRecording(title: "countdown carrier")

    // MARK: - The countdown itself

    // ⚠️ Outcomes are bound before they are compared: `#expect` captures its operands in a closure, which
    // cannot call a mutating method.

    @Test("a countdown that was never acknowledged does not run, however long it waits")
    func timeDoesNotRunBeforeAcknowledgement() {
        var countdown = Countdown(presentation: 7)
        let soon = countdown.evaluate(at: Self.at(1))
        let late = countdown.evaluate(at: Self.at(1000))
        #expect(soon == .none)
        #expect(late == .none)
        #expect(countdown.phase == .awaitingAcknowledgement)
    }

    @Test("the deadline is measured from the acknowledgement, and completion is reported once")
    func theDeadlineStartsAtAcknowledgement() {
        var countdown = Countdown(presentation: 7)
        let started = countdown.acknowledge(presentation: 7, at: Self.at(100))
        #expect(started)
        let counted = (1..<20).map { countdown.evaluate(at: Self.at(100 + TimeInterval($0))) }
        #expect(counted == (1..<20).map { .remaining(seconds: 20 - $0) })
        let atDeadline = countdown.evaluate(at: Self.at(120))
        let afterwards = countdown.evaluate(at: Self.at(121))
        let revokedLate = countdown.revoke(.dismissed)
        #expect(atDeadline == .completed)
        #expect(afterwards == .none)
        #expect(!revokedLate, "a completed countdown was revoked after the fact")
    }

    @Test("an acknowledgement for another presentation, or a second one, changes nothing")
    func foreignAndRepeatedAcknowledgementsAreRefused() {
        var countdown = Countdown(presentation: 7)
        let foreign = countdown.acknowledge(presentation: 8, at: Self.at(0))
        #expect(!foreign)
        #expect(countdown.phase == .awaitingAcknowledgement)
        let own = countdown.acknowledge(presentation: 7, at: Self.at(0))
        let repeated = countdown.acknowledge(presentation: 7, at: Self.at(10))
        #expect(own)
        #expect(!repeated)
        #expect(countdown.phase == .running(deadline: Self.at(20)))
    }

    @Test("a gap revokes even past the deadline, and nothing brings the countdown back")
    func aGapNeverCatchesUp() {
        var countdown = Countdown(presentation: 7)
        countdown.acknowledge(presentation: 7, at: Self.at(0))
        let watched = countdown.evaluate(at: Self.at(1))
        // Asleep from 1 s to 31 s: the deadline passed while nobody could cancel.
        let woke = countdown.evaluate(at: Self.at(31))
        let reacknowledged = countdown.acknowledge(presentation: 7, at: Self.at(32))
        let afterwards = countdown.evaluate(at: Self.at(33))
        #expect(watched == .remaining(seconds: 19))
        #expect(woke == .revoked(.observationLapsed))
        #expect(!reacknowledged)
        #expect(afterwards == .none)
    }

    @Test("a clock that runs backwards is a gap, not a watched interval")
    func aBackwardsClockRevokes() {
        var countdown = Countdown(presentation: 7)
        countdown.acknowledge(presentation: 7, at: Self.at(10))
        let outcome = countdown.evaluate(at: Self.at(9))
        #expect(outcome == .revoked(.observationLapsed))
    }

    @Test("a gap within the tolerance is one late tick, not a lapse")
    func oneLateTickIsTolerated() {
        var countdown = Countdown(presentation: 7)
        countdown.acknowledge(presentation: 7, at: Self.at(0))
        let late = countdown.evaluate(at: Self.at(2.5))
        let lapsed = countdown.evaluate(at: Self.at(5.01))
        #expect(late == .remaining(seconds: 18))
        #expect(lapsed == .revoked(.observationLapsed))
    }

    // MARK: - Through an injected presenter

    /// A presenter that records every call and acknowledges only when told to.
    @available(macOS 15.0, *)
    final class FakePresenter: ReminderPresenting {
        var shown: [ReminderPresentation] = []
        var updates: [ReminderPresentation] = []
        var withdrawn: [UInt64] = []
        var acknowledgesOnShow = false
        /// One-shot: the next `show` reports the presentation lost before it returns — a panel ordered
        /// onto a screen that is already locked, or occluded the instant it appears.
        var losesNextPresentationOnShow = false
        weak var coordinator: ReminderCoordinator?

        func show(_ presentation: ReminderPresentation) {
            shown.append(presentation)
            if acknowledgesOnShow { coordinator?.acknowledgePresentation(presentation.id) }
            if losesNextPresentationOnShow {
                losesNextPresentationOnShow = false
                coordinator?.presentationLost(presentation.id)
            }
        }
        func updateCountdown(_ presentation: ReminderPresentation) { updates.append(presentation) }
        func withdraw(_ presentationID: UInt64) { withdrawn.append(presentationID) }
    }

    @available(macOS 15.0, *)
    private struct Fixture {
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

        /// The id of the last presentation shown.
        @MainActor
        var lastID: UInt64? { presenter.shown.last?.id }
    }

    @available(macOS 15.0, *)
    private func makeFixture(presenter attach: Bool = true, acknowledging: Bool = false) -> Fixture {
        let harness = ControllerHarness(label: "reminder-presenter")
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
        if attach { coordinator.presenter = presenter }
        coordinator.tick()     // baseline
        return Fixture(harness: harness, coordinator: coordinator, reader: reader, clock: clock,
                       presenter: presenter)
    }

    /// ⚠️ **The named test for the plan's negative control.** Parked for longer than the whole duration,
    /// then acknowledged: a countdown started at publication would already have completed before the
    /// acknowledgement arrived.
    @Test("a parked acknowledgement holds the countdown, which then runs its full duration from the acknowledgement")
    @available(macOS 15.0, *)
    func aParkedAcknowledgementHoldsTheCountdown() {
        let fixture = makeFixture()
        defer { fixture.harness.tearDown() }
        fixture.coordinator.presentCountdown(Self.carrier)
        guard let id = fixture.lastID else { Issue.record("nothing was shown"); return }
        #expect(fixture.presenter.shown.last?.secondsRemaining == 20)

        fixture.run(seconds: 30)
        #expect(fixture.coordinator.authorisedCountdown == nil, "a countdown ran without being acknowledged")
        #expect(fixture.coordinator.prompt == Self.carrier)
        #expect(fixture.presenter.updates.isEmpty, "an unacknowledged countdown was rendered as running")

        fixture.coordinator.acknowledgePresentation(id)
        fixture.run(seconds: 19)
        #expect(fixture.coordinator.authorisedCountdown == nil, "the countdown ended before its full duration")
        fixture.run(seconds: 1)
        #expect(fixture.coordinator.authorisedCountdown == id)
        #expect(fixture.coordinator.prompt == nil)
        #expect(fixture.presenter.withdrawn.contains(id))
    }

    @Test("with no presenter attached, nothing is acknowledged and nothing is authorised")
    @available(macOS 15.0, *)
    func anUnavailablePresenterNeverAuthorises() {
        let fixture = makeFixture(presenter: false)
        defer { fixture.harness.tearDown() }
        fixture.coordinator.presentCountdown(Self.carrier)
        fixture.run(seconds: 60)
        #expect(fixture.coordinator.authorisedCountdown == nil)
        #expect(fixture.coordinator.countdown?.phase == .awaitingAcknowledgement)
        #expect(fixture.presenter.shown.isEmpty)
    }

    @Test("a stalled presenter, or one acknowledging the wrong presentation, never authorises")
    @available(macOS 15.0, *)
    func aStalledPresenterNeverAuthorises() {
        let fixture = makeFixture()
        defer { fixture.harness.tearDown() }
        fixture.coordinator.presentCountdown(Self.carrier)
        guard let first = fixture.lastID else { Issue.record("nothing was shown"); return }
        // Replaced before it was acknowledged; the late acknowledgement names the one that is gone.
        fixture.coordinator.presentCountdown(Self.carrier)
        guard let second = fixture.lastID, second != first else { Issue.record("no new presentation"); return }
        fixture.coordinator.acknowledgePresentation(first)
        fixture.coordinator.acknowledgePresentation(second &+ 1)
        fixture.run(seconds: 60)
        #expect(fixture.coordinator.authorisedCountdown == nil)
        #expect(fixture.coordinator.countdown?.presentation == second)
        #expect(fixture.coordinator.countdown?.phase == .awaitingAcknowledgement)
    }

    @Test("a running countdown is updated in place, once a second, and a repeated acknowledgement does not move its deadline")
    @available(macOS 15.0, *)
    func updatesAreInPlaceAndTheDeadlineIsTheCoordinators() {
        let fixture = makeFixture(acknowledging: true)
        defer { fixture.harness.tearDown() }
        fixture.coordinator.presentCountdown(Self.carrier)
        guard let id = fixture.lastID else { Issue.record("nothing was shown"); return }

        fixture.run(seconds: 10)
        #expect(fixture.presenter.shown.count == 1, "an update was presented as a new prompt")
        #expect(fixture.presenter.updates.map(\.id) == Array(repeating: id, count: 10))
        #expect(fixture.presenter.updates.map(\.secondsRemaining) == (10...19).reversed().map { $0 })

        // A presenter re-acknowledging on a redraw must not buy the countdown more time.
        fixture.coordinator.acknowledgePresentation(id)
        fixture.run(seconds: 10)
        #expect(fixture.coordinator.authorisedCountdown == id)
    }

    // MARK: - Revocation

    /// An acknowledged countdown five seconds in, ready to be revoked.
    @available(macOS 15.0, *)
    private func running() -> (Fixture, UInt64)? {
        let fixture = makeFixture(acknowledging: true)
        fixture.coordinator.presentCountdown(Self.carrier)
        fixture.run(seconds: 5)
        guard let id = fixture.lastID, case .running = fixture.coordinator.countdown?.phase else {
            Issue.record("the countdown is not running")
            fixture.harness.tearDown()
            return nil
        }
        return (fixture, id)
    }

    @available(macOS 15.0, *)
    private func expectRevoked(_ fixture: Fixture, _ id: UInt64, _ reason: Countdown.Revocation,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(fixture.coordinator.countdown?.phase == .revoked(reason), sourceLocation: sourceLocation)
        fixture.run(seconds: 30)
        #expect(fixture.coordinator.authorisedCountdown == nil, "a revoked countdown still authorised",
                sourceLocation: sourceLocation)
    }

    @Test("dismissing the prompt revokes its countdown")
    @available(macOS 15.0, *)
    func dismissalRevokes() {
        guard let (fixture, id) = running() else { return }
        defer { fixture.harness.tearDown() }
        fixture.coordinator.dismiss()
        #expect(fixture.coordinator.prompt == nil)
        #expect(fixture.presenter.withdrawn.contains(id))
        expectRevoked(fixture, id, .dismissed)
    }

    @Test("another prompt replacing it revokes the countdown rather than handing it on")
    @available(macOS 15.0, *)
    func replacementRevokes() {
        guard let (fixture, id) = running() else { return }
        defer { fixture.harness.tearDown() }
        guard raiseStartOffer(fixture) else { Issue.record("no start offer replaced the countdown"); return }
        // ⚠️ **Gone, not merely marked.** The replacing prompt carries no countdown, so none may remain
        // attached — a revoked record left in place would be one assignment away from being inherited.
        #expect(fixture.coordinator.countdown == nil, "the start offer inherited the countdown it replaced")
        fixture.coordinator.acknowledgePresentation(id)
        fixture.run(seconds: 30)
        #expect(fixture.coordinator.countdown == nil)
        #expect(fixture.coordinator.authorisedCountdown == nil, "a replaced countdown still authorised")
    }

    /// Slack takes the microphone until the start offer appears — a real prompt, raised by a real rule.
    @available(macOS 15.0, *)
    private func raiseStartOffer(_ fixture: Fixture) -> Bool {
        fixture.reader.set(AudioProcessSnapshot(
            processes: [AudioProcessObservation(pid: 501, bundleID: "com.tinyspeck.slackmacgap",
                                                displayName: "Slack", processName: "Slack",
                                                isRunningInput: true)],
            isComplete: true))
        for _ in 0..<8 {
            fixture.run(seconds: 1)
            if case .offerToRecord = fixture.coordinator.prompt { return true }
        }
        return false
    }

    @Test("switching the release preference off revokes the countdown and takes its prompt down")
    @available(macOS 15.0, *)
    func thePreferenceRevokes() {
        guard let (fixture, id) = running() else { return }
        defer { fixture.harness.tearDown() }
        var settings = fixture.harness.controller.settings
        settings.offersStopWhenOwnerReleases = false
        fixture.harness.controller.settings = settings
        fixture.harness.controller.saveSettings()
        fixture.coordinator.tick()
        #expect(fixture.coordinator.prompt == nil)
        expectRevoked(fixture, id, .preferenceOff)
    }

    @Test("quit revokes the countdown")
    @available(macOS 15.0, *)
    func quitRevokes() {
        guard let (fixture, id) = running() else { return }
        defer { fixture.harness.tearDown() }
        fixture.coordinator.beginClosing()
        #expect(fixture.coordinator.prompt == nil)
        // ⚠️ The tick no longer runs after quit, so drive the evaluation the other way: even an
        // acknowledgement arriving now changes nothing.
        fixture.coordinator.acknowledgePresentation(id)
        expectRevoked(fixture, id, .closing)
    }

    @Test("a presenter losing the presentation revokes the countdown, and leaves a prompt without one alone")
    @available(macOS 15.0, *)
    func lostPresentationRevokes() {
        guard let (fixture, id) = running() else { return }
        defer { fixture.harness.tearDown() }
        fixture.coordinator.presentationLost(id &+ 1)
        #expect(fixture.coordinator.countdown?.phase != .revoked(.presentationLost),
                "a loss reported for another presentation revoked this one")
        fixture.coordinator.presentationLost(id)
        #expect(fixture.coordinator.prompt == nil)
        #expect(fixture.presenter.withdrawn.contains(id))
        expectRevoked(fixture, id, .presentationLost)

        guard raiseStartOffer(fixture), let plainID = fixture.lastID, let plain = fixture.coordinator.prompt else {
            Issue.record("no start offer was raised"); return
        }
        fixture.coordinator.presentationLost(plainID)
        #expect(fixture.coordinator.prompt == plain)
    }

    /// ⚠️ **Sleep is modelled on the coordinator's clock**, which is what the countdown measures; the
    /// production clock is `ContinuousClock`-based and keeps counting while the Mac is asleep.
    @Test("a wake past the deadline withdraws the countdown instead of completing it, and only a new presentation counts again")
    @available(macOS 15.0, *)
    func noCatchUpStopAfterAWake() {
        guard let (fixture, id) = running() else { return }
        defer { fixture.harness.tearDown() }
        fixture.clock.advance(60)
        fixture.coordinator.tick()
        #expect(fixture.coordinator.authorisedCountdown == nil, "the countdown caught up across a sleep")
        #expect(fixture.coordinator.prompt == nil)
        fixture.coordinator.acknowledgePresentation(id)
        expectRevoked(fixture, id, .observationLapsed)

        fixture.coordinator.presentCountdown(Self.carrier)
        guard let fresh = fixture.lastID else { Issue.record("nothing was shown"); return }
        #expect(fresh != id)
        #expect(fixture.presenter.shown.last?.secondsRemaining == 20)
        fixture.run(seconds: 20)
        #expect(fixture.coordinator.authorisedCountdown == fresh)
    }

    @Test("a rebaseline after an unobserved gap revokes the countdown, whatever the injected clock says")
    @available(macOS 15.0, *)
    func aRebaselineRevokes() async {
        guard let (fixture, id) = running() else { return }
        defer { fixture.harness.tearDown() }
        fixture.coordinator.rebaselineThreshold = .milliseconds(50)
        try? await Task.sleep(nanoseconds: 120_000_000)
        fixture.clock.advance(1)
        fixture.coordinator.tick()
        #expect(fixture.coordinator.prompt == nil)
        fixture.coordinator.rebaselineThreshold = ReminderCoordinator.rebaselineAfter
        expectRevoked(fixture, id, .observationLapsed)
    }
}
