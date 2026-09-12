import ActaKit
import Foundation
import Testing

/// `MicrophoneOwnershipRule` — has the owner of a recording let the microphone go?
///
/// ⚠️ **Every test states its timestamps.** The rule has no clock, so qualification, revocation and gaps
/// are decided by the numbers on the page rather than raced. And every snapshot that matters carries
/// `com.apple.CoreSpeech` holding beside the owner, because that is the machine this was measured on: a
/// one-holder fixture lets a rule that looks beyond its owner pass.
@Suite("Microphone ownership rule")
struct MicrophoneOwnershipRuleTests {
    private typealias Fixtures = MicrophoneOwnershipFixtures
    private typealias Rule = MicrophoneOwnershipRule

    private static let owner = Fixtures.slackHelper
    private static let ownerPID = Fixtures.slackHelperPID
    private static let otherApp = "com.zzz.dictation"

    private static func at(_ seconds: TimeInterval) -> Date { Fixtures.origin.addingTimeInterval(seconds) }

    /// A rule bound at zero, so every test reads in seconds since the binding.
    private static func boundRule() -> Rule { Rule(owner: Fixtures.binding(at: Fixtures.origin)) }

    private static func process(_ pid: Int32, _ bundleID: String?, _ input: Bool?) -> AudioProcessObservation {
        AudioProcessObservation(pid: pid, bundleID: bundleID, isRunningInput: input)
    }

    private static let coreSpeechHolding = process(Fixtures.coreSpeechPID, Fixtures.coreSpeech, true)

    /// The owner with its input as given, CoreSpeech holding, and anything else supplied.
    private static func owner(_ input: Bool?, complete: Bool = true,
                              others: [AudioProcessObservation] = []) -> AudioProcessReadings.Evidence {
        snapshot([process(ownerPID, owner, input), coreSpeechHolding] + others, complete: complete)
    }

    private static func snapshot(_ processes: [AudioProcessObservation],
                                 complete: Bool = true) -> AudioProcessReadings.Evidence {
        AudioProcessReadings.evidence(from: AudioProcessSnapshot(processes: processes, isComplete: complete),
                                      dropping: .init())
    }

    private static let held = owner(true)
    private static let released = owner(false)

    /// Feed a sequence, keeping only what the rule said.
    private static func feed(_ rule: inout Rule,
                             _ samples: [(TimeInterval, AudioProcessReadings.Evidence)]) -> [Fixtures.Emission] {
        samples.compactMap { seconds, evidence in
            let outcome = rule.observe(evidence, at: at(seconds))
            return outcome == .none ? nil : Fixtures.Emission(at: seconds, outcome: outcome)
        }
    }

    /// One sample a second from `from` through `through`, all saying the same thing.
    private static func every(_ from: TimeInterval, through: TimeInterval,
                              _ evidence: AudioProcessReadings.Evidence)
        -> [(TimeInterval, AudioProcessReadings.Evidence)] {
        stride(from: from, through: through, by: 1).map { ($0, evidence) }
    }

    // MARK: - Qualification is a sequence

    @Test("five seconds of released observations qualify, once, on the transition")
    func aContinuousReleaseQualifiesOnce() {
        var rule = Self.boundRule()
        let emissions = Self.feed(&rule, Self.every(1, through: 20, Self.released))
        #expect(emissions == [Fixtures.Emission(at: 6, outcome: .releaseQualified)])
        #expect(rule.phase == .releasedQualified)
    }

    /// ⚠️ **The measured reason this rule exists.** Every join was followed within 1.4–2.4 s by a release
    /// and a re-acquisition; an offer on the first `false` stops a recording two seconds into its call.
    @Test("a single false sample does not qualify")
    func aSingleFalseSampleDoesNotQualify() {
        var rule = Self.boundRule()
        let emissions = Self.feed(&rule, [(1, Self.held), (2, Self.released), (3, Self.held)]
                                        + Self.every(4, through: 30, Self.held))
        #expect(!emissions.contains { $0.outcome == .releaseQualified })
        #expect(rule.phase == .held(since: Self.at(3)))
    }

    @Test("an unknown observation revokes an accumulating release, and the next one starts from zero")
    func unknownRevokes() {
        var rule = Self.boundRule()
        var samples = Self.every(1, through: 5, Self.released)          // would qualify at 6
        samples.append((5.5, Self.owner(nil)))                            // an unreadable property
        samples += Self.every(6, through: 12, Self.released)
        let emissions = Self.feed(&rule, samples)
        // ⚠️ 6 is where it would have qualified had unknown been skipped over; 11 is five seconds after
        // the first released observation that followed it.
        #expect(emissions == [Fixtures.Emission(at: 11, outcome: .releaseQualified)])
    }

