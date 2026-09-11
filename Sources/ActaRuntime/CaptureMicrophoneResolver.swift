import ActaKit
import Foundation

/// Who decides which microphone a recording is pinned to, asked **again at every start and restart**.
///
/// A seam rather than a call into `MicrophoneManager` because the audio path must not hop to the main
/// actor to bring a stream up, and because a test needs to script "this device will not start" without
/// a sound card.
public protocol CaptureMicrophoneResolving: Sendable {
    /// Resolve now, against the devices that exist now.
    func resolve() -> CaptureMicrophoneResolution
}

/// The user's capture preference, readable from the audio path without an actor hop.
///
/// ⚠️ **A shared mutable box on purpose, and the alternative is worse.** The preference lives on the
/// main actor (`MicrophoneManager`), while it must be read by `AudioRecorder.restart()` deep inside a
/// capture lifecycle that has no business awaiting the UI. Snapshotting it into the session at start
/// would be simpler and wrong: a watchdog restart re-resolves, and the plan requires that a priority
/// edit made mid-recording **can** take effect at that restart. A stale snapshot would silently make
/// that false.
public final class CaptureMicrophonePreference: @unchecked Sendable {
    /// The list and the choice as **one** value.
    ///
    /// ⚠️ **Read once per resolution, and replaced whole.** Two independent properties let a resolution
    /// combine a list from one settings revision with a choice from another — a mixture no user ever
    /// asked for, and one that appears only under load.
    public struct Snapshot: Equatable, Sendable {
        public var priority: MicrophonePriority
        public var choice: CaptureMicrophoneChoice

        public init(priority: MicrophonePriority = .empty,
                    choice: CaptureMicrophoneChoice = .followPriority) {
            self.priority = priority
            self.choice = choice
        }
    }

    private let lock = NSLock()
    private var stored: Snapshot

    public init(priority: MicrophonePriority = .empty,
                choice: CaptureMicrophoneChoice = .followPriority) {
        stored = Snapshot(priority: priority, choice: choice)
    }

    /// The whole preference, atomically.
    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Replace it. ⚠️ The only writer; there is deliberately no per-field setter, because a per-field
    /// setter is how the two halves drift apart.
    public func set(_ next: Snapshot) { lock.lock(); stored = next; lock.unlock() }

    public var priority: MicrophonePriority { snapshot.priority }
    public var choice: CaptureMicrophoneChoice { snapshot.choice }
}

/// The shipped resolver: the app's one device reader plus the user's preference.
///
/// ⚠️ It holds `AudioDeviceReading`, not `AudioDeviceDirectory` — a recording resolves which microphone
/// to record from and never touches the Mac's default input. See the seam amendment in `CLAUDE.md`.
public struct LiveCaptureMicrophoneResolver: CaptureMicrophoneResolving {
    private let reader: any AudioDeviceReading
    private let preference: CaptureMicrophonePreference

    public init(reader: any AudioDeviceReading, preference: CaptureMicrophonePreference) {
        self.reader = reader
        self.preference = preference
    }

    public func resolve() -> CaptureMicrophoneResolution {
        // One read, so a resolution cannot mix a list from one settings revision with a choice from
        // another.
        let preference = preference.snapshot
        var observation = CaptureObservation()
        switch reader.enumerateInputDevices() {
        case .devices(let listed, let uninspectable):
            observation.devices = listed
            // ⚠️ Carried, not discarded. An incomplete snapshot is not proof that a device left, and it
            // is certainly not proof the machine has no microphone.
            observation.uninspectable = uninspectable
        case .failed(let reason):
            // ⚠️ Not `.noEligibleDevice`: the machine was never described. Telling the user their Mac
            // has no microphone because one query failed is the failure mode this whole feature exists
            // to avoid.
            observation.enumerationFailure = reason
        }

        if case .systemDefault = preference.choice, observation.enumerationFailure == nil {
            switch reader.currentDefaultInput() {
            case .device(let uid): observation.systemDefault = .device(uid: uid)
            case .none: observation.systemDefault = .noDefault
            case .failed(let reason): observation.defaultReadFailure = reason
            }
        }

        // ⚠️ **The interpretation is shared, not repeated.** This used to be a wrapper written here,
        // and the menu's summary called the bare policy instead — so the same machine got two different
        // answers. See `MicrophonePolicy.resolveCapture(_:priority:choice:)`.
        return MicrophonePolicy.resolveCapture(observation,
                                               priority: preference.priority,
                                               choice: preference.choice)
    }
}
