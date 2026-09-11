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

    @Test("a conversation that resumed cancels the reminder rather than merely deferring it")
    func aResumedConversationCancelsTheSnooze() {
        // ⚠️ **Cancellation, not suppression, and the difference is the whole point.** Codex was right
        // that the previous version of this test proved only that a prompt is withheld *while* people
        // are talking. The failure it must rule out is the other one: the meeting resumes, pauses again
        // for a moment, and the half-hour reminder fires into a live conversation.
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 520, microphone: Self.background, system: Self.background)
        _ = rule.evaluate(at: Self.at(520), context: Self.context)
        rule.armSnooze(until: Self.at(2_320), recordingID: 1)

        // People come back for a few minutes...
        Self.feed(&rule, from: 520, to: 800, microphone: Self.speech, system: Self.speech)
        // ...and then the room goes quiet again, for longer than the whole quiet interval.
        Self.feed(&rule, from: 800, to: 2_400, microphone: Self.background, system: Self.background)
        // The reminder is gone, not merely postponed: nothing is asked, then or later.
        #expect(rule.evaluate(at: Self.at(2_330), context: Self.context) == .none)
        #expect(rule.evaluate(at: Self.at(2_400), context: Self.context) == .none)
    }

    @Test("a meter hiccup is not a resumed conversation and does not cancel the reminder")
    func anUnknownStretchLeavesTheSnoozeArmed() {
        // ⚠️ The converse, so cancellation does not quietly become "any interruption cancels it".
        var rule = Self.armed()
        Self.feed(&rule, from: 0, to: 60, microphone: Self.background, system: Self.background)
        Self.feed(&rule, from: 60, to: 200, microphone: Self.speech, system: Self.speech)
        Self.feed(&rule, from: 200, to: 520, microphone: Self.background, system: Self.background)
        _ = rule.evaluate(at: Self.at(520), context: Self.context)
        rule.armSnooze(until: Self.at(1_400), recordingID: 1)
        // The meter fails for a while, then recovers, and the room was quiet throughout.
        Self.feed(&rule, from: 520, to: 560, microphone: { _ in nil }, system: Self.background)
        Self.feed(&rule, from: 560, to: 1_410, microphone: Self.background, system: Self.background)
        #expect(rule.evaluate(at: Self.at(1_410), context: Self.context) == .offerStop(recordingID: 1))
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

/// The two traces Codex executed against the committed rule, at default configuration.
///
/// ⚠️ Both produce an **actual erroneous offer** without the fix, so they are regressions rather than
/// hypotheticals. Both are written at the exact instant the quiet threshold is crossed, which is where
/// a "it settles down eventually" fix would still be wrong.
@Suite("Audio activity rule: failures at the threshold")
struct AudioActivityThresholdTests {
    private static let start = Date(timeIntervalSince1970: 5_000_000)
    private static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
    private static let context = AudioActivityRule.Context(isEnabled: true, recordingID: 1)

    /// One second of both tracks, once per second, exactly as Codex's reproducer does.
    private static func feed(_ rule: inout AudioActivityRule, from: Int, through: Int,
                             microphone: Double?, system: Double?) {
        for second in from...through {
            rule.ingest(AudioActivitySummary(track: .microphone, generation: 1, duration: 1,
                                             power: microphone), at: at(Double(second)))
            rule.ingest(AudioActivitySummary(track: .system, generation: 1, duration: 1,
                                             power: system), at: at(Double(second)))
        }
    }

    private static func silentRule() -> AudioActivityRule {
        var rule = AudioActivityRule()
        rule.beginRecording(1, generation: 1)
        feed(&rule, from: 0, through: 358, microphone: -100, system: -100)
        return rule
    }

    @Test("the first unmeasurable buffer at the threshold withholds the offer")
    func aFailedMeasurementAtTheThresholdIsNotQuiet() {
        var rule = Self.silentRule()
        // The measurement fails exactly as five minutes of quiet completes.
        rule.ingest(AudioActivitySummary(track: .microphone, generation: 1, duration: 1, power: nil),
                    at: Self.at(359))
        rule.ingest(AudioActivitySummary(track: .system, generation: 1, duration: 1, power: -100),
                    at: Self.at(359))
        #expect(rule.state(of: .microphone, at: Self.at(359)) == .unknown)
        #expect(rule.evaluate(at: Self.at(359), context: Self.context) == .none)
    }

    @Test("a non-finite measurement is refused the same way")
    func aNonFiniteMeasurementAtTheThresholdIsNotQuiet() {
        var rule = Self.silentRule()
        rule.ingest(AudioActivitySummary(track: .microphone, generation: 1, duration: 1,
                                         power: Double.nan), at: Self.at(359))
        rule.ingest(AudioActivitySummary(track: .system, generation: 1, duration: 1, power: -100),
                    at: Self.at(359))
        #expect(rule.state(of: .microphone, at: Self.at(359)) == .unknown)
        #expect(rule.evaluate(at: Self.at(359), context: Self.context) == .none)
    }

    @Test("a measurement that recovers is trusted again")
    func measurementRecoveryRestoresEvidence() {
        // ⚠️ The other half: invalidating on failure must not be a one-way door.
        var rule = Self.silentRule()
        rule.ingest(AudioActivitySummary(track: .microphone, generation: 1, duration: 1, power: nil),
                    at: Self.at(359))
        Self.feed(&rule, from: 360, through: 700, microphone: -100, system: -100)
        #expect(rule.state(of: .microphone, at: Self.at(700)) == .quiet)
        #expect(rule.evaluate(at: Self.at(700), context: Self.context) == .offerStop(recordingID: 1))
    }

    @Test("remote speech arriving at the threshold is not hidden by a silent history")
    func speechAtTheThresholdOutranksTheWindow() {
        // ⚠️ Six minutes of digital silence keep the ninetieth percentile at the floor, so the history
        // still looks silent when somebody starts talking. What is happening now outranks it.
        var rule = Self.silentRule()
        rule.ingest(AudioActivitySummary(track: .microphone, generation: 1, duration: 1, power: -100),
                    at: Self.at(359))
        rule.ingest(AudioActivitySummary(track: .system, generation: 1, duration: 1, power: -20),
                    at: Self.at(359))
        #expect(rule.state(of: .system, at: Self.at(359)) == .active)
        #expect(rule.evaluate(at: Self.at(359), context: Self.context) == .none)
    }

    @Test("speech on the microphone at the threshold is not hidden either")
    func microphoneSpeechAtTheThresholdOutranksTheWindow() {
        var rule = Self.silentRule()
        rule.ingest(AudioActivitySummary(track: .microphone, generation: 1, duration: 1, power: -20),
                    at: Self.at(359))
        rule.ingest(AudioActivitySummary(track: .system, generation: 1, duration: 1, power: -100),
                    at: Self.at(359))
        #expect(rule.state(of: .microphone, at: Self.at(359)) == .active)
        #expect(rule.evaluate(at: Self.at(359), context: Self.context) == .none)
    }

    @Test("speech arriving while an offer stands withdraws it")
    func speechWithdrawsAStandingOfferOutOfASilentHistory() {
        var rule = Self.silentRule()
        Self.feed(&rule, from: 359, through: 400, microphone: -100, system: -100)
        #expect(rule.evaluate(at: Self.at(400), context: Self.context) == .offerStop(recordingID: 1))
        rule.ingest(AudioActivitySummary(track: .system, generation: 1, duration: 1, power: -20),
                    at: Self.at(401))
        #expect(rule.evaluate(at: Self.at(401), context: Self.context) == .withdraw(recordingID: 1))
    }

    @Test("an absurd finite power degrades the hint instead of trapping the conversion")
    func anAbsurdPowerDoesNotTrap() {
        // ⚠️ `Int(_:)` traps on a finite Double too large for `Int`, and a meter reporting nonsense must
        // never be able to take a recording down with it.
        var rule = AudioActivityRule()
        rule.beginRecording(1, generation: 1)
        for second in 0...120 {
            rule.ingest(AudioActivitySummary(track: .microphone, generation: 1, duration: 1,
                                             power: 1e308), at: Self.at(Double(second)))
            rule.ingest(AudioActivitySummary(track: .system, generation: 1, duration: 1,
                                             power: -1e308), at: Self.at(Double(second)))
        }
        #expect(rule.evaluate(at: Self.at(120), context: Self.context) == .none)
    }
}
