import ActaKit
import Foundation
import Testing

/// `MicrophoneActivityRule` — the decision "another application took the microphone, ask about it?".
///
/// Every test here drives the rule with explicit timestamps rather than sleeping: the rule has no clock
/// of its own precisely so that the whole matrix — holds, re-arms, unreadable gaps — is decided rather
/// than raced.
@Suite("Microphone activity rule")
struct MicrophoneActivityRuleTests {
    // MARK: - Fixture

    private static let start = Date(timeIntervalSince1970: 1_000_000)
    private static let slack = "com.tinyspeck.slackmacgap"

    /// A snapshot in which `bundles` hold the input and nothing else does.
    private static func holding(_ bundles: [String],
                                names: [String: String] = [:],
                                idle: [String] = []) -> AudioProcessSnapshot {
        var pid: Int32 = 100
        var processes: [AudioProcessObservation] = []
        for bundle in bundles {
            processes.append(AudioProcessObservation(pid: pid, bundleID: bundle,
                                                     displayName: names[bundle],
                                                     isRunningInput: true))
            pid += 1
        }
        for bundle in idle {
            processes.append(AudioProcessObservation(pid: pid, bundleID: bundle,
                                                     displayName: names[bundle],
                                                     isRunningInput: false))
            pid += 1
        }
        return AudioProcessSnapshot(processes: processes, isComplete: true)
    }

    private static let quiet = AudioProcessSnapshot(processes: [], isComplete: true)

    /// A rule that has seen its baseline on an idle machine, so the next held sample is a rising edge.
    private static func armedRule(_ configuration: MicrophoneActivityRule.Configuration = .default)
        -> MicrophoneActivityRule {
        var rule = MicrophoneActivityRule(configuration: configuration)
        _ = rule.observe(quiet, at: start, context: MicrophoneActivityRule.Context())
        return rule
    }

    private static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private static func offeredEpisode(_ outcome: MicrophoneActivityRule.Outcome)
        -> MicrophoneActivityEpisode? {
        if case .offer(let episode) = outcome { return episode }
        return nil
    }

    // MARK: - Qualification

