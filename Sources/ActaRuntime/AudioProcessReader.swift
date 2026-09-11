import ActaKit
import AppKit
import Foundation
import os

// MARK: - The raw reading seam

/// One property read: it produced a value, it succeeded and there was nothing there, or it failed.
///
/// ⚠️ **`absent` and `unreadable` are different answers and collapsing them is a defect.** A process
/// with no bundle identifier is ordinary; a bundle identifier that could not be read is a process whose
/// identity we have temporarily lost. Treating the second as the first re-keys a live application under
/// its pid and asks about the same call again — and, while the read is failing, walks straight past the
/// user's exclusion list.
public enum AudioPropertyReading<Value: Sendable>: Sendable, Equatable where Value: Equatable {
    case value(Value)
    case absent
    case unreadable
}

/// The enumeration itself, which is also a read that can fail.
public enum AudioProcessListReading: Sendable, Equatable {
    case list([UInt32])
    case unreadable
}

/// The raw property reads the process reader is made of — a seam, so that every failure path can be
/// tested. ⚠️ A live machine cannot be asked to fail a property read on demand, and these failures are
/// precisely where the interesting defects live.
public protocol AudioProcessPropertyReading: AnyObject, Sendable {
    func processObjectIDs() -> AudioProcessListReading
    func processID(of object: UInt32) -> AudioPropertyReading<Int32>
    func bundleID(of object: UInt32) -> AudioPropertyReading<String>
    func isRunningInput(of object: UInt32) -> AudioPropertyReading<Bool>
    /// Whether the process has at least one **input-scoped** device.
    ///
    /// ⚠️ `IsRunningInput` alone says a process runs IO with an active input stream; it does not say the
    /// input is a microphone rather than a loopback or virtual capture. This narrows it by one step.
    func hasInputDevices(of object: UInt32) -> AudioPropertyReading<Bool>
}

// MARK: - Reading

/// Reads which processes currently hold audio input.
///
/// ⚠️ **A seam, and a narrow one.** Everything that decides anything lives in
/// `MicrophoneActivityRule`; this exists so the coordinator can be driven from a test without a HAL.
public protocol AudioProcessReading: AnyObject, Sendable {
    /// One reading, right now. Never throws: a failure is an **incomplete** snapshot, which the rule
    /// treats as "nothing was observed" rather than "nothing is happening".
    func readSnapshot() -> AudioProcessSnapshot
}

