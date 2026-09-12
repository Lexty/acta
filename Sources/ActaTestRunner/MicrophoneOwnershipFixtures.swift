import ActaKit
import Foundation

/// Recorded owner traces, and a replayer that samples them the way the production observer would.
///
/// ⚠️ **What a replay is, and what it is not.** Every trace below is a *reconstruction of what an
/// observer saw* — the owner's input state between observed transitions, taken as constant. Resampling
/// it at 1 Hz with a phase offset asks what a 1 Hz observer would have seen **if the world between the
/// recorded transitions was as smooth as the reconstruction says**. It is not proof of what another
/// physical observer would have seen: a hold or release shorter than the recording's own sampling
/// interval is absent from the trace, so it is absent from every replay of it too.
///
/// ⚠️ **And the start instant is chosen to be hard, not realistic.** A production binding exists only
/// after the start rule's 3 s hold and a prompt; every replay here binds at the owner's *first*
/// acquisition instead, so the pre-join flap — the one most likely to be mistaken for a release — is
/// inside the watched interval rather than before it.
enum MicrophoneOwnershipFixtures {
    // MARK: - Identities, as measured

    /// The process that holds the input during a Slack huddle. It has a bundle identifier of its own and
    /// no display name.
    static let slackHelper = "com.tinyspeck.slackmacgap.helper"
    static let slackHelperPID: Int32 = 81379
    /// Holds the input persistently on the measured machine. This is what breaks any rule that looks
    /// beyond the owner.
    static let coreSpeech = "com.apple.CoreSpeech"
    static let coreSpeechPID: Int32 = 1136

    /// An arbitrary fixed epoch. Replays are expressed in seconds from here.
    static let origin = Date(timeIntervalSince1970: 2_000_000)

    // MARK: - Traces

    /// One owner's input, as a list of observed transitions.
    struct Trace: Sendable {
        let name: String
        /// Seconds from the first transition, each the instant the owner was observed holding or not.
        let transitions: [(at: TimeInterval, holding: Bool)]
        /// The last instant the trace vouches for.
        let end: TimeInterval
        /// What is reconstructed rather than recorded, when anything is.
        let caveat: String?

        /// The owner's state at `time`: the last transition at or before it.
        func isHolding(at time: TimeInterval) -> Bool {
            transitions.last { $0.at <= time }?.holding ?? false
        }

        /// Every stretch the owner was released, with the instant it ended — the next hold, or the end
        /// of the trace, whichever came first.
        var releases: [(from: TimeInterval, until: TimeInterval, endsInHold: Bool)] {
            transitions.enumerated().compactMap { index, transition in
                guard !transition.holding else { return nil }
                let next = transitions.dropFirst(index + 1).first { $0.holding }
                return (transition.at, next?.at ?? end, next != nil)
            }
        }
    }

    /// Two huddles, one uninterrupted run: join, mute, leave, re-join, leave.
    ///
    /// Recorded 2026-09-12, macOS 26.6.2 (25G83), Slack 4.52.155, by a probe sampling every 250 ms that
    /// reported releases only from complete enumerations (there were none incomplete). Transcribed from
    /// `docs/backlog/per-application-autonomy-modes.md`, "The full trace", with 13:22:35.565 as zero.
    /// Mute happened at roughly +10 s to +20 s and produced no transition, so nothing encodes it.
    static let twoHuddles = Trace(
        name: "two huddles, 250 ms probe, 13:22",
        transitions: [
            (0.000, true),    // 13:22:35.565 join #1 (the pre-join dialog)
            (1.903, false),   // 13:22:37.468
            (2.176, true),    // 13:22:37.741 gap 273 ms
            (2.444, false),   // 13:22:38.009 held 268 ms
            (2.710, true),    // 13:22:38.275 gap 266 ms
            (20.486, false),  // 13:22:56.051 leave #1
            (37.281, true),   // 13:23:12.846 join #2, after 16.8 s released
            (38.652, false),  // 13:23:14.217
            (39.203, true),   // 13:23:14.768 gap 551 ms
            (48.782, false)   // 13:23:24.347 leave #2
        ],
        end: 95.248,          // 13:24:10.813, 46 s with nothing from Slack
        caveat: nil)

