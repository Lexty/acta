import ActaKit
import Foundation
import Testing

/// `AudioActivityRule` — "has this recording been quiet long enough to be worth asking about?".
///
/// ⚠️ **A detector that only ever withholds is not a finished feature**, so this suite leads with the
/// positive case: ordinary room noise, then speech, then sustained quiet, and an offer at the end of it.
/// The negatives follow.
///
/// ⚠️ Every number here is a **proposed default awaiting acoustic validation on real recordings**. What
/// these tests establish is that the decision procedure behaves as designed, not that −52 dBFS is what a
/// particular flat sounds like.
@Suite("Audio activity rule")
struct AudioActivityRuleTests {
    private static let start = Date(timeIntervalSince1970: 2_000_000)
    private static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// Room tone with a little life in it, deterministic so the suite cannot flake.
    private static func background(_ index: Int) -> Double {
        let pattern: [Double] = [-58, -54, -61, -56, -52, -59, -55, -57]
        return pattern[index % pattern.count]
    }

    private static func speech(_ index: Int) -> Double {
        let pattern: [Double] = [-28, -22, -35, -25, -31, -20, -33, -26]
        return pattern[index % pattern.count]
    }

    /// Feed both tracks at 2 Hz between two times.
    @discardableResult
    private static func feed(_ rule: inout AudioActivityRule,
                             from: TimeInterval,
                             to: TimeInterval,
                             generation: UInt64 = 1,
                             microphone: (Int) -> Double?,
                             system: (Int) -> Double?) -> Int {
        var index = Int(from * 2)
        var time = from
        while time < to {
            rule.ingest(AudioActivitySummary(track: .microphone, generation: generation,
                                             duration: 0.5, power: microphone(index)),
                        at: at(time))
            rule.ingest(AudioActivitySummary(track: .system, generation: generation,
                                             duration: 0.5, power: system(index)),
                        at: at(time))
            index += 1
            time += 0.5
        }
        return index
    }

    private static func armed(_ configuration: AudioActivityRule.Configuration = .default)
        -> AudioActivityRule {
        var rule = AudioActivityRule(configuration: configuration)
        rule.beginRecording(1, generation: 1)
        return rule
    }

    private static let context = AudioActivityRule.Context(isEnabled: true, recordingID: 1)

    // MARK: - The positive case

    @Test("room noise, then a meeting, then five minutes of quiet, and it offers")
    func aRealMeetingThatEndsIsOffered() {
        var rule = Self.armed()
        // A minute of room tone to warm the estimate, then four minutes of conversation.
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 300, microphone: Self.speech, system: Self.speech)
        #expect(rule.evaluate(at: Self.at(300), context: Self.context) == .none)
        #expect(rule.state(of: .microphone, at: Self.at(300)) == .active)

        // Everyone leaves. The room is still the room.
        Self.feed(&rule, from: 300, to: 320, microphone: Self.background, system: Self.background)
        #expect(rule.state(of: .microphone, at: Self.at(320)) == .quiet)
        #expect(rule.state(of: .system, at: Self.at(320)) == .quiet)
        #expect(rule.evaluate(at: Self.at(320), context: Self.context) == .none)

