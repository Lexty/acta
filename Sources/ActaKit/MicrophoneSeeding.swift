import Foundation

/// What Acta proposes as a starting priority list when the user first switches on management of the
/// Mac's default input.
///
/// **Seed, do not invent.** The list has to start somewhere, and the two wrong answers are equally
/// easy: leaving it empty means enabling the feature does nothing and the user is left staring at
/// "waiting for a preferred microphone", while inventing a full ranking of every device on the machine
/// puts choices in front of them they never made.
public enum MicrophoneSeeding {
    /// A **suitable physical microphone**, defined in fields rather than in prose because the plan
    /// requires it to be:
    ///
    /// - `isSystemDefaultCandidate` — available (alive, with input channels) and not something the OS
    ///   refuses to make the default. ⚠️ An *unknown* eligibility counts as eligible, matching the rest
    ///   of the policy: one failed query must not prune the machine.
    /// - `isPhysical` — a real input rather than a virtual device, a loopback or an aggregate. Those
    ///   can legitimately be recorded from and are legitimately chosen by hand, but proposing one as a
    ///   *default* the Mac should return to is not a guess Acta gets to make.
    public static func isSuitable(_ device: AudioInputDevice) -> Bool {
        device.isSystemDefaultCandidate && device.isPhysical
    }

    /// Propose a starting list.
    ///
    /// The rule, and each clause is a decision:
    ///
    /// 1. **The device the Mac currently prefers goes first** — unless it is Bluetooth. Enabling the
    ///    feature while wearing a headset must not enshrine the headset as the preference, because
    ///    "my Mac keeps switching to my headset" is the complaint the whole feature exists to answer.
    /// 2. **The built-in microphone is the fallback**, and the first entry when the current input is
    ///    Bluetooth. It is the one input that is always there.
    /// 3. ⚠️ **When there is no built-in microphone** — a Mac mini, a Mac Studio — the proposal is the
    ///    highest-ranked suitable non-Bluetooth device instead. If the machine offers nothing but
    ///    Bluetooth, the proposal is **empty**: Acta will not seed the very thing the user is trying to
    ///    stop happening, and the menu asks them to choose.
    ///
    /// - Parameter systemDefault: the uid the OS currently reports, if it reported one.
    public static func proposal(from devices: [AudioInputDevice],
                                systemDefault: String?) -> [String] {
        let suitable = devices.filter(isSuitable)
        let builtIn = suitable.first { $0.transport == .builtIn }
        let current = systemDefault.flatMap { uid in suitable.first { $0.uid == uid } }

        var proposal: [AudioInputDevice] = []
        if let current, !current.isBluetooth {
            proposal.append(current)
        } else if let builtIn {
            proposal.append(builtIn)
        } else if let wired = suitable.first(where: { !$0.isBluetooth }) {
            proposal.append(wired)
        }

        if let builtIn, !proposal.contains(where: { $0.uid == builtIn.uid }) {
            proposal.append(builtIn)
        }
        return proposal.map(\.uid)
    }

    /// Apply a proposal to the list the user already has.
    ///
    /// ⚠️ **Seeding never overwrites an existing list**, and this is the function that guarantees it
    /// rather than every caller remembering. A user who disables the feature and enables it again must
    /// find their order intact — losing a hand-made ranking to a convenience is worse than never
    /// having offered the convenience.
    public static func seeded(_ existing: [String],
                              devices: [AudioInputDevice],
                              systemDefault: String?) -> [String] {
        seeded(existing, proposal: proposal(from: devices, systemDefault: systemDefault))
    }

    /// The same rule against a proposal computed earlier.
    ///
    /// ⚠️ **This overload exists so the decision can be made where the list actually lives.** Computing
    /// a seed from a cached copy of the order and then writing the result back is a read-modify-write
    /// across two hops, and an explicit edit arriving in between is lost: enabling management while a
    /// priority edit was in flight replaced the user's edit with a seed, measured 20 times out of 20.
    /// The owner of the authoritative list calls this **inside its own turn**, so "is it empty" and
    /// "then seed it" cannot be separated.
    public static func seeded(_ existing: [String], proposal: [String]) -> [String] {
        existing.isEmpty ? proposal : existing
    }
}

/// Laying out a bounded, self-sizing section.
///
/// ⚠️ **Pure and here because it is a rule, not a drawing.** A `ScrollView` is greedy along its scroll
/// axis, so a bounded section has to be told its content's height — and the measurement arrives from a
/// `PreferenceKey`, which reports its **default** whenever the content is not in the hierarchy. A
/// collapsed disclosure is exactly that: it renders nothing, the measurement comes back zero, the zero
/// is stored, and on the next expansion the frame is zero tall, so the content lays out at zero and goes
/// on measuring zero. The section opens empty and stays empty, which is what shipped.
public enum BoundedSectionLayout {
    /// The height to give the section, given the last measurement and the bound.
    ///
    /// A non-positive measurement means **not measured**, never "nothing to show": it is what an absent
    /// hierarchy reports, and treating it as a height is the latch above.
    public static func height(measured: Double, bound: Double) -> Double {
        guard measured > 0 else { return bound }
        return min(measured, bound)
    }
}