    /// One huddle seen by the 250 ms probe, the same huddle Acta's own 1 Hz reader caught its flap in.
    ///
    /// Transcribed from the same file, "Acta's own reader, compared against the probe", with
    /// 15:22:19.676 as zero. ⚠️ It ends 155 ms after the leave, at Acta's own observation of it, because
    /// nothing later was recorded: the release is truncated and must not be counted as one that ran for
    /// long enough.
    static let comparedHuddle = Trace(
        name: "one huddle, probe against Acta, 15:22",
        transitions: [
            (0.000, true),    // 15:22:19.676
            (2.224, false),   // 15:22:21.900
            (2.763, true),    // 15:22:22.439 gap 539 ms
            (48.239, false)   // 15:23:07.915 leave
        ],
        end: 48.394,          // 15:23:08.070, Acta's first sample after the leave
        caveat: nil)

    /// Every gap reported inside a call, and every pre-join hold, placed in a synthetic call.
    ///
    /// ⚠️ **Reconstructed.** The backlog reports the gaps 266, 273, 279, 539, 551, 824 and 834 ms and the
    /// pre-join holds 1.90, 1.37, 6.21 and 2.22 s as bare durations; the 279, 824 and 834 ms gaps come
    /// with no surrounding timestamps at all. The *durations* are measured; how they are paired, the 30 s
    /// call and the 20 s released tail are invented. And the durations are intervals between observed
    /// states — they bound no physical duration, so this is not a threshold search either.
    static let reportedFlaps: [Trace] = {
        let gaps: [TimeInterval] = [0.266, 0.273, 0.279, 0.539, 0.551, 0.824, 0.834]
        let preJoinHolds: [TimeInterval] = [1.90, 1.37, 6.21, 2.22]
        return gaps.enumerated().map { index, gap in
            let preJoin = preJoinHolds[index % preJoinHolds.count]
            let rejoin = preJoin + gap
            let leave = rejoin + 30
            return Trace(
                name: String(format: "reported flap %.0f ms after a %.2f s pre-join hold", gap * 1000, preJoin),
                transitions: [(0, true), (preJoin, false), (rejoin, true), (leave, false)],
                end: leave + 20,
                caveat: "durations measured, placement invented")
        }
    }()

    static var allTraces: [Trace] { [twoHuddles, comparedHuddle] + reportedFlaps }

    // MARK: - The replayer

    /// One outcome the rule produced, and when, in trace seconds.
    struct Emission: Equatable, Sendable {
        let at: TimeInterval
        let outcome: MicrophoneOwnershipRule.Outcome
    }

    /// Sample `trace` every `period` seconds starting at `offset`, and feed the rule what each sample saw.
    ///
    /// Every snapshot is the realistic machine rather than a one-holder fake: the Slack helper, present
    /// in every sample with its input as the trace says, and `com.apple.CoreSpeech` holding throughout.
    /// Both are complete enumerations, as the recording's were.
    static func replay(_ trace: Trace,
                       period: TimeInterval,
                       offset: TimeInterval,
                       configuration: MicrophoneOwnershipRule.Configuration = .default)
        -> [Emission] {
        precondition(period > 0 && offset >= 0 && offset < period)
        var rule = MicrophoneOwnershipRule(owner: binding(at: origin), configuration: configuration)
        var emissions: [Emission] = []
        var index = 0
        while true {
            // Multiplied rather than accumulated, so a long trace does not drift off its phase.
            let time = offset + Double(index) * period
            guard time <= trace.end else { break }
            let evidence = Self.evidence(ownerHolding: trace.isHolding(at: time))
            let outcome = rule.observe(evidence, at: origin.addingTimeInterval(time))
            if outcome != .none { emissions.append(Emission(at: time, outcome: outcome)) }
            index += 1
        }
        return emissions
    }

    /// The machine as measured: the owner's helper, and CoreSpeech holding.
    static func evidence(ownerHolding: Bool) -> AudioProcessReadings.Evidence {
        AudioProcessReadings.evidence(
            from: AudioProcessSnapshot(processes: [
                AudioProcessObservation(pid: slackHelperPID, bundleID: slackHelper,
                                        processName: "Slack Helper", isRunningInput: ownerHolding),
                AudioProcessObservation(pid: coreSpeechPID, bundleID: coreSpeech, isRunningInput: true)
            ], isComplete: true),
            dropping: .init())
    }

    /// A binding to the Slack helper, minted the only way a binding can be: from an episode about it and
    /// evidence showing it holding.
    static func binding(at observedAt: Date, epoch: UInt64 = 1) -> OwnerBinding {
        let episode = MicrophoneActivityEpisode(id: 1, bundleID: slackHelper, displayName: nil,
                                                processName: "Slack Helper")
        guard let binding = OwnerBinding.bind(episode: episode,
                                              holding: evidence(ownerHolding: true).readings,
                                              epoch: epoch, observedAt: observedAt) else {
            preconditionFailure("the fixture's own binding must exist")
        }
        return binding
    }
}
