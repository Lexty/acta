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