/// Turns raw property readings into the snapshot the rule consumes.
///
/// ⚠️ **What this feature can and cannot say.** `IsRunningInput` means, in `AudioHardware.h`'s own
/// words, that the process "is running IO and there is at least one active input stream". It does not
/// mean a meeting started, and it cannot distinguish a microphone from a virtual or loopback input
/// beyond the input-scope device check below. The prompt therefore says *microphone activity*, which is
/// what is measured, and another recorder or a loopback capture is an expected false positive answered
/// by the exclusion list rather than by a cleverer reading.
public final class AudioProcessProjection: AudioProcessReading, @unchecked Sendable {
    private let reader: any AudioProcessPropertyReading
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "AudioProcessReader")
    private let lock = NSLock()

    /// The last bundle identifier positively read for a pid, so a transient read failure does not
    /// change an application's identity.
    ///
    /// ⚠️ Cleared for any pid that is absent from a **complete** enumeration, so a recycled pid cannot
    /// inherit the identity of the process that used to own it.
    private var knownBundleIDs: [Int32: String] = [:]
    /// The same for names, and for the same reason.
    private var knownNames: [Int32: (display: String?, process: String?)] = [:]

    public init(reader: any AudioProcessPropertyReading) {
        self.reader = reader
    }

    public func readSnapshot() -> AudioProcessSnapshot {
        guard case .list(let objects) = reader.processObjectIDs() else {
            return .unreadable
        }
        var observations: [AudioProcessObservation] = []
        var seenPIDs: Set<Int32> = []
        // ⚠️ Any observation we cannot key is dropped **and** costs the snapshot its completeness: a
        // process we could not identify has not been observed to stop, and a list that quietly omits it
        // while claiming to be complete is the partial-list defect wearing a disguise.
        var isComplete = true

        for object in objects {
            guard case .value(let pid) = reader.processID(of: object) else {
                // ⚠️ Never fabricated. A pid of -1 would coalesce every unidentifiable process under one
                // false identity, and make real keys vanish and later re-arm.
                isComplete = false
                continue
            }
            seenPIDs.insert(pid)

            var identityIsKnown = true
            let bundle = resolveBundleID(for: pid, object: object, isComplete: &isComplete,
                                         identityIsKnown: &identityIsKnown)
            let names = resolveNames(for: pid)
            // ⚠️ **An unresolved identity may not carry actionable input evidence.** Reporting a held
            // input under a fabricated process key is worse than reporting nothing: the rule keys the
            // episode by pid, offers anonymously — past the exclusion list, which is keyed by bundle id
            // — and then mints a *second* episode for the same process the moment the identifier
            // resolves. Unknown here means unknown, which the rule already refuses to read as idle.
            let input = identityIsKnown ? inputState(of: object) : nil
            observations.append(AudioProcessObservation(pid: pid,
                                                        bundleID: bundle,
                                                        displayName: names.display,
                                                        processName: names.process,
                                                        isRunningInput: input))
        }

        if isComplete { forget(pidsOutside: seenPIDs) }
        return AudioProcessSnapshot(processes: observations, isComplete: isComplete)
    }

    // MARK: - Identity

    private func resolveBundleID(for pid: Int32, object: UInt32,
                                 isComplete: inout Bool,
                                 identityIsKnown: inout Bool) -> String? {
        switch reader.bundleID(of: object) {
        case .value(let identifier):
            lock.lock(); knownBundleIDs[pid] = identifier; lock.unlock()
            return identifier
        case .absent:
            // A real answer: this process genuinely has no bundle identifier. Any remembered one is
            // stale — a recycled pid — so it must go.
            lock.lock(); knownBundleIDs[pid] = nil; lock.unlock()
            return nil
        case .unreadable:
            // Identity preserved across a transient failure; if we never knew one, the snapshot loses
            // its completeness rather than inventing a process key that would rearm later.
            lock.lock(); let remembered = knownBundleIDs[pid]; lock.unlock()
            // ⚠️ The inout is *completeness*, not degradation — an inverted name here silently
            // turned every unreadable identity into a complete reading.
            if remembered == nil {
                isComplete = false
                identityIsKnown = false
            }
            return remembered
        }
    }

    /// The name a prompt may show, and the name a settings row may show. They are different questions.
    ///
    /// ⚠️ **Measured on this machine.** A call in a Safari tab is held by `com.apple.WebKit.GPU`, whose
    /// name resolves to "Safari Graphics and Media"; Chrome's audio runs in `com.google.Chrome.helper`,
    /// "Google Chrome Helper". Both are real names that describe a meeting worse than saying nothing.
    /// `activationPolicy` separates them cleanly — every user-facing application measured here is
    /// `.regular` and every helper is `.accessory` or `.prohibited` — so only a regular application's
    /// name is offered to the prompt.
    ///
    /// ⚠️ **A conservative display heuristic, not proof of attribution.** A regular application holding
    /// the input is not evidence that *it* is the meeting; it is only evidence that naming it will not
    /// mislead as badly as naming its helper would.
    private func resolveNames(for pid: Int32) -> (display: String?, process: String?) {
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else {
            lock.lock(); let remembered = knownNames[pid]; lock.unlock()
            return (remembered?.display, remembered?.process)
        }
        guard let name = app.localizedName else { return (nil, nil) }
        let display = app.activationPolicy == .regular ? name : nil
        lock.lock(); knownNames[pid] = (display, name); lock.unlock()
        return (display, name)
    }

    private func forget(pidsOutside seen: Set<Int32>) {
        lock.lock()
        knownBundleIDs = knownBundleIDs.filter { seen.contains($0.key) }
        knownNames = knownNames.filter { seen.contains($0.key) }
        lock.unlock()
    }

    // MARK: - Input

    /// ⚠️ **`nil`, never `false`, on any failure.** Both halves must be positively true for a process to
    /// count as holding microphone input, and either being unreadable makes the answer unknown — which
    /// the rule refuses to treat as idle.
    private func inputState(of object: UInt32) -> Bool? {
        switch reader.isRunningInput(of: object) {
        case .unreadable:
            return nil
        case .absent:
            return nil
        case .value(false):
            return false
        case .value(true):
            switch reader.hasInputDevices(of: object) {
            case .value(let hasInput): return hasInput
            case .absent: return false
            case .unreadable: return nil
            }
        }
    }
}