        // Four minutes in it is still not asking...
        Self.feed(&rule, from: 320, to: 560, microphone: Self.background, system: Self.background)
        #expect(rule.evaluate(at: Self.at(560), context: Self.context) == .none)
        // ...and past five it does.
        Self.feed(&rule, from: 560, to: 625, microphone: Self.background, system: Self.background)
        #expect(rule.evaluate(at: Self.at(625), context: Self.context) == .offerStop(recordingID: 1))
    }

    @Test("it asks once per recording, not once every five minutes")
    func theOfferIsSpentAfterItIsMade() {
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 520, microphone: Self.background, system: Self.background)
        #expect(rule.evaluate(at: Self.at(520), context: Self.context) == .offerStop(recordingID: 1))
        Self.feed(&rule, from: 520, to: 1_200, microphone: Self.background, system: Self.background)
        #expect(rule.evaluate(at: Self.at(1_200), context: Self.context) == .none)
    }

    // MARK: - Why it holds back

    @Test("someone listening to a presentation is not an idle recording")
    func remoteSpeechAloneKeepsTheClockAtZero() {
        // ⚠️ The accepted trade, stated as a test: the system track holds the recording on its own, so
        // unrelated music will also prevent an offer. That false negative is preferable to declaring a
        // meeting over while somebody is talking.
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 900, microphone: Self.background, system: Self.speech)
        #expect(rule.state(of: .microphone, at: Self.at(900)) == .quiet)
        #expect(rule.state(of: .system, at: Self.at(900)) == .active)
        #expect(rule.evaluate(at: Self.at(900), context: Self.context) == .none)
    }

    @Test("a recording that begins mid-sentence does not learn speech as its background")
    func warmUpProtectsAgainstAMidSentenceStart() {
        // ⚠️ The defect a rolling low percentile has by construction: it learns whatever it hears most
        // of. Without the warm-up, ten minutes of continuous speech becomes "the floor" and the next
        // ordinary pause reads as silence.
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 30, microphone: Self.speech, system: Self.speech)
        #expect(rule.state(of: .microphone, at: Self.at(30)) == .warmingUp)
        #expect(rule.evaluate(at: Self.at(30), context: Self.context) == .none)
        // Even once warm, continuous speech is not quiet.
        Self.feed(&rule, from: 30, to: 700, microphone: Self.speech, system: Self.speech)
        #expect(rule.evaluate(at: Self.at(700), context: Self.context) == .none)
    }

    @Test("a level that never varies is not called silence, it is called indistinguishable")
    func aFlatSignalWithholdsTheOffer() {
        // ⚠️ A constant tone and a constantly-talking room look the same to this estimator. Saying so is
        // the honest answer; calling it quiet is the failure the whole feature must not have.
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 700, microphone: { _ in -50 }, system: { _ in -50 })
        #expect(rule.state(of: .microphone, at: Self.at(700)) == .indistinguishable)
        #expect(rule.evaluate(at: Self.at(700), context: Self.context) == .none)
    }

    // MARK: - Unknown is not quiet

    @Test("a track that stopped reporting is unknown, and the clock resets")
    func amissingTrackIsNotQuiet() {
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 400, microphone: Self.background, system: Self.background)
        #expect(rule.evaluate(at: Self.at(400), context: Self.context) == .none)
        // The microphone track stalls. Three hundred seconds later the elapsed time would be enough —
        // but none of it was evidence.
        Self.feed(&rule, from: 400, to: 800, microphone: { _ in nil }, system: Self.background)
        #expect(rule.state(of: .microphone, at: Self.at(800)) != .quiet)
        #expect(rule.evaluate(at: Self.at(800), context: Self.context) == .none)
    }

    @Test("no summaries at all is unknown rather than silence")
    func aStalledMeterIsNotSilence() {
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 300, microphone: Self.background, system: Self.background)
        // Nothing arrives for ten minutes: the process is alive, the meter is not.
        #expect(rule.state(of: .microphone, at: Self.at(900)) == .unknown)
        #expect(rule.evaluate(at: Self.at(900), context: Self.context) == .none)
    }

    @Test("a capture restart discards the calibration rather than carrying it over")
    func aGenerationChangeStartsFresh() {
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 520, microphone: Self.background, system: Self.background)
        // A device change: everything learned describes audio that no longer exists.
        rule.beginGeneration(2)
        #expect(rule.state(of: .microphone, at: Self.at(520)) == .unknown)
        Self.feed(&rule, from: 520, to: 560, generation: 2,
                  microphone: Self.background, system: Self.background)
        #expect(rule.state(of: .microphone, at: Self.at(560)) == .warmingUp)
        #expect(rule.evaluate(at: Self.at(560), context: Self.context) == .none)
    }

    @Test("summaries from the previous capture are refused")
    func aStaleGenerationCannotWarmTheNewOne() {
        var rule = Self.armed()
        rule.beginGeneration(2)
        // A callback still in flight from the capture that just ended.
        Self.feed(&rule, from: 0, to: 700, generation: 1,
                  microphone: Self.background, system: Self.background)
        #expect(rule.state(of: .microphone, at: Self.at(700)) == .unknown)
    }

    // MARK: - Standing offers and snoozes

    @Test("sound returning withdraws a standing offer")
    func soundReturningWithdrawsTheOffer() {
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 520, microphone: Self.background, system: Self.background)
        #expect(rule.evaluate(at: Self.at(520), context: Self.context) == .offerStop(recordingID: 1))
        // Somebody says something while the prompt is still up.
        Self.feed(&rule, from: 520, to: 540, microphone: Self.speech, system: Self.background)
        #expect(rule.evaluate(at: Self.at(540), context: Self.context) == .withdraw(recordingID: 1))
        // Withdrawn once, not on every evaluation afterwards.
        #expect(rule.evaluate(at: Self.at(541), context: Self.context) == .none)
    }

    @Test("a snooze is bound to its recording and re-checked when it comes due")
    func aSnoozeIsRecheckedRatherThanFired() {
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 520, microphone: Self.background, system: Self.background)
        #expect(rule.evaluate(at: Self.at(520), context: Self.context) == .offerStop(recordingID: 1))
        rule.armSnooze(until: Self.at(2_320), recordingID: 1)

        // Half an hour of continued quiet: it comes due and asks again.
        Self.feed(&rule, from: 520, to: 2_330, microphone: Self.background, system: Self.background)
        #expect(rule.evaluate(at: Self.at(2_000), context: Self.context) == .none)
        #expect(rule.evaluate(at: Self.at(2_330), context: Self.context) == .offerStop(recordingID: 1))
    }

    @Test("a conversation that resumed cancels the reminder instead of asking about a live meeting")
    func aResumedConversationDefusesTheSnooze() {
        // ⚠️ The whole reason the snooze is re-checked rather than fired: a guaranteed prompt half an
        // hour later is a prompt to stop a meeting that is under way.
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 520, microphone: Self.background, system: Self.background)
        _ = rule.evaluate(at: Self.at(520), context: Self.context)
        rule.armSnooze(until: Self.at(2_320), recordingID: 1)
        // People come back and keep talking straight through the reminder.
        Self.feed(&rule, from: 520, to: 2_400, microphone: Self.speech, system: Self.speech)
        #expect(rule.evaluate(at: Self.at(2_400), context: Self.context) == .none)
    }

    @Test("a snooze does not survive into the next recording")
    func aSnoozeBelongsToOneRecording() {
        var rule = Self.armed()
        rule.armSnooze(until: Self.at(100), recordingID: 1)
        rule.beginRecording(2, generation: 2)
        Self.feed(&rule, from: 0, to: 60, generation: 2,
                  microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, generation: 2,
                  microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 520, generation: 2,
                  microphone: Self.background, system: Self.background)
        let second = AudioActivityRule.Context(isEnabled: true, recordingID: 2)
        // The fresh recording gets its own single offer, unaffected by the previous one's snooze.
        #expect(rule.evaluate(at: Self.at(520), context: second) == .offerStop(recordingID: 2))
    }

    // MARK: - The preference

    @Test("switched off, it never offers")
    func disabledNeverOffers() {
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 900, microphone: Self.background, system: Self.background)
        let off = AudioActivityRule.Context(isEnabled: false, recordingID: 1)
        #expect(rule.evaluate(at: Self.at(900), context: off) == .none)
    }

    @Test("switching the reminder off discards the quiet history rather than banking it")
    func invalidationResetsTheEstimate() {
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 500, microphone: Self.background, system: Self.background)
        rule.invalidate()
        #expect(rule.state(of: .microphone, at: Self.at(500)) == .unknown)
        // Re-enabled, it starts from a fresh warm-up instead of inheriting five minutes of quiet.
        Self.feed(&rule, from: 500, to: 530, microphone: Self.background, system: Self.background)
        #expect(rule.state(of: .microphone, at: Self.at(530)) == .warmingUp)
        #expect(rule.evaluate(at: Self.at(530), context: Self.context) == .none)
    }

    // MARK: - Numbers

    @Test("digital silence is a finite value, not an infinity")
    func digitalZeroIsClamped() {
        var rule = Self.armed()
        // An exact-zero stream: the meter reports the configured floor rather than −infinity, which
        // would poison every average it touched.
        Self.feed(&rule, from: 0, to: 700, microphone: { _ in -.infinity },
                  system: { _ in -.infinity })
        // Non-finite input is refused as a measurement rather than clamped into evidence, so the track
        // reads as unknown: the meter is running and blind, which is not the same as quiet.
        #expect(rule.state(of: .microphone, at: Self.at(700)) == .unknown)
    }

    @Test("the floor may fall freely and rise only slowly")
    func theFloorRisesUnderABound() {
        // ⚠️ A floor allowed to climb without limit eventually reaches speech and calls it background.
        var configuration = AudioActivityRule.Configuration.default
        configuration.maxFloorRisePerMinute = 1
        var rule = AudioActivityRule(configuration: configuration)
        rule.beginRecording(1, generation: 1)
        Self.feed(&rule, from: 0, to: 120, microphone: Self.background, system: Self.background)
        // The room suddenly becomes much louder and stays there. If the floor could follow freely, this
        // level would become "background" within one window and the recording would read as quiet.
        Self.feed(&rule, from: 120, to: 400, microphone: { _ in -30 }, system: { _ in -30 })
        #expect(rule.state(of: .microphone, at: Self.at(400)) == .active)
        #expect(rule.evaluate(at: Self.at(400), context: Self.context) == .none)
    }
}

