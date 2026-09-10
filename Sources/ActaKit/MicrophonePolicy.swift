import Foundation

/// The user's microphone preferences: an ordered list, plus a temporary override.
///
/// **Identity is the UID**, never the display name. Two devices can share a name, and a rename must not
/// orphan a list entry — see `AudioInputDevice.uid` for why the UID is the only durable handle.
public struct MicrophonePriority: Codable, Equatable, Sendable {
    /// Preferred devices, most preferred first. Empty means "nothing configured", which is a real and
    /// ordinary state — not an error, and not a reason to pick something.
    public var order: [String]

    /// *Use now*: a temporary choice that outranks the whole list.
    ///
    /// ⚠️ **Temporary, and never promoted into `order` by any code path.** Borrowing a headset for one
    /// call must not silently rewrite a permanent preference; that is the whole reason the two are
    /// separate fields rather than "move it to the front". Expiry belongs to the reconciler — this type
    /// only records the choice.
    public var override: String?

    public init(order: [String] = [], override: String? = nil) {
        self.order = order
        self.override = override
    }

    public static let empty = MicrophonePriority()
}

/// What a selection is *for*. The two purposes have genuinely different eligibility rules, and that is
/// why one function takes this rather than two functions drifting apart.
public enum SelectionPurpose: Equatable, Sendable {
    /// Choosing what to write into the system default input. Filters on `canBeSystemDefault`.
    case systemDefault
    /// Choosing what Acta records from. ⚠️ Deliberately does **not** filter on `canBeSystemDefault`:
    /// that property answers whether the OS will make a device the system default, which is a different
    /// question from whether ScreenCaptureKit can capture it.
    case capture
}

/// The outcome of a selection. Three cases, not an optional — because the two "nothing chosen" answers
/// mean different things to the caller and to the user.
public enum MicrophoneSelection: Equatable, Sendable {
    case selected(AudioInputDevice)

    /// Usable devices exist, but none of them is preferred (the list is empty, or every entry on it is
    /// absent).
    ///
    /// ⚠️ **Its own case, distinct from Pause and from an error.** It means *leave the system default
    /// alone and keep watching* — the menu's "waiting for a preferred microphone" state. Collapsing it
    /// into "nothing available" would have Acta claim the machine has no microphones while the user is
    /// looking at one.
    case noPreferredDeviceAvailable

    /// Nothing on this machine can serve this purpose at all.
    case noEligibleDevice
}

/// Whether a device is on the machine — with the third answer that keeps a failed look from passing for
/// a disconnect.
public enum DevicePresence: Equatable, Sendable {
    case present
    case absent
    /// It was not in the snapshot, **and the snapshot was incomplete**, so its absence proves nothing.
    case unknown
}

/// The selection policy: pure, total, and the only place that decides which microphone wins.
///
/// It is in `ActaKit` because every hard case here is reachable from literals — an override whose device
/// vanished, a list whose every entry is absent, a device present but not default-eligible. Those are
/// the cases a live machine can almost never be persuaded to produce on demand.
public enum MicrophonePolicy {
    /// Choose a device, or say precisely why not.
    ///
    /// - Parameter refused: UIDs the OS has already **refused a write for during this reconciliation
    ///   pass**. ⚠️ This parameter is the answer to a specific trap. A device whose eligibility query
    ///   failed is treated as eligible (see `AudioInputDevice.isSystemDefaultCandidate`, and the
    ///   machine-wide failure that optimism prevents), so the policy will happily keep choosing one the
    ///   OS will not accept. A refused *write* is not the same event as a competitor reverting the
    ///   default, and without this exclusion the reconciler would re-pick the same doomed candidate
    ///   forever and never reach a known-good device below it.
    public static func select(from devices: [AudioInputDevice],
                              priority: MicrophonePriority,
                              purpose: SelectionPurpose,
                              refused: Set<String> = []) -> MicrophoneSelection {
        let candidates = devices.filter { eligible($0, for: purpose) && !refused.contains($0.uid) }
        guard !candidates.isEmpty else { return .noEligibleDevice }

        // The override outranks the list — but only while its device is actually usable. A `Use now`
        // whose device has gone selects nothing here; retiring the stale override is the reconciler's
        // job, and doing it here would make a pure function that edits its own input.
        if let override = priority.override,
           let device = candidates.first(where: { $0.uid == override }) {
            return .selected(device)
        }

        for uid in priority.order {
            if let device = candidates.first(where: { $0.uid == uid }) { return .selected(device) }
        }
        return .noPreferredDeviceAvailable
    }

    /// Whether `uid` is on the machine, given a snapshot that may be incomplete.
    ///
    /// ⚠️ **This exists so that "I could not see it" never becomes "it was unplugged".** Consumers act
    /// destructively on absence — an override expires, a recording fails over to another microphone —
    /// so concluding absence from a snapshot that admits it could not describe every device would turn
    /// one unreadable driver into a lost recording. `snapshotComplete` comes from the directory's
    /// `uninspectable` list being empty.
    public static func presence(of uid: String,
                                in devices: [AudioInputDevice],
                                snapshotComplete: Bool) -> DevicePresence {
        if devices.contains(where: { $0.uid == uid }) { return .present }
        return snapshotComplete ? .absent : .unknown
    }

    private static func eligible(_ device: AudioInputDevice, for purpose: SelectionPurpose) -> Bool {
        switch purpose {
        case .capture: return device.isCaptureCandidate
        case .systemDefault: return device.isSystemDefaultCandidate
        }
    }
}
