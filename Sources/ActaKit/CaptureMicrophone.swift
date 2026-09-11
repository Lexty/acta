import Foundation

/// What Acta's **own recording** should point at — a different question from which microphone the Mac
/// prefers, and deliberately a separate setting.
///
/// ⚠️ **There is no "unset" case, and that is the point.** `SCStream.h` makes an unspecified capture
/// device mean "System Default Microphone", which is exactly the silent inheritance this feature
/// exists to end: connect a headset and Acta's recording follows it without anyone choosing that.
/// Every recording therefore starts from one of these two, and both end in a concrete device UID.
public enum CaptureMicrophoneChoice: Equatable, Codable, Sendable {
    /// Record from the highest-priority device on the user's list that is actually present.
    case followPriority

    /// Record from whatever the system default is **at the moment the recording starts** — resolved to
    /// a concrete UID and pinned to *that*.
    ///
    /// ⚠️ **Resolve-then-pin, never "pass nothing and let the OS decide".** The difference is invisible
    /// until a headset connects mid-recording: an unspecified device follows it silently, a pinned one
    /// does not. This case is the user saying "start from what the system prefers", not "keep following
    /// the system".
    case systemDefault
}

/// Which microphone a recording will use, or precisely why none could be chosen.
public enum CaptureMicrophoneResolution: Equatable, Sendable {
    /// The device to record from, plus the devices to fall back to **in order** if it will not start
    /// or is lost mid-recording.
    case pinned(AudioInputDevice, alternatives: [AudioInputDevice])
    case unavailable(CaptureMicrophoneFailure)
}

/// Why no microphone could be pinned. ⚠️ Four cases rather than one, because they are four different
/// sentences and three of them are the user's to fix.
public enum CaptureMicrophoneFailure: Equatable, Sendable {
    /// The user has never chosen anything, and has not asked for the system default either.
    ///
    /// ⚠️ Its own case because it is the **only** one an empty machine and a full one share, and the
    /// only one where the answer is a question rather than an error. Recording cannot silently fall
    /// back to "whatever the OS prefers" — see `CaptureMicrophoneChoice`.
    case noneConfigured
    /// A list exists; none of the devices on it is present and usable right now.
    case noPreferredDeviceAvailable
    /// Nothing on this machine can be recorded from at all.
    case noEligibleDevice
    /// `.systemDefault` was asked for and the OS would not say what the default is — which is not the
    /// same as there being none.
    case systemDefaultUnreadable(String)
    /// The device list could not be fully described, and what *was* described held nothing usable.
    ///
    /// ⚠️ **Its own case because the alternative is a lie about the machine.** An enumeration that
    /// could not read every driver and found nothing among the rest is not evidence that this Mac has
    /// no microphone, nor that the user's preferred one left — and both of those would be shown to the
    /// user as settled facts with an action attached.
    case snapshotIncomplete
}

public extension MicrophonePolicy {
    /// Resolve the device a recording will be pinned to.
    ///
    /// ⚠️ **Eligibility here is `isCaptureCandidate`, not `isSystemDefaultCandidate`.** Whether the OS
    /// will make a device the *system default* is a different question from whether ScreenCaptureKit
    /// can capture it, and the machine says so: the Teams loopback driver reported `0` for
    /// input-scope `canBeDefaultDevice` while BlackHole and the aggregate reported `1`.
    ///
    /// - Parameter systemDefault: the uid the OS currently reports, or `nil` if it reported none.
    ///   Consulted only for `.systemDefault`; `nil` there is a real state (no input hardware) and is
    ///   reported as `.noEligibleDevice` rather than silently followed.
    static func resolveCapture(from devices: [AudioInputDevice],
                               priority: MicrophonePriority,
                               choice: CaptureMicrophoneChoice,
                               systemDefault: String?) -> CaptureMicrophoneResolution {
        let candidates = devices.filter(\.isCaptureCandidate)
        guard !candidates.isEmpty else { return .unavailable(.noEligibleDevice) }

        // ⚠️ **A *Use now* outranks the choice, not just the list.** `.systemDefault` is a standing
        // policy — "start from what the OS prefers" — and the override is the user pointing at a
        // microphone right now. With the policy consulted first, clicking a device while
        // `.systemDefault` was set silently did nothing, which makes the one explicit action in this
        // whole feature the one that cannot be relied on.
        if let override = priority.override,
           let device = candidates.first(where: { $0.uid == override }) {
            return .pinned(device, alternatives: preferred(in: candidates, priority: priority)
                .filter { $0.uid != device.uid })
        }

        switch choice {
        case .systemDefault:
            guard let systemDefault else { return .unavailable(.noEligibleDevice) }
            guard let device = candidates.first(where: { $0.uid == systemDefault }) else {
                // The OS named a device this snapshot cannot record from. Reporting "no eligible
                // device" would be a lie about the machine, so it is named as what it is.
                return .unavailable(.systemDefaultUnreadable(systemDefault))
            }
            // ⚠️ The alternatives are still the user's list: "start from the system default" says
            // nothing about where to go if it dies mid-recording.
            return .pinned(device, alternatives: preferred(in: candidates, priority: priority)
                .filter { $0.uid != device.uid })

        case .followPriority:
            let ranked = preferred(in: candidates, priority: priority)
            guard let first = ranked.first else {
                let configured = priority.override != nil || !priority.order.isEmpty
                return .unavailable(configured ? .noPreferredDeviceAvailable : .noneConfigured)
            }
            return .pinned(first, alternatives: Array(ranked.dropFirst()))
        }
    }