/// Digital silence, which is a measurement and not an ambiguity.
@Suite("Audio activity rule: measured silence")
struct AudioActivitySilenceTests {
    private static let start = Date(timeIntervalSince1970: 4_000_000)
    private static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private static func feed(_ rule: inout AudioActivityRule, from: TimeInterval, to: TimeInterval,
                             microphone: (Int) -> Double, system: (Int) -> Double) {
        var index = Int(from * 2)
        var time = from
        while time < to {
            rule.ingest(AudioActivitySummary(track: .microphone, generation: 1, duration: 0.5,
                                             power: microphone(index)), at: at(time))
            rule.ingest(AudioActivitySummary(track: .system, generation: 1, duration: 0.5,
                                             power: system(index)), at: at(time))
            index += 1
            time += 0.5
        }
    }

    private static func room(_ index: Int) -> Double {
        [-58.0, -54, -61, -56, -52, -59, -55, -57][index % 8]
    }
    private static func voice(_ index: Int) -> Double {
        [-28.0, -22, -35, -25, -31, -20, -33, -26][index % 8]
    }

    @Test("a recording with nobody on the other end can still be offered")
    func aSilentSystemTrackDoesNotBlockForEver() {
        // ⚠️ The case that made this a blocker: an in-person recording. The system track is digital
        // silence for its whole life, so its spread is zero for ever — and a spread test alone would
        // call that "indistinguishable" and never offer, no matter how good the microphone evidence is.
        var rule = AudioActivityRule()
        rule.beginRecording(1, generation: 1)
        let context = AudioActivityRule.Context(isEnabled: true, recordingID: 1)
        Self.feed(&rule, from: 0, to: 60, microphone: Self.room, system: { _ in -140 })
        Self.feed(&rule, from: 60, to: 200, microphone: Self.voice, system: { _ in -140 })
        #expect(rule.state(of: .system, at: Self.at(200)) == .quiet)
        #expect(rule.evaluate(at: Self.at(200), context: context) == .none)

        Self.feed(&rule, from: 200, to: 520, microphone: Self.room, system: { _ in -140 })
        #expect(rule.evaluate(at: Self.at(520), context: context) == .offerStop(recordingID: 1))
    }

