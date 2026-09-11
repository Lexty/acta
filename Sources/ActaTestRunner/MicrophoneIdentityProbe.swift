import ActaKit
import AVFoundation
@testable import ActaRuntime
import Foundation

/// Two **independent live observations** of this machine's microphones, and the procedure that
/// compares them.
///
/// ## Why this exists
///
/// The whole microphone-priority design rests on one equality Apple documents nowhere as a single
/// identity: the string CoreAudio returns for `kAudioDevicePropertyDeviceUID` and the string
/// `AVCaptureDevice.uniqueID` returns are the same string, which is what lets a UID read from the HAL
/// be handed to `SCStreamConfiguration.microphoneCaptureDeviceID`. It was **measured**, on one machine,
/// on one OS version. If a future macOS diverges, every line of Acta still compiles and either the
/// wrong microphone is recorded or capture fails outright.
///
/// ## The matching procedure, and why it is not circular
///
/// ⚠️ **Correspondence must not be established by the very identity under test.** Matching the two
/// lists by UID and then asserting the UIDs are equal proves nothing at all — it is `x == x` dressed up
/// as a probe. So devices are corresponded by something else, and the UID is only ever the thing
/// *compared*:
///
/// 1. **By role** — each API is asked, independently, which device is the system default input
///    (`kAudioHardwarePropertyDefaultInputDevice` / `AVCaptureDevice.default(for: .audio)`). The
///    correspondence is "the default", and the two UIDs must be the same string.
/// 2. **By display name** — `kAudioObjectPropertyName` against `AVCaptureDevice.localizedName`. A name
///    that is not unique on both sides corresponds to nothing and is **excluded**: two identical USB
///    microphones would otherwise let the matcher pair them arbitrarily and call the resulting
///    mismatch a divergence. That is why identity is keyed on the UID in production and why ambiguity
///    here is reported as *uncorrespondable*, never as a failure.
///
/// ## What it claims
///
/// It **detects divergence on the devices this machine actually exercises**. It does not guarantee
/// compatibility with a future macOS: a device nobody plugged in is a device nobody checked, which is
/// exactly why absent hardware is reported as a visible skip rather than a pass. And UID equality does
/// **not** prove ScreenCaptureKit captured the intended microphone — that claim needs ears and stays in
/// manual acceptance.
///
/// ⚠️ It lives in `ActaTestRunner` **by design**: it must import `AVFoundation` and name device
/// identities across both APIs, which the production confinements forbid. `SourceConfinementTests`
/// scans the four production targets and nothing else precisely so this file can exist without an
/// exemption list.
enum MicrophoneIdentityProbe {
    // MARK: - What one API said

    /// One device as one API described it. Two fields, because those are the two an API can be asked
    /// for without consulting the other.
    struct ObservedDevice: Equatable, Sendable {
        var uid: String
        var name: String
    }

    /// One API's whole answer.
    struct Observation: Equatable, Sendable {
        var devices: [ObservedDevice]
        /// The device *this* API names as the system default input, if it names one. `nil` is a real
        /// answer (no default input), distinct from the read failing — a failure never reaches here.
        var defaultInput: ObservedDevice?
    }

    // MARK: - The result categories

    /// A pair the procedure was able to correspond, and what the two APIs called it.
    struct Correspondence: Equatable, Sendable {
        var name: String
        var halUID: String
        var avUID: String
        var agrees: Bool { halUID == avUID }
    }

    /// Why a device could not be corresponded. ⚠️ **None of these is a failure**, and keeping them
    /// separate from `divergent` is the single most important line in this file: classifying a genuine
    /// discrepancy as "missing — skip" is the one outcome that would defeat the probe's purpose, and
    /// the inverse — calling absent hardware a divergence — would make the probe cry wolf until it was
    /// switched off.
    enum Uncorrespondable: Equatable, Sendable {
        /// The name occurs more than once on at least one side; pairing would be a coin toss.
        case ambiguousName(String)
        /// CoreAudio lists it; `AVCaptureDevice` does not expose anything by that name.
        case onlyInCoreAudio(name: String, uid: String)
        /// `AVCaptureDevice` lists it; CoreAudio's input enumeration does not.
        case onlyInAVFoundation(name: String, uid: String)
    }

    enum Verdict: Equatable, Sendable {
        /// At least one device corresponded, and every correspondence agreed.
        case agreed
        /// At least one corresponded device is named by two different identities. **The failure.**
        case divergent
        /// Nothing could be corresponded at all. ⚠️ **Not a pass.** An oracle that cannot fail
        /// rubber-stamps everything, and "I compared nothing and found no disagreement" is exactly that
        /// — it is also what a total identity divergence looks like from here.
        case inconclusive
    }

    struct Comparison: Equatable, Sendable {
        var agreed: [Correspondence]
        var divergent: [Correspondence]
        var uncorrespondable: [Uncorrespondable]