    /// The user's devices, present and capture-eligible, most preferred first. The override outranks
    /// the list — it is `Use now`, and for capture it is the whole point of the action.
    private static func preferred(in candidates: [AudioInputDevice],
                                  priority: MicrophonePriority) -> [AudioInputDevice] {
        var ranked: [AudioInputDevice] = []
        if let override = priority.override,
           let device = candidates.first(where: { $0.uid == override }) {
            ranked.append(device)
        }
        for uid in priority.order {
            if let device = candidates.first(where: { $0.uid == uid }),
               !ranked.contains(where: { $0.uid == device.uid }) {
                ranked.append(device)
            }
        }
        return ranked
    }
}

/// One observation of the machine, **including what the observation could not establish**.
///
/// ⚠️ **It exists because two callers were resolving the same question from different inputs.** The
/// live resolver wrapped `resolveCapture` with the handling that turns "the enumeration failed" and "I
/// could not describe every driver" into answers that are honest about the machine; a second caller —
/// the menu's summary — called the bare policy with `[AudioInputDevice]` and a `String?` and therefore
/// gave a *different* answer for the same machine: an incomplete snapshot read as "none of your
/// microphones is connected", and a default input that was never read read as "there is none". Those
/// are claims about the hardware drawn from a read that made no such claim.
///
/// So the interpretation lives here, once, and both callers pass what they saw.
public struct CaptureObservation: Equatable, Sendable {
    public var devices: [AudioInputDevice]
    /// Devices the OS listed and would not describe. Non-empty means the snapshot is **incomplete**,
    /// and an incomplete snapshot may not be used to claim a device is absent.
    public var uninspectable: [String]
    /// The enumeration itself failed — `devices` says nothing at all in that case.
    public var enumerationFailure: String?
    /// What the OS last said about the default input, including "never read".
    public var systemDefault: ObservedDefaultInput
    /// Reading the default input failed, which is not the same as there being none.
    public var defaultReadFailure: String?

    public init(devices: [AudioInputDevice] = [],
                uninspectable: [String] = [],
                enumerationFailure: String? = nil,
                systemDefault: ObservedDefaultInput = .unread,
                defaultReadFailure: String? = nil) {
        self.devices = devices
        self.uninspectable = uninspectable
        self.enumerationFailure = enumerationFailure
        self.systemDefault = systemDefault
        self.defaultReadFailure = defaultReadFailure
    }
}

public extension MicrophonePolicy {
    /// The whole capture decision, made from one observation.
    ///
    /// The selection itself is `resolveCapture(from:priority:choice:systemDefault:)`; this adds the two
    /// things that decide whether its answer may be *believed*, and both of them are about honesty
    /// rather than policy:
    ///
    /// 1. **A failed read is never an answer about the hardware.** A failed enumeration, and a default
    ///    input that failed or was never read while `.systemDefault` is the choice, are reported as
    ///    unreadable — not as "this Mac has no microphone".
    /// 2. **An incomplete snapshot may not claim absence.** When some driver would not describe itself,
    ///    the two answers that are claims about the hardware are downgraded to `.snapshotIncomplete`.
    ///    "You have not chosen anything" is untouched: that is a fact about the user, not the machine.
    static func resolveCapture(_ observation: CaptureObservation,
                               priority: MicrophonePriority,
                               choice: CaptureMicrophoneChoice) -> CaptureMicrophoneResolution {
        if let reason = observation.enumerationFailure {
            return .unavailable(.systemDefaultUnreadable(reason))
        }

        // ⚠️ **A usable *Use now* is resolved before any default-input fact is required.** The selection
        // below already puts an override above the standing choice — "a Use now outranks the choice, not
        // just the list" — and asking about the Mac's input first quietly contradicted that: a user who
        // had pointed at a present, recordable microphone could not start a recording because an
        // unrelated read had failed. The winning choice needed that read not at all.
        //
        // ⚠️ Narrow on purpose. It skips the default-input *facts*, never the enumeration failure above,
        // and only for an override that is actually present and recordable — a stored override naming a
        // device that is gone proves nothing and must not license following a default nobody could read.
        let overrideIsUsable = priority.override.map { uid in
            observation.devices.contains { $0.uid == uid && $0.isCaptureCandidate }
        } ?? false

        var systemDefault: String?
        if case .systemDefault = choice, !overrideIsUsable {
            if let reason = observation.defaultReadFailure {
                return .unavailable(.systemDefaultUnreadable(reason))
            }
            switch observation.systemDefault {
            case .device(let uid):
                systemDefault = uid
            case .unread:
                // ⚠️ Never read is **not** "there is none": the user asked to follow the Mac's input and
                // nobody has looked at what it is.
                return .unavailable(.systemDefaultUnreadable("the Mac's input has not been read"))
            case .noDefault:
                systemDefault = nil
            }
        }

        let resolution = resolveCapture(from: observation.devices,
                                        priority: priority,
                                        choice: choice,
                                        systemDefault: systemDefault)
        if case .unavailable(let failure) = resolution, !observation.uninspectable.isEmpty {
            switch failure {
            case .noEligibleDevice, .noPreferredDeviceAvailable:
                return .unavailable(.snapshotIncomplete)
            case .noneConfigured, .systemDefaultUnreadable, .snapshotIncomplete:
                break
            }
        }
        return resolution
    }
}