    @Test("a probe too short to be a call raises nothing")
    func aBriefHoldNeverQualifies() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: context) == .none)
        // Released again well before the three-second hold: this is what a permission check looks like.
        #expect(rule.observe(Self.quiet, at: Self.at(2), context: context) == .none)
        // And it leaves nothing behind that a later sample could complete.
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(3), context: context) == .none)
    }

    @Test("input held past the hold offers exactly once")
    func aQualifiedHoldOffersOnce() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: context) == .none)
        let outcome = rule.observe(Self.holding([Self.slack]), at: Self.at(4.1), context: context)
        #expect(Self.offeredEpisode(outcome)?.bundleID == Self.slack)
        // The episode is spent: holding the microphone for an hour is still one call.
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(60), context: context) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(600), context: context) == .none)
    }

    @Test("the offer names the application only when the system named it")
    func attributionIsNeverInvented() {
        var named = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        _ = named.observe(Self.holding([Self.slack], names: [Self.slack: "Slack"]),
                          at: Self.at(1), context: context)
        let withName = named.observe(Self.holding([Self.slack], names: [Self.slack: "Slack"]),
                                     at: Self.at(4.1), context: context)
        #expect(Self.offeredEpisode(withName)?.displayName == "Slack")
        #expect(Self.offeredEpisode(withName)?.isAttributed == true)

        // A helper the system would not name: the prompt gets no name to show, and says so by carrying
        // none. This is the com.apple.WebKit.GPU case — a call in a browser tab.
        var anonymous = Self.armedRule()
        let helper = AudioProcessSnapshot(
            processes: [AudioProcessObservation(pid: 900, bundleID: nil, displayName: nil,
                                                isRunningInput: true)],
            isComplete: true)
        _ = anonymous.observe(helper, at: Self.at(1), context: context)
        let unnamed = anonymous.observe(helper, at: Self.at(4.1), context: context)
        #expect(Self.offeredEpisode(unnamed) != nil)
        #expect(Self.offeredEpisode(unnamed)?.displayName == nil)
        #expect(Self.offeredEpisode(unnamed)?.isAttributed == false)
    }

    @Test("a name seen earlier in the episode survives a sample that lost it")
    func aNameOnceSuppliedIsRemembered() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        _ = rule.observe(Self.holding([Self.slack], names: [Self.slack: "Slack"]),
                         at: Self.at(1), context: context)
        // The qualifying sample carries no name — resolution failed on this pass.
        let outcome = rule.observe(Self.holding([Self.slack]), at: Self.at(4.1), context: context)
        #expect(Self.offeredEpisode(outcome)?.displayName == "Slack")
    }

    @Test("several processes of one application are one episode")
    func processesOfOneApplicationCoalesce() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        // An Electron application: three processes, one of which holds the input.
        func electron(_ running: [Bool]) -> AudioProcessSnapshot {
            AudioProcessSnapshot(
                processes: running.enumerated().map { index, isRunning in
                    AudioProcessObservation(pid: Int32(300 + index), bundleID: Self.slack,
                                            displayName: "Slack", isRunningInput: isRunning)
                },
                isComplete: true)
        }
        #expect(rule.observe(electron([false, true, false]), at: Self.at(1), context: context) == .none)
        let outcome = rule.observe(electron([true, false, false]), at: Self.at(4.1), context: context)
        #expect(Self.offeredEpisode(outcome) != nil)
        // One offer, not three: the helper that hands over to another helper is the same call.
        #expect(rule.observe(electron([false, false, true]), at: Self.at(8), context: context) == .none)
    }

    // MARK: - Episodes and re-arming

    @Test("input already held when Acta launches establishes a baseline without asking")
    func theFirstSnapshotNeverOffers() {
        var rule = MicrophoneActivityRule()
        let context = MicrophoneActivityRule.Context()
        // Acta launches in the middle of a call.
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.start, context: context) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(10), context: context) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(600), context: context) == .none)
        // ...and the call ending, then a *new* one starting, does raise an offer. The baseline costs
        // this meeting, not every future one.
        #expect(rule.observe(Self.quiet, at: Self.at(601), context: context) == .none)
        #expect(rule.observe(Self.quiet, at: Self.at(700), context: context) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(701), context: context) == .none)
        let outcome = rule.observe(Self.holding([Self.slack]), at: Self.at(705), context: context)
        #expect(Self.offeredEpisode(outcome) != nil)
    }

    @Test("a brief release inside a call does not start a second episode")
    func aShortReleaseDoesNotRearm() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: context)
        #expect(Self.offeredEpisode(rule.observe(Self.holding([Self.slack]), at: Self.at(4.1),
                                                 context: context)) != nil)
        // A device handoff: the input is released for five seconds, far short of the re-arm.
        // ⚠️ Not withdrawn here: a released input inside the re-arm window is a handoff, not an ending,
        // and the episode it belongs to is still the live one.
        #expect(rule.observe(Self.quiet, at: Self.at(20), context: context) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(25), context: context) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(40), context: context) == .none)
    }

    @Test("a new call after observed silence does raise a new offer")
    func aLongReleaseRearms() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: context)
        #expect(Self.offeredEpisode(rule.observe(Self.holding([Self.slack]), at: Self.at(4.1),
                                                 context: context)) != nil)
        _ = rule.observe(Self.quiet, at: Self.at(10), context: context)
        // Thirty-one seconds of *observed* idleness closes the episode — and closing it is what makes
        // a prompt still on screen stale, so the withdrawal lands on this very sample.
        #expect(rule.observe(Self.quiet, at: Self.at(41), context: context) == .withdraw(episodeID: 1))
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(42), context: context) == .none)
        let second = rule.observe(Self.holding([Self.slack]), at: Self.at(46), context: context)
        #expect(Self.offeredEpisode(second) != nil)
        // A distinct episode, so a click on the first prompt can be refused.
        #expect(Self.offeredEpisode(second)?.id != 1)
    }

    // MARK: - Unknown is not idle

    @Test("an unreadable stretch is not an idle stretch")
    func unknownNeverClosesAnEpisode() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: context)
        #expect(Self.offeredEpisode(rule.observe(Self.holding([Self.slack]), at: Self.at(4.1),
                                                 context: context)) != nil)

        // The enumeration fails for two minutes — far longer than the re-arm. If that counted as
        // silence, the next readable sample would be a rising edge and the user would be asked twice
        // about one call.
        for second in stride(from: 10.0, through: 130.0, by: 10.0) {
            #expect(rule.observe(.unreadable, at: Self.at(second), context: context) == .none)
        }
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(140), context: context) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(200), context: context) == .none)
    }

    @Test("a partial snapshot is not evidence that a missing application stopped")
    func anIncompleteSnapshotIsNotARelease() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: context)
        #expect(Self.offeredEpisode(rule.observe(Self.holding([Self.slack]), at: Self.at(4.1),
                                                 context: context)) != nil)
        // Slack is simply absent from a snapshot that admits it is partial.
        let partial = AudioProcessSnapshot(processes: [], isComplete: false)
        for second in stride(from: 10.0, through: 130.0, by: 10.0) {
            #expect(rule.observe(partial, at: Self.at(second), context: context) == .none)
        }
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(140), context: context) == .none)
    }

    @Test("a qualification clock cannot complete across an unreadable gap")
    func unknownRestartsTheHold() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        // One second of observed hold, then the reads fail for a minute.
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: context) == .none)
        #expect(rule.observe(.unreadable, at: Self.at(2), context: context) == .none)
        // Coming back sixty seconds later, the *elapsed* time exceeds the hold many times over — but
        // none of it was observed, so it may not qualify anything.
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(62), context: context) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(63), context: context) == .none)
        // Three seconds of genuine observation later, it qualifies.
        #expect(Self.offeredEpisode(rule.observe(Self.holding([Self.slack]), at: Self.at(65.1),
                                                 context: context)) != nil)
    }

    @Test("a re-arm cannot complete across an unreadable gap either")
    func unknownRestartsTheRearm() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: context)
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(4.1), context: context)
        _ = rule.observe(Self.quiet, at: Self.at(10), context: context)      // releasing since 10
        _ = rule.observe(.unreadable, at: Self.at(12), context: context)     // gap
        // Back at t=100: 90 s have passed, but the release was only observed for 2 s of it.
        #expect(rule.observe(Self.quiet, at: Self.at(100), context: context) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(105), context: context) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(120), context: context) == .none)
    }

    // MARK: - Suppression

    @Test("an excluded application never offers, and stays spent when the exclusion is lifted")
    func exclusionSpendsTheEpisode() {
        var rule = Self.armedRule()
        let excluded = MicrophoneActivityRule.Context(excludedBundleIDs: [Self.slack])
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: excluded)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(4.1), context: excluded) == .none)
        // Removing the exclusion mid-call does not retro-ask about the call already under way.
        let included = MicrophoneActivityRule.Context()
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(10), context: included) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(300), context: included) == .none)
    }

    @Test("a recording already running suppresses the offer and spends the episode")
    func busySpendsTheEpisode() {
        var rule = Self.armedRule()
        let busy = MicrophoneActivityRule.Context(isBusy: true)
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: busy)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(4.1), context: busy) == .none)
        // ⚠️ Stopping that recording must not immediately ask whether to record the same call: the one
        // moment the answer is obviously no is right after the user chose to stop.
        let idle = MicrophoneActivityRule.Context()
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(20), context: idle) == .none)
    }

    @Test("the menu being open suppresses the offer")
    func anOpenMenuSuppresses() {
        var rule = Self.armedRule()
        let open = MicrophoneActivityRule.Context(isMenuOpen: true)
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: open)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(4.1), context: open) == .none)
    }

    @Test("the preference off means no offer ever")
    func disabledNeverOffers() {
        var rule = Self.armedRule()
        let off = MicrophoneActivityRule.Context(isEnabled: false)
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: off)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(4.1), context: off) == .none)
        #expect(rule.observe(Self.holding([Self.slack]), at: Self.at(400), context: off) == .none)
    }

    @Test("Acta's own capture never offers to record itself")
    func ownCaptureIsInvisible() {
        let context = MicrophoneActivityRule.Context(ownBundleIDs: ["dev.personal.acta",
                                                                    "dev.personal.acta-dev"],
                                                     ownPIDs: [4242])
        var byBundle = Self.armedRule()
        let stableFlavor = Self.holding(["dev.personal.acta"])
        _ = byBundle.observe(stableFlavor, at: Self.at(1), context: context)
        #expect(byBundle.observe(stableFlavor, at: Self.at(4.1), context: context) == .none)
        #expect(byBundle.observe(stableFlavor, at: Self.at(60), context: context) == .none)

        // And by pid, which is the only identity a helper without a bundle id has.
        var byPID = Self.armedRule()
        let helper = AudioProcessSnapshot(
            processes: [AudioProcessObservation(pid: 4242, bundleID: nil, isRunningInput: true)],
            isComplete: true)
        _ = byPID.observe(helper, at: Self.at(1), context: context)
        #expect(byPID.observe(helper, at: Self.at(4.1), context: context) == .none)
    }

    // MARK: - Withdrawal

    @Test("the offer is withdrawn when its call ends")
    func anEndedEpisodeWithdrawsItsOffer() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: context)
        let episode = Self.offeredEpisode(rule.observe(Self.holding([Self.slack]), at: Self.at(4.1),
                                                       context: context))
        #expect(episode != nil)
        _ = rule.observe(Self.quiet, at: Self.at(10), context: context)
        _ = rule.observe(Self.quiet, at: Self.at(45), context: context)   // re-arm elapses, episode gone
        // Withdrawn exactly once — a second one would be a UI event about nothing.
        var withdrawals = 0
        for second in stride(from: 46.0, through: 60.0, by: 2.0) {
            if case .withdraw = rule.observe(Self.quiet, at: Self.at(second), context: context) {
                withdrawals += 1
            }
        }
        #expect(withdrawals <= 1)
        #expect(rule.observe(Self.quiet, at: Self.at(100), context: context) == .none)
    }

    @Test("an offer already resolved is not withdrawn afterwards")
    func aResolvedOfferProducesNoWithdrawal() {
        var rule = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        _ = rule.observe(Self.holding([Self.slack]), at: Self.at(1), context: context)
        let episode = Self.offeredEpisode(rule.observe(Self.holding([Self.slack]), at: Self.at(4.1),
                                                       context: context))!
        rule.offerResolved(episodeID: episode.id)
        _ = rule.observe(Self.quiet, at: Self.at(10), context: context)
        for second in stride(from: 45.0, through: 80.0, by: 5.0) {
            #expect(rule.observe(Self.quiet, at: Self.at(second), context: context) == .none)
        }
    }

    // MARK: - Determinism

    @Test("two applications qualifying in the same sample are ordered, not raced")
    func simultaneousQualificationIsDeterministic() {
        let both = ["com.apple.FaceTime", Self.slack]
        var first = Self.armedRule()
        var second = Self.armedRule()
        let context = MicrophoneActivityRule.Context()
        _ = first.observe(Self.holding(both), at: Self.at(1), context: context)
        _ = second.observe(Self.holding(both), at: Self.at(1), context: context)
        let a = Self.offeredEpisode(first.observe(Self.holding(both), at: Self.at(4.1),
                                                  context: context))
        let b = Self.offeredEpisode(second.observe(Self.holding(both), at: Self.at(4.1),
                                                   context: context))
        #expect(a?.bundleID != nil)
        #expect(a?.bundleID == b?.bundleID)
        // One prompt, never two stacked: the other application's episode is spent silently.
        #expect(first.observe(Self.holding(both), at: Self.at(10), context: context) == .none)
    }
}