    @Test("a return at 4.9 s requires a full new 5 s")
    func aReturnJustBeforeQualificationStartsOver() {
        var rule = Self.boundRule()
        var samples = Self.every(0, through: 4, Self.released)
        samples.append((4.9, Self.held))
        samples += Self.every(5, through: 12, Self.released)
        let emissions = Self.feed(&rule, samples)
        #expect(emissions == [Fixtures.Emission(at: 4.9, outcome: .ownerReturned),
                              Fixtures.Emission(at: 10, outcome: .releaseQualified)])
    }

    /// ⚠️ **Both directions.** Other applications holding, idle, unreadable, appearing and vanishing must
    /// neither prevent a release nor create one. CoreSpeech alone would have kept a naive "is anything
    /// holding" rule from ever qualifying; the dictation service's `nil` would have revoked a rule that
    /// read unknown machine-wide.
    @Test("other applications never affect the owner's reading")
    func otherApplicationsAreInvisible() {
        let noise: [[AudioProcessObservation]] = [
            [Self.process(900, Self.otherApp, true)],
            [Self.process(900, Self.otherApp, nil)],
            [],
            [Self.process(900, Self.otherApp, false), Self.process(901, nil, true)],
            [Self.process(901, nil, nil)]
        ]

        var releasing = Self.boundRule()
        let released = (1...12).map { second -> (TimeInterval, AudioProcessReadings.Evidence) in
            (Double(second), Self.owner(false, others: noise[second % noise.count]))
        }
        #expect(Self.feed(&releasing, released) == [Fixtures.Emission(at: 6, outcome: .releaseQualified)])

        var holding = Self.boundRule()
        let held = (1...12).map { second -> (TimeInterval, AudioProcessReadings.Evidence) in
            (Double(second), Self.owner(true, others: noise[second % noise.count]))
        }
        #expect(Self.feed(&holding, held).isEmpty)
        #expect(holding.phase == .held(since: Self.at(0)))
    }

    /// ⚠️ **The negative control for `maxSampleGap` is this test.** Two released observations five
    /// seconds apart are not five seconds of release: the owner may have held the input the whole time in
    /// between, and nobody looked.
    @Test("a skipped poll is not a continuous release")
    func aSkippedPollRestartsTheInterval() {
        var rule = Self.boundRule()
        let emissions = Self.feed(&rule, [(1, Self.released), (2, Self.released),
                                          (6, Self.released),              // 4 s since the last look
                                          (7, Self.released), (8, Self.released),
                                          (9, Self.released), (10, Self.released), (11, Self.released)])
        #expect(emissions == [Fixtures.Emission(at: 11, outcome: .releaseQualified)])
    }

    @Test("a late tick inside the tolerated gap still counts as continuous")
    func aGapInsideTheToleranceIsContinuous() {
        var rule = Self.boundRule()
        let emissions = Self.feed(&rule, [(1, Self.released), (3.5, Self.released), (6, Self.released)])
        #expect(emissions == [Fixtures.Emission(at: 6, outcome: .releaseQualified)])
    }

    @Test("a timestamp that runs backwards is a gap, never a continuous interval")
    func aBackwardsClockIsAGap() {
        var rule = Self.boundRule()
        // ⚠️ Every forward step here is one second, so this pins the backwards half of the gap rule and
        // nothing about `maxSampleGap`: an earlier version used a 5 s forward step and failed that
        // control too, which made the control say less than it should.
        let emissions = Self.feed(&rule, Self.every(1, through: 5, Self.released)
                                        + Self.every(3, through: 9, Self.released))
        // Read as continuous, the release from 1 would qualify at the second 6; restarted at the step
        // back to 3, it qualifies five seconds later, at 8.
        #expect(emissions == [Fixtures.Emission(at: 8, outcome: .releaseQualified)])
    }

    // MARK: - Leaving a qualified release

    @Test("the owner returning to a qualified release is reported, and the next release starts over")
    func aReturnAfterQualification() {
        var rule = Self.boundRule()
        var samples = Self.every(1, through: 7, Self.released)
        samples.append((8, Self.held))
        samples += Self.every(9, through: 14, Self.released)
        #expect(Self.feed(&rule, samples) == [Fixtures.Emission(at: 6, outcome: .releaseQualified),
                                              Fixtures.Emission(at: 8, outcome: .ownerReturned),
                                              Fixtures.Emission(at: 14, outcome: .releaseQualified)])
    }

    @Test("an unknown observation during a qualified release reports the evidence lost")
    func unknownAfterQualification() {
        var rule = Self.boundRule()
        var samples = Self.every(1, through: 6, Self.released)
        samples.append((7, Self.owner(nil)))
        samples.append((8, Self.owner(nil)))
        samples.append((9, Self.held))
        let emissions = Self.feed(&rule, samples)
        // ⚠️ And leaving unknown for held says nothing more: the qualified release was already withdrawn
        // at 7, so a second event would be a second withdrawal of one thing.
        #expect(emissions == [Fixtures.Emission(at: 6, outcome: .releaseQualified),
                              Fixtures.Emission(at: 7, outcome: .evidenceLost)])
        #expect(rule.phase == .held(since: Self.at(9)))
    }

    // MARK: - The ownership fixtures Codex asked for

    /// ⚠️ **The process that held the input is exactly the one a partial list can be missing.** A
    /// visible idle sibling of the same application says nothing about it.
    @Test("a partial enumeration with a visible idle sibling never releases the owner")
    func aPartialListWithAnIdleSiblingIsUnknown() {
        var rule = Self.boundRule()
        let partial = Self.snapshot([Self.process(Self.ownerPID + 1, Self.owner, false), Self.coreSpeechHolding],
                                    complete: false)
        let emissions = Self.feed(&rule, Self.every(1, through: 30, partial))
        #expect(emissions.isEmpty)
        #expect(rule.phase == .unknown(since: Self.at(1)))

        // And it revokes a release that was already accumulating.
        var accumulating = Self.boundRule()
        let mixed = Self.every(1, through: 4, Self.released) + [(5, partial)]
            + Self.every(6, through: 9, Self.released)
        #expect(Self.feed(&accumulating, mixed).isEmpty)
    }

    @Test("a same-application sibling seen holding keeps the owner held")
    func aHoldingSiblingKeepsTheOwnerHeld() {
        var rule = Self.boundRule()
        let sibling = Self.owner(false, others: [Self.process(Self.ownerPID + 1, Self.owner, true)])
        // In both orders of enumeration, and in a partial list too: a process seen holding is holding.
        let reversed = Self.snapshot([Self.process(Self.ownerPID + 1, Self.owner, true),
                                      Self.process(Self.ownerPID, Self.owner, false)], complete: false)
        let emissions = Self.feed(&rule, Self.every(1, through: 10, sibling) + Self.every(11, through: 20, reversed))
        #expect(emissions.isEmpty)
        #expect(rule.phase == .held(since: Self.at(0)))
    }

    /// ⚠️ **Every release in the recorded traces was "object present, input now false"**, and that
    /// describes five minutes in which nobody quit anything. Quitting is a release too.
    @Test("the owner disappearing from a complete list is a release; from a partial one it is unknown")
    func disappearance() {
        let gone = Self.snapshot([Self.coreSpeechHolding])
        var quitting = Self.boundRule()
        #expect(Self.feed(&quitting, Self.every(1, through: 8, gone))
                == [Fixtures.Emission(at: 6, outcome: .releaseQualified)])

        let goneFromAPartialList = Self.snapshot([Self.coreSpeechHolding], complete: false)
        var unseen = Self.boundRule()
        #expect(Self.feed(&unseen, Self.every(1, through: 30, goneFromAPartialList)).isEmpty)
        #expect(unseen.phase == .unknown(since: Self.at(1)))
    }

    /// ⚠️ **As the reader actually reports it.** `AudioProcessProjection` turns a bundle identifier it
    /// could not read, for a pid it never identified, into a pid-keyed observation with no input evidence
    /// in an *incomplete* snapshot (`an unreadable identifier we never knew degrades the snapshot instead
    /// of inventing a key`). The owner's process under that disguise must not look like the owner gone.
    @Test("an unresolved identity is unknown, never a release")
    func anUnresolvedIdentityIsUnknown() {
        let unresolved = Self.snapshot([Self.process(Self.ownerPID, nil, nil), Self.coreSpeechHolding],
                                       complete: false)
        var rule = Self.boundRule()
        let emissions = Self.feed(&rule, Self.every(1, through: 4, Self.released)
                                        + Self.every(5, through: 30, unresolved))
        #expect(emissions.isEmpty)
        #expect(rule.phase == .unknown(since: Self.at(5)))
    }

    /// ⚠️ **A countdown on screen when the samples stop** — a sleep, a wedged tick. The user was
    /// promised the whole interval to cancel in, and did not get it; the evidence behind the offer is
    /// withdrawn, and a new offer needs a full fresh release first.
    @Test("an observation gap during a visible countdown withdraws the evidence behind it")
    func aGapDuringACountdown() {
        var rule = Self.boundRule()
        var samples = Self.every(1, through: 8, Self.released)   // qualified at 6, countdown running
        samples += Self.every(40, through: 46, Self.released)    // a 32 s hole, then released again
        #expect(Self.feed(&rule, samples) == [Fixtures.Emission(at: 6, outcome: .releaseQualified),
                                              Fixtures.Emission(at: 40, outcome: .evidenceLost),
                                              Fixtures.Emission(at: 45, outcome: .releaseQualified)])
    }

    // MARK: - Replays of the recorded traces

    /// Production samples at 1 Hz; the probe that recorded the traces sampled at 250 ms. Offsets are
    /// sixteenths of a period so every timestamp is exact in binary and the oracle's bounds are not at the
    /// mercy of rounding.
    private static let phaseSteps = 16

    /// ⚠️ **Stated in both directions, and against the trace rather than against the rule.**
    /// - No qualification may happen unless the trace shows the owner released, continuously, for the
    ///   full interval before it. That is "no flap qualifies", without naming the flaps.
    /// - Every release that lasted at least the interval plus one period qualifies exactly once, within
    ///   one period of the earliest instant it could, and a return after it is reported at the first
    ///   sample that sees the return.
    /// - A release in between those two lengths could go either way depending on phase, so the fixture
    ///   must not contain one — checked, not assumed.
    ///
    /// ⚠️ **This judges the rule's logic, not its 5 s.** The oracle reads the configured interval, and
    /// every recorded flap is shorter than one second, so the replay stays green with a 1 s interval too —
    /// measured, as a control. The number is pinned by the unit tests above; what this catches is a rule
    /// that accumulates a release across a return, which failed it at every offset.
    @Test("every recorded trace at every phase offset: no flap qualifies, and every real release does",
          arguments: [1.0, 0.25])
    func replayedTraces(period: TimeInterval) {
        let interval = Rule.Configuration.default.releaseQualification
        let tolerance = 1e-9
        for trace in Fixtures.allTraces {
            #expect(!trace.releases.contains { $0.until - $0.from >= interval && $0.until - $0.from < interval + period },
                    "\(trace.name) has a release whose qualification depends on phase; the oracle cannot judge it")
            let genuine = trace.releases.filter { $0.until - $0.from >= interval + period }

            for step in 0..<Self.phaseSteps {
                let offset = period * Double(step) / Double(Self.phaseSteps)
                let label = "\(trace.name), period \(period), offset \(offset)"
                let emissions = Fixtures.replay(trace, period: period, offset: offset)
                let qualifications = emissions.filter { $0.outcome == .releaseQualified }

                #expect(!emissions.contains { $0.outcome == .evidenceLost },
                        "\(label): a complete, gapless replay lost evidence")
                for qualification in qualifications {
                    let release = trace.releases.first { $0.from <= qualification.at && qualification.at < $0.until }
                    #expect(release.map { qualification.at - $0.from >= interval } == true,
                            "\(label): qualified at \(qualification.at) without \(interval) s of release behind it")
                }
                #expect(qualifications.count == genuine.count, "\(label): \(emissions)")
                for release in genuine {
                    let inside = qualifications.filter { $0.at >= release.from && $0.at < release.until }
                    #expect(inside.count == 1, "\(label): release at \(release.from)")
                    if let first = inside.first {
                        #expect(first.at < release.from + interval + period + tolerance,
                                "\(label): release at \(release.from) qualified late, at \(first.at)")
                    }
                    guard release.endsInHold, let qualified = inside.first else { continue }
                    let next = emissions.first { $0.at > qualified.at }
                    #expect(next?.outcome == .ownerReturned, "\(label): return after \(release.from)")
                    #expect(next.map { $0.at >= release.until && $0.at < release.until + period } == true,
                            "\(label): return at \(release.until) reported at \(String(describing: next?.at))")
                }
            }
        }
    }

    /// ⚠️ **The fixture has to be able to fail.** A replay oracle over traces with no flap in them would
    /// pass any rule. With qualification set to zero — the naive "a sample said false" — the recorded
    /// huddle stops its own call inside the pre-join flap.
    @Test("the recorded traces would have stopped the call under a naive rule")
    func theTracesHaveTeeth() {
        let naive = Rule.Configuration(releaseQualification: 0)
        let emissions = Fixtures.replay(Fixtures.twoHuddles, period: 0.25, offset: 0, configuration: naive)
        let leaveOne = 20.486
        #expect(emissions.contains { $0.outcome == .releaseQualified && $0.at < leaveOne })
        #expect(Fixtures.twoHuddles.releases.filter { $0.until - $0.from >= 5 + 1 }.count == 2)
    }
}
