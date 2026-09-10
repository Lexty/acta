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
    private let lock = NSLock()
    private var storedPriority: MicrophonePriority
    private var storedChoice: CaptureMicrophoneChoice

    public init(priority: MicrophonePriority = .empty,
                choice: CaptureMicrophoneChoice = .followPriority) {
        storedPriority = priority
        storedChoice = choice
    }

    public var priority: MicrophonePriority {
        get { lock.lock(); defer { lock.unlock() }; return storedPriority }
        set { lock.lock(); storedPriority = newValue; lock.unlock() }
    }

    public var choice: CaptureMicrophoneChoice {
        get { lock.lock(); defer { lock.unlock() }; return storedChoice }
        set { lock.lock(); storedChoice = newValue; lock.unlock() }
    }
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
        let devices: [AudioInputDevice]
        switch reader.enumerateInputDevices() {
        case .devices(let listed, _):
            devices = listed
        case .failed(let reason):
            // ⚠️ Not `.noEligibleDevice`: the machine was never described. Telling the user their Mac
            // has no microphone because one query failed is the failure mode this whole feature exists
            // to avoid.
            return .unavailable(.systemDefaultUnreadable(reason))
        }

        var systemDefault: String?
        if case .systemDefault = preference.choice {
            switch reader.currentDefaultInput() {
            case .device(let uid): systemDefault = uid
            case .none: systemDefault = nil
            case .failed(let reason): return .unavailable(.systemDefaultUnreadable(reason))
            }
        }

        return MicrophonePolicy.resolveCapture(from: devices,
                                               priority: preference.priority,
                                               choice: preference.choice,
                                               systemDefault: systemDefault)
    }
}
