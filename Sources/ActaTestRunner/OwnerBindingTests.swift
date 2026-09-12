import ActaKit
import Foundation
import Testing

/// `OwnerBinding` — which application a recording belongs to.
///
/// ⚠️ **The tests that matter here guard an *absence*.** The rule is that the owner comes from the
/// prompt's episode and from nothing else; two earlier drafts of this plan tried to infer one from the
/// world, and the second was worse than the first. So most of this suite exists to fail if inference
/// ever comes back.
@Suite("Owner binding")
struct OwnerBindingTests {
    /// The application the prompt was about. Named so it sorts **first** among the fixture's holders.
    private static let promptApp = "com.aaa.calls"
    /// Another application holding the input at the same instant. Named so it sorts **last**, and
    /// listed last in every snapshot below.
    ///
    /// ⚠️ **Both properties are deliberate.** A rule that picked "some holder from the world" would have
    /// to pick by *something*, and the two orderings available to it — the enumeration order and the
    /// identifier order — both land on this one. That is what makes the negative control deterministic
    /// instead of a coin toss.
    private static let otherApp = "com.zzz.dictation"

    private static let observed = Date(timeIntervalSince1970: 9_000_000)

    private static func process(_ pid: Int32, _ bundleID: String?,
                                _ isRunningInput: Bool?) -> AudioProcessObservation {
        AudioProcessObservation(pid: pid, bundleID: bundleID, displayName: nil,
                                processName: nil, isRunningInput: isRunningInput)
    }

    private static func readings(_ processes: [AudioProcessObservation],
                                 complete: Bool = true) -> [AudioProcessKey: MicrophoneInputReading] {
        AudioProcessReadings.reduce(AudioProcessSnapshot(processes: processes, isComplete: complete),
                                    dropping: .init())
    }

    private static func episode(_ id: UInt64, _ bundleID: String?) -> MicrophoneActivityEpisode {
        MicrophoneActivityEpisode(id: id, bundleID: bundleID, displayName: nil, processName: nil)
    }

    // MARK: - What a binding carries

    @Test("a prompt episode yields a binding carrying its epoch, its episode and its evidence's time")
    func aPromptEpisodeBinds() {
        let binding = OwnerBinding.bind(episode: Self.episode(7, Self.promptApp),
                                        holding: Self.readings([Self.process(501, Self.promptApp, true)]),
                                        epoch: 3, observedAt: Self.observed)
        #expect(binding?.key == .bundle(Self.promptApp))
        #expect(binding?.bundleID == Self.promptApp)
        #expect(binding?.episodeID == 7)
        // ⚠️ Episode ids restart at 1 in a fresh rule, so the epoch is half of the identity.
        #expect(binding?.epoch == 3)
        // ⚠️ Admission time is a software boundary; the evidence's own timestamp is what is recorded.
        #expect(binding?.observedAt == Self.observed)
    }

    // MARK: - The absence this suite exists for

    /// ⚠️ **The guard against the recency heuristic ever coming back.** The counterexample it died on:
    /// Slack has held the input for four minutes and the meeting is live; a dictation service acquires
    /// the input briefly just before the user presses Record; that service is the only recent acquirer,
    /// so a recency rule binds it; it releases, and Acta runs a countdown and stops the still-running
    /// Slack recording. A false binding is worse than a missing one.
    @Test("the prompt's application is bound even when another application is also holding")
    func thePromptWinsOverAnyOtherHolder() {
        let world = Self.readings([Self.process(501, Self.promptApp, true),
                                   Self.process(900, Self.otherApp, true)])
        // The fixture is a real counterexample rather than a degenerate one: there genuinely are two
        // holders, and the other one is the one any "pick from the world" ordering would reach first.
        #expect(world.count == 2)
        #expect(world[.bundle(Self.otherApp)] == .held)

        let binding = OwnerBinding.bind(episode: Self.episode(1, Self.promptApp), holding: world,
                                        epoch: 1, observedAt: Self.observed)
        #expect(binding?.key == .bundle(Self.promptApp),
                "the binding was taken from the world instead of from the prompt")
    }

    /// ⚠️ **A pid can be reused within one recording**, so a bare pid cannot promise the identity a
    /// bundle key can. This increment leaves such a holder unbound rather than inventing an incarnation
    /// fence from evidence nobody has measured.
    @Test("a pid-only episode yields no binding")
    func aPidOnlyEpisodeDoesNotBind() {
        let binding = OwnerBinding.bind(episode: Self.episode(1, nil),
                                        holding: Self.readings([Self.process(777, nil, true)]),
                                        epoch: 1, observedAt: Self.observed)
        #expect(binding == nil)
    }

    // MARK: - The evidence the binding claims to come from

    /// Several processes of one application are one holder, so the binding is one application rather
    /// than the helper that happened to be enumerated first.
    @Test("several processes of one application coalesce into one holder")
    func processesOfOneApplicationAreOneHolder() {
        let world = Self.readings([Self.process(501, Self.promptApp, false),
                                   Self.process(502, Self.promptApp, true),
                                   Self.process(503, Self.promptApp, false)])
        #expect(world == [.bundle(Self.promptApp): .held])
        let binding = OwnerBinding.bind(episode: Self.episode(1, Self.promptApp), holding: world,
                                        epoch: 1, observedAt: Self.observed)
        #expect(binding?.key == .bundle(Self.promptApp))
    }

    /// ⚠️ **Stop authority is never handed to something the evidence does not show.** The readings are
    /// not consulted to *choose* the key — that is the rule above — but a key the evidence cannot see
    /// holding produces no binding at all.
    @Test("an episode whose application is not shown holding yields no binding")
    func anUnseenApplicationDoesNotBind() {
        let idle = OwnerBinding.bind(episode: Self.episode(1, Self.promptApp),
                                     holding: Self.readings([Self.process(501, Self.promptApp, false)]),
                                     epoch: 1, observedAt: Self.observed)
        #expect(idle == nil)

        let absent = OwnerBinding.bind(episode: Self.episode(1, Self.promptApp),
                                       holding: Self.readings([Self.process(900, Self.otherApp, true)]),
                                       epoch: 1, observedAt: Self.observed)
        #expect(absent == nil)

        // ⚠️ Unreadable is not held. An incomplete enumeration is exactly where a key stops being
        // answerable, and a binding minted from it would claim evidence that does not exist.
        let unreadable = OwnerBinding.bind(
            episode: Self.episode(1, Self.promptApp),
            holding: Self.readings([Self.process(501, Self.promptApp, false)], complete: false),
            epoch: 1, observedAt: Self.observed)
        #expect(unreadable == nil)
    }
}
