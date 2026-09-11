import ActaKit
import AppKit
import CoreAudio
import Foundation
import os

/// Reads which processes currently hold microphone input.
///
/// ⚠️ **A seam, and a narrow one.** Everything that decides *anything* lives in
/// `MicrophoneActivityRule`; this protocol exists so the coordinator can be driven from a test without
/// a HAL, and so the HAL adapter has nothing to get wrong beyond reading properties.
public protocol AudioProcessReading: AnyObject, Sendable {
    /// One reading, right now. Never throws: a failure is an **incomplete** snapshot, which the rule
    /// treats as "nothing was observed" rather than "nothing is happening".
    func readSnapshot() -> AudioProcessSnapshot
}

/// The production reader, over CoreAudio's process objects.
///
/// ⚠️ **Why not `kAudioDevicePropertyDeviceIsRunningSomewhere`**, which `AudioInputDevice` already
/// carries: it answers "some process has this device open" and cannot say which. It therefore cannot
/// name the application in the prompt, and — worse — cannot tell Acta's own capture from anybody
/// else's, so every recording Acta started would look like a reason to offer to start one.
///
/// ⚠️ **What `IsRunningInput` actually means**, quoted from `AudioHardware.h`: the process "is running
/// IO and there is at least one active input stream". It does **not** mean a meeting started, that
/// microphone ownership was taken, or that anyone is speaking. A muted participant usually keeps the
/// stream open; a listen-only participant may never open one. Those are expected false positives and
/// negatives, and no amount of debouncing fixes them — the exclusion list does.
///
/// ⚠️ **A bundle identifier names a process, not an application a user recognises.** Measured on this
/// machine: a call in a browser tab appears as `com.apple.WebKit.GPU`. So the display name is whatever
/// `NSRunningApplication` can supply for that pid and is `nil` otherwise, and the prompt must be able to
/// say that some application is using the microphone without naming one.
public final class CoreAudioProcessReader: AudioProcessReading {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "AudioProcessReader")

    public init() {}

    public func readSnapshot() -> AudioProcessSnapshot {
        guard let objects = processObjects() else {
            // The enumeration itself failed: absence proves nothing, and the flag says so.
            return .unreadable
        }
        let processes = objects.map { object -> AudioProcessObservation in
            let pid = self.pid(of: object)
            return AudioProcessObservation(pid: pid ?? -1,
                                           bundleID: bundleID(of: object),
                                           displayName: pid.flatMap(displayName(forPID:)),
                                           isRunningInput: isRunningInput(of: object))
        }
        return AudioProcessSnapshot(processes: processes, isComplete: true)
    }

    // MARK: - CoreAudio

    private func processObjects() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                                        &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            log.error("process list size unreadable: \(sizeStatus, privacy: .public)")
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                0, nil, &size, &ids)
        guard status == noErr else {
            log.error("process list unreadable: \(status, privacy: .public)")
            return nil
        }
        return ids
    }

    /// ⚠️ **`nil`, never `false`.** A property that could not be read is the whole reason the rule's
    /// input is three-valued; returning `false` here would reintroduce the defect at the one place the
    /// type system cannot catch it.
    private func isRunningInput(of object: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value != 0
    }

    private func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private func pid(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var value: pid_t = 0
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    /// The name the user would recognise, when the system has one for this pid.
    ///
    /// ⚠️ Resolved from the pid rather than the bundle identifier on purpose: the identifier belongs to
    /// the process that holds the audio, which for a browser is a helper. `NSRunningApplication` returns
    /// `nil` for a helper that is not an application, and `nil` is the honest answer the prompt needs.
    private func displayName(forPID pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.localizedName
    }
}