        var verdict: Verdict {
            if !divergent.isEmpty { return .divergent }
            return agreed.isEmpty ? .inconclusive : .agreed
        }

        /// The whole finding in one readable block, for the human who ran the probe deliberately.
        var report: String {
            var lines = ["verdict: \(verdict)"]
            for pair in agreed { lines.append("  agreed      \(pair.name): \(pair.halUID)") }
            for pair in divergent {
                lines.append("  DIVERGENT   \(pair.name): CoreAudio=\(pair.halUID) AVFoundation=\(pair.avUID)")
            }
            for item in uncorrespondable {
                switch item {
                case .ambiguousName(let name):
                    lines.append("  unmatched   \(name): the name is not unique — cannot correspond")
                case .onlyInCoreAudio(let name, let uid):
                    lines.append("  unmatched   \(name): CoreAudio only (\(uid))")
                case .onlyInAVFoundation(let name, let uid):
                    lines.append("  unmatched   \(name): AVFoundation only (\(uid))")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// The default-input comparison, which needs no names at all.
    enum DefaultInputFinding: Equatable, Sendable {
        case agreed(uid: String)
        /// Both APIs name a default input and they are different strings. **The failure.**
        case divergent(coreAudio: String, avFoundation: String)
        /// Neither reports one — a Mac with no input hardware. Nothing proved, nothing wrong.
        case neitherReportsOne
        /// One API says there is a default input and the other says there is none. ⚠️ Also a failure:
        /// the reads are bracketed against a change (see `observeLive`), so a settled machine that
        /// answers this way is answering inconsistently about the same property.
        case disagreedOnExistence(coreAudio: String?, avFoundation: String?)
    }

    // MARK: - The procedure itself, pure

    static func compare(coreAudio: Observation, avFoundation: Observation) -> Comparison {
        let halByName = Dictionary(grouping: coreAudio.devices, by: \.name)
        let avByName = Dictionary(grouping: avFoundation.devices, by: \.name)

        var agreed: [Correspondence] = []
        var divergent: [Correspondence] = []
        var uncorrespondable: [Uncorrespondable] = []

        for name in Set(halByName.keys).union(avByName.keys).sorted() {
            let hal = halByName[name] ?? []
            let av = avByName[name] ?? []
            // ⚠️ Ambiguity is checked before absence, because a name that repeats on one side is
            // uncorrespondable whatever the other side holds.
            if hal.count > 1 || av.count > 1 {
                uncorrespondable.append(.ambiguousName(name))
                continue
            }
            switch (hal.first, av.first) {
            case (let hal?, let av?):
                let pair = Correspondence(name: name, halUID: hal.uid, avUID: av.uid)
                if pair.agrees { agreed.append(pair) } else { divergent.append(pair) }
            case (let hal?, nil):
                uncorrespondable.append(.onlyInCoreAudio(name: name, uid: hal.uid))
            case (nil, let av?):
                uncorrespondable.append(.onlyInAVFoundation(name: name, uid: av.uid))
            case (nil, nil):
                continue
            }
        }
        return Comparison(agreed: agreed, divergent: divergent, uncorrespondable: uncorrespondable)
    }

    static func compareDefaultInput(coreAudio: Observation, avFoundation: Observation) -> DefaultInputFinding {
        switch (coreAudio.defaultInput?.uid, avFoundation.defaultInput?.uid) {
        case (nil, nil):
            return .neitherReportsOne
        case (let hal?, let av?):
            return hal == av ? .agreed(uid: hal) : .divergent(coreAudio: hal, avFoundation: av)
        case (let hal, let av):
            return .disagreedOnExistence(coreAudio: hal, avFoundation: av)
        }
    }

    /// Why the probe could not take an observation at all. ⚠️ A third outcome next to agreement and
    /// divergence, and it must never collapse into either: "I could not look" is not "they agree".
    struct ObservationFailure: Error, Equatable, Sendable {
        var reason: String
    }

    // MARK: - The live observations

    /// What CoreAudio says, read through **production's own adapter**.
    ///
    /// ⚠️ Deliberately not a private HAL reader written for the probe: the string that will be handed
    /// to `SCStreamConfiguration` is the one `CoreAudioDeviceDirectory` produces, so that is the one
    /// that has to be checked. A second reader here would prove the probe agrees with itself.
    static func observeCoreAudio(_ directory: any AudioDeviceReading) -> Result<Observation, ObservationFailure> {
        guard case .devices(let devices, _) = directory.enumerateInputDevices() else {
            return .failure(ObservationFailure(reason: "CoreAudio enumeration failed"))
        }
        let observed = devices.map { ObservedDevice(uid: $0.uid, name: $0.name) }
        let defaultInput: ObservedDevice?
        switch directory.currentDefaultInput() {
        case .device(let uid):
            defaultInput = observed.first { $0.uid == uid }
                ?? ObservedDevice(uid: uid, name: "")
        case .none:
            defaultInput = nil
        case .failed(let reason):
            return .failure(ObservationFailure(reason: "reading the default input failed: \(reason)"))
        }
        return .success(Observation(devices: observed, defaultInput: defaultInput))
    }

    /// What `AVFoundation` says. The independent half — it consults nothing above.
    static func observeAVFoundation() -> Observation {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                       mediaType: .audio,
                                                       position: .unspecified)
        // ⚠️ `isConnected` filtered: a device object can outlive its hardware, and a stale entry would
        // present as `onlyInAVFoundation` — noise that looks like a finding.
        let devices = session.devices.filter(\.isConnected).map {
            ObservedDevice(uid: $0.uniqueID, name: $0.localizedName)
        }
        let fallback = AVCaptureDevice.default(for: .audio).map {
            ObservedDevice(uid: $0.uniqueID, name: $0.localizedName)
        }
        return Observation(devices: devices, defaultInput: fallback)
    }

    /// Both observations, taken close together and **bracketed against the machine moving**.
    ///
    /// ⚠️ The default input can change between two reads — a headset connecting is exactly the event
    /// this whole feature is about. A divergence reported because the world moved mid-probe would be a
    /// false alarm of the worst kind: the one that gets the probe deleted. So CoreAudio is read again
    /// after `AVFoundation`, and the pass is retried while the two CoreAudio reads disagree.
    static func observeLive(_ directory: any AudioDeviceReading,
                            attempts: Int = 3) -> Result<(coreAudio: Observation, avFoundation: Observation), ObservationFailure> {
        var lastFailure = "the machine never settled"
        for _ in 0 ..< attempts {
            switch observeCoreAudio(directory) {
            case .failure(let failure):
                lastFailure = failure.reason
            case .success(let before):
                let av = observeAVFoundation()
                switch observeCoreAudio(directory) {
                case .failure(let failure):
                    lastFailure = failure.reason
                case .success(let after):
                    if before == after { return .success((coreAudio: after, avFoundation: av)) }
                    lastFailure = "the audio devices changed while the probe was reading them"
                }
            }
        }
        return .failure(ObservationFailure(reason: lastFailure))
    }

    // MARK: - What this machine can cover

    /// The live input devices, for the `.enabled(if:)` conditions below. Absent hardware is not a
    /// failure — it is coverage this run did not have, and it has to be **visible** rather than passed.
    static func liveInputDevices() -> [AudioInputDevice] {
        guard case .devices(let devices, _) = CoreAudioDeviceDirectory().enumerateInputDevices() else {
            return []
        }
        return devices
    }

    static func machineHasAnInputDevice() -> Bool { !liveInputDevices().isEmpty }
    static func machineHasABluetoothInput() -> Bool { liveInputDevices().contains(where: \.isBluetooth) }
    static func machineHasABuiltInInput() -> Bool { liveInputDevices().contains { $0.transport == .builtIn } }

    // MARK: - Warming AVFoundation before the suite runs

    /// ⚠️ **The first `AVCaptureDevice` discovery in a process must happen before the parallel suite
    /// starts, and this is not a style preference — it is measured.**
    ///
    /// Measured on this machine: the first `DiscoverySession` costs **221 ms**, every later one
    /// **0.04 ms** — a one-time initialization of AVFoundation's capture stack. Paying that 221 ms
    /// *inside* the parallel suite took the full gate from **7.6 s to 67 s** and made
    /// `SegmentWriter.finish` exhaust its 30-second `pendingWrites` wait, failing
    /// `aRecordingBackedByAFakeSourceCrossesASegmentBoundaryAndAssembles`. Paying it here, before any
    /// test runs, costs **7.8 s** — the same as not probing at all — and the in-suite discoveries are
    /// then free.
    ///
    /// ⚠️ **The mechanism is not established, and is deliberately not guessed at.** What is measured is
    /// the three numbers above; naming a cause on that evidence is exactly the mistake
    /// `docs/backlog/segment-finalisation-waits-under-parallel-tests.md` exists to record. It is a
    /// second reproducer for the open question in that file, and it is written up there.
    ///
    /// `isWarm` exists so deleting the call fails a test rather than silently restoring a 60-second
    /// flaky gate.
    static func warmUp() {
        _ = observeAVFoundation()
        warmth.lock(); didWarmUp = true; warmth.unlock()
    }

    static var isWarm: Bool { warmth.lock(); defer { warmth.unlock() }; return didWarmUp }

    private static let warmth = NSLock()
    private nonisolated(unsafe) static var didWarmUp = false

    /// Printing is opt-in so an ordinary suite run stays quiet, and a human running the probe
    /// deliberately (`bash Scripts/probe-microphone-identity.sh`) reads the whole finding.
    static var isVerbose: Bool {
        ProcessInfo.processInfo.environment["ACTA_PROBE_VERBOSE"] == "1"
    }

    static func report(_ text: String) {
        guard isVerbose else { return }
        print(text)
    }
}
