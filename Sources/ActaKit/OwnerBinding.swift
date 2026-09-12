import Foundation

/// The application a recording belongs to, fixed at the moment the start was admitted.
///
/// ⚠️ **Only a recording started from a prompt is bound.** The prompt carries a *known* triggering
/// identity; every other route would have to infer one, and inference here is not cheap to get wrong.
/// The counterexample that killed the alternative: Slack has held the input for four minutes and the
/// meeting is live; a microphone test or a dictation service acquires the input briefly just before the
/// user presses Record; that service is the only recent acquirer, so a recency rule binds **it**; it
/// releases, and Acta runs a countdown and stops the still-running Slack recording. A false binding is
/// worse than a missing one. A manual or socket start therefore stays unbound: the recording works, and
/// no stop is offered for it.
///
/// ⚠️ **A second failure needs no third party.** Two holders both acquire, a recency rule correctly
/// answers "ambiguous" — then the older acquisition ages out while that application is still holding,
/// and the identical situation becomes "unambiguous" because a timestamp expired.
///
/// ⚠️ **The exclusion list is not consulted here.** "Do not offer to record Slack" can mean "I record
/// Slack myself", which is not consent to give another application authority to stop a recording. New
/// copy and a new test do not retroactively change what an already-saved preference meant.
public struct OwnerBinding: Equatable, Sendable {
    /// Which application. Always a bundle key — see `init?(episode:...)`.
    public let key: AudioProcessKey

    /// The observation epoch the evidence belongs to.
    ///
    /// ⚠️ **Carried because episode ids restart at 1 in a fresh rule.** A preference toggle or a wake
    /// rebaseline replaces the rule, and a different application already holding the input is minted
    /// episode 1 at the new baseline. The epoch is what stops a binding admitted before that from being
    /// matched against evidence gathered after it.
    public let epoch: UInt64

    /// The episode this binding came from, so a parked admission can be re-checked rather than trusted.
    public let episodeID: UInt64

    /// When the evidence behind it was observed.
    ///
    /// ⚠️ **Admission time is a software boundary, not proof of the physical holder at that instant.**
    /// Even a fresh sample carries observation latency, which is why this is recorded rather than
    /// assumed to be "now".
    public let observedAt: Date

    /// The bundle identifier, which a binding always has.
    public var bundleID: String {
        // Unreachable by construction: the only entry point refuses a key without one.
        key.bundleID ?? ""
    }

    private init(key: AudioProcessKey, epoch: UInt64, episodeID: UInt64, observedAt: Date) {
        self.key = key
        self.epoch = epoch
        self.episodeID = episodeID
        self.observedAt = observedAt
    }

    /// Bind a recording to the application whose episode raised the prompt that started it.
    ///
    /// ⚠️ **The only entry point in this increment, deliberately.** There is no way to build a binding
    /// from "whatever is currently holding the input", because that is exactly the rule the
    /// counterexample above refuses. The memberwise initialiser is private for the same reason.
    ///
    /// ⚠️ **`readings` is never used to *choose* the key.** It is the evidence the binding claims to
    /// come from, and its one job here is to refuse a binding to an application that evidence does not
    /// show holding the input — binding to something we cannot see would hand stop authority to a
    /// guess. Several processes of one application have already been coalesced into one holder by
    /// `AudioProcessReadings.reduce`, so "is it holding" is one lookup rather than a scan.
    ///
    /// Returns `nil` when the episode has no bundle identifier. ⚠️ **A pid-only holder is left
    /// unbound**: a pid can be reused *within one recording*, so a bare pid cannot promise the identity
    /// a bundle key can, and inventing an incarnation fence from evidence nobody has measured is out of
    /// scope for this increment.
    public static func bind(episode: MicrophoneActivityEpisode,
                            holding readings: [AudioProcessKey: MicrophoneInputReading],
                            epoch: UInt64,
                            observedAt: Date) -> OwnerBinding? {
        guard let bundleID = episode.bundleID else { return nil }
        let key = AudioProcessKey.bundle(bundleID)
        guard readings[key] == .held else { return nil }
        return OwnerBinding(key: key, epoch: epoch, episodeID: episode.id, observedAt: observedAt)
    }
}