// MARK: - The HAL adapter

import CoreAudio

/// The production property reads, straight onto CoreAudio's process objects.
///
/// ⚠️ **Read-only, and `SourceConfinementTests` enforces it**: this file may never name
/// `AudioObjectSetPropertyData`. The device adapter writes the Mac's default input, which is the one
/// thing Acta changes outside itself; the reader answering "who is using the microphone" writes nothing.
public final class CoreAudioProcessProperties: AudioProcessPropertyReading, @unchecked Sendable {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "AudioProcessProperties")

    public init() {}

    public func processObjectIDs() -> AudioProcessListReading {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else {
            return .unreadable
        }
        let stride = MemoryLayout<AudioObjectID>.size
        guard size > 0 else { return .list([]) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        var readSize = size
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &readSize, &ids) == noErr else {
            return .unreadable
        }
        return .list(Self.trimmed(ids.map { UInt32($0) }, returnedBytes: readSize, stride: stride))
    }

    /// What the second read actually returned, rather than what the sizing read promised.
    ///
    /// ⚠️ **The list can shrink between the two calls.** Returning the whole allocation then hands back
    /// trailing zeroes as if they were processes; object id 0 fails every property read, so a machine
    /// that briefly lost an audio client would look like a machine full of unidentifiable ones — and,
    /// because unidentifiable observations cost the snapshot its completeness, every live episode would
    /// freeze. Pure and static so this is decided by a test rather than by a race.
    public static func trimmed(_ ids: [UInt32], returnedBytes: UInt32, stride: Int) -> [UInt32] {
        guard stride > 0 else { return [] }
        let returned = Int(returnedBytes) / stride
        guard returned > 0 else { return [] }
        return Array(ids.prefix(min(returned, ids.count)))
    }

    public func processID(of object: UInt32) -> AudioPropertyReading<Int32> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var value: pid_t = 0
        guard AudioObjectGetPropertyData(AudioObjectID(object), &address,
                                         0, nil, &size, &value) == noErr else {
            return .unreadable
        }
        return .value(Int32(value))
    }

    public func bundleID(of object: UInt32) -> AudioPropertyReading<String> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(AudioObjectID(object), &address,
                                         0, nil, &size, &value) == noErr else {
            return .unreadable
        }
        guard let value else { return .absent }
        let string = value.takeRetainedValue() as String
        // An empty identifier is the HAL saying "this process has none", which is a real answer.
        return string.isEmpty ? .absent : .value(string)
    }

    public func isRunningInput(of object: UInt32) -> AudioPropertyReading<Bool> {
        flag(kAudioProcessPropertyIsRunningInput, of: object)
    }

    public func hasInputDevices(of object: UInt32) -> AudioPropertyReading<Bool> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(object), &address,
                                             0, nil, &size) == noErr else {
            return .unreadable
        }
        return .value(size >= UInt32(MemoryLayout<AudioObjectID>.size))
    }

    private func flag(_ selector: AudioObjectPropertySelector,
                      of object: UInt32) -> AudioPropertyReading<Bool> {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(AudioObjectID(object), &address,
                                         0, nil, &size, &value) == noErr else {
            return .unreadable
        }
        return .value(value != 0)
    }
}

extension AudioProcessProjection {
    /// The production wiring.
    public static func live() -> AudioProcessProjection {
        AudioProcessProjection(reader: CoreAudioProcessProperties())
    }
}