    @Test("both tracks at digital zero is quiet, not ambiguous")
    func pureSilenceOnBothTracksIsQuiet() {
        var rule = AudioActivityRule()
        rule.beginRecording(1, generation: 1)
        let context = AudioActivityRule.Context(isEnabled: true, recordingID: 1)
        Self.feed(&rule, from: 0, to: 420, microphone: { _ in -140 }, system: { _ in -140 })
        #expect(rule.state(of: .microphone, at: Self.at(420)) == .quiet)
        #expect(rule.evaluate(at: Self.at(420), context: context) == .offerStop(recordingID: 1))
    }

    @Test("a constant audible level is still refused as ambiguous")
    func aConstantHumIsStillWithheld() {
        // ⚠️ The distinction the fix must not erase: a hum at −50 dBFS and a room talking constantly
        // look identical to this estimator, and that is still a reason to say nothing.
        var rule = AudioActivityRule()
        rule.beginRecording(1, generation: 1)
        let context = AudioActivityRule.Context(isEnabled: true, recordingID: 1)
        Self.feed(&rule, from: 0, to: 420, microphone: { _ in -50 }, system: { _ in -50 })
        #expect(rule.state(of: .microphone, at: Self.at(420)) == .indistinguishable)
        #expect(rule.evaluate(at: Self.at(420), context: context) == .none)
    }
}
