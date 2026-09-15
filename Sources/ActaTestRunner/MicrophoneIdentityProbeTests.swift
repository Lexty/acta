import ActaKit
@testable import ActaRuntime
import Foundation
import Testing

/// The live divergence probe — **and, first, proof that its oracle can fail.**
///
/// See `MicrophoneIdentityProbe` for the procedure and the claim. The order of this file is the
/// argument: the matcher is driven against fabricated observations until it is shown to report a
/// divergence, to refuse to invent one, and to refuse to call an empty comparison a pass. Only then is
/// it pointed at the machine. A probe whose oracle has never failed is a green light wired to nothing.
@Suite("Microphone identity probe")
struct MicrophoneIdentityProbeTests {
    private typealias Probe = MicrophoneIdentityProbe
    private typealias Device = MicrophoneIdentityProbe.ObservedDevice

    private static func observation(_ devices: [Device],
                                    defaultInput: Device? = nil) -> Probe.Observation {
        Probe.Observation(devices: devices, defaultInput: defaultInput)
    }

    private static let builtIn = Device(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private static let headset = Device(uid: "00-00-5E-00-53-02:input", name: "AirPods Max")

    // MARK: - The oracle, before it is believed

    /// ⚠️ **The control the whole task turns on.** A future macOS that keeps the display name and
    /// changes the identity is the exact shape of the failure this probe exists to catch — and if the
    /// matcher cannot report it here, against a fabricated pair, it will never report it against a
    /// machine.
    @Test("a device named the same by both APIs with two different identities is a divergence")
    func divergenceIsDetected() {
        let comparison = Probe.compare(
            coreAudio: Self.observation([Self.builtIn]),
            avFoundation: Self.observation([Device(uid: "0x1100000", name: "MacBook Pro Microphone")]))

        #expect(comparison.verdict == .divergent)
        #expect(comparison.divergent.count == 1)
        #expect(comparison.divergent.first?.halUID == "BuiltInMicrophoneDevice")
        #expect(comparison.divergent.first?.avUID == "0x1100000")
        #expect(comparison.agreed.isEmpty)
    }

    @Test("identical identities on both sides agree")
    func agreementIsDetected() {
        let comparison = Probe.compare(coreAudio: Self.observation([Self.builtIn, Self.headset]),
                                       avFoundation: Self.observation([Self.headset, Self.builtIn]))
        #expect(comparison.verdict == .agreed)
        #expect(comparison.agreed.count == 2)
        #expect(comparison.divergent.isEmpty)
        #expect(comparison.uncorrespondable.isEmpty)
    }

    /// ⚠️ **Nothing compared is not a pass.** This is what a total identity divergence looks like from
    /// inside the matcher — no name corresponds, so no pair disagrees — and it is also what a broken
    /// `AVFoundation` read looks like. Both must be refused, and `.agreed` must be unreachable from
    /// here, or the probe reports success by having done nothing.
    @Test("a comparison that corresponded nothing is inconclusive, never agreed")
    func anEmptyComparisonIsNotAPass() {
        let nothing = Probe.compare(coreAudio: Self.observation([Self.builtIn]),
                                    avFoundation: Self.observation([]))
        #expect(nothing.verdict == .inconclusive)
        #expect(nothing.uncorrespondable == [.onlyInCoreAudio(name: "MacBook Pro Microphone",
                                                              uid: "BuiltInMicrophoneDevice")])

        // And the degenerate case: two APIs that both described nothing.
        #expect(Probe.compare(coreAudio: Self.observation([]),
                              avFoundation: Self.observation([])).verdict == .inconclusive)
    }

    /// ⚠️ **The inverse error, and it is just as fatal.** Two identical microphones carry one name, so
    /// pairing them is a coin toss — and a matcher that tossed it would call a 50 % arbitrary mismatch a
    /// divergence, cry wolf, and get itself switched off. Ambiguity corresponds to nothing. This is the
    /// same fact production encodes by keying identity on the UID and never on the name.
    @Test("two devices sharing a name correspond to nothing and are not a divergence")
    func anAmbiguousNameIsNotADivergence() {
        let comparison = Probe.compare(
            coreAudio: Self.observation([Device(uid: "USB_A", name: "USB Microphone"),
                                         Device(uid: "USB_B", name: "USB Microphone")]),
            avFoundation: Self.observation([Device(uid: "USB_B", name: "USB Microphone"),
                                            Device(uid: "USB_A", name: "USB Microphone")]))

        #expect(comparison.divergent.isEmpty, "an ambiguous name was reported as a divergence")
        #expect(comparison.uncorrespondable == [.ambiguousName("USB Microphone")])
        #expect(comparison.verdict == .inconclusive, "nothing was actually compared")
    }

    /// A device only one API lists is **incomplete coverage**, not a failure — and it must not drag the
    /// verdict down when something else was genuinely compared.
    @Test("a device listed by one API only leaves the verdict to the devices that corresponded")
    func oneSidedDevicesAreCoverageNotFailure() {
        let comparison = Probe.compare(
            coreAudio: Self.observation([Self.builtIn, Device(uid: "Loopback_UID", name: "Teams Audio")]),
            avFoundation: Self.observation([Self.builtIn, Device(uid: "Cam_UID", name: "Studio Display")]))

        #expect(comparison.verdict == .agreed)
        #expect(comparison.agreed.count == 1)
        #expect(comparison.uncorrespondable.count == 2)
        #expect(comparison.uncorrespondable.contains(.onlyInCoreAudio(name: "Teams Audio",
                                                                      uid: "Loopback_UID")))
        #expect(comparison.uncorrespondable.contains(.onlyInAVFoundation(name: "Studio Display",
                                                                         uid: "Cam_UID")))
    }

    // MARK: - The skip decision, which is where the probe once lied

    /// ⚠️ **The probe committed the very error it exists to catch, and this is the guard.** Its first
    /// version reduced the enumeration to `[AudioInputDevice]`, returning `[]` when the HAL *failed* —
    /// so a machine whose CoreAudio would not answer skipped all four live tests as "this Mac lists no
    /// input device" and exited 0. A review injected an enumeration failure into the real adapter and
    /// measured exactly that. Absence must be **proved**, never inferred from a read that did not
    /// happen.
    @Test("an unreadable HAL is not an empty machine")
    func anUnreadableHALProvesNothing() {
        let unreadable = Probe.coverage(from: .failed(reason: "scripted"))
        #expect(unreadable == .unreadable("scripted"))
        #expect(unreadable.provesAbsence { _ in true } == false,
                "a failed enumeration was accepted as proof that this Mac has no microphones")
        #expect(unreadable.provesAbsence(of: \.isBluetooth) == false)
        #expect(unreadable.complaint != nil)
    }

    /// ⚠️ And a **partial** read proves nothing either: the device that would have answered the
    /// question may be exactly the one the HAL would not describe.
    @Test("a partial read does not prove a device is absent")
    func aPartialReadProvesNoAbsence() {
        let partial = Probe.coverage(from: .devices([.builtInMic()],
                                                    uninspectable: ["a USB device that would not answer"]))
        #expect(partial.provesAbsence(of: \.isBluetooth) == false,
                "an incomplete enumeration was accepted as proof that no headset is connected")
        #expect(partial.isComplete == false)
        #expect(partial.devices == [.builtInMic()])
        #expect(partial.complaint != nil)
    }

    /// The converse, or the guard above would just disable every skip: a complete enumeration really
    /// does prove absence, and absent hardware stays a skip rather than becoming a failure.
    @Test("a complete enumeration proves absence")
    func aCompleteReadProvesAbsence() {
        let complete = Probe.coverage(from: .devices([.builtInMic()], uninspectable: []))
        #expect(complete.provesAbsence(of: \.isBluetooth), "absent hardware stopped being a skip")
        #expect(complete.provesAbsence { _ in true } == false)
        #expect(complete.isComplete)
        #expect(complete.complaint == nil)
    }

    /// ⚠️ The same loss one level on: an observation that drops `uninspectable` arrives as a complete
    /// description of the machine, and an "agreed" verdict then covers less than it claims.
    @Test("a partial HAL read is not a successful complete observation")
    func aPartialHALReadIsCarriedIntoTheObservation() {
        let directory = FakeAudioDeviceDirectory(devices: [.builtInMic()],
                                                 defaultInput: "BuiltInMicrophoneDevice")
        directory.setDevices([.builtInMic()], uninspectable: ["USB device UID could not be read"])
        guard case .success(let observation) = Probe.observeCoreAudio(directory) else {
            Issue.record("a partial read should still observe what it could describe"); return
        }
        #expect(observation.uninspectable == ["USB device UID could not be read"])
        #expect(observation.devices.count == 1)
    }

    /// And a failed enumeration is a failed observation, not an empty one.
    @Test("a failed enumeration does not observe an empty machine")
    func aFailedEnumerationIsAFailure() {
        let directory = FakeAudioDeviceDirectory(devices: [])
        directory.failEnumeration(reason: "scripted")
        guard case .failure(let failure) = Probe.observeCoreAudio(directory) else {
            Issue.record("a failed enumeration was observed as a machine with no microphones"); return
        }
        #expect(failure.reason.contains("enumeration failed"))
    }

    // MARK: - The role-based comparison, which needs no names

    @Test("the default input is compared by role, and a mismatch is a divergence")
    func theDefaultInputFindingIsDetected() {
        #expect(Probe.compareDefaultInput(
            coreAudio: Self.observation([Self.builtIn], defaultInput: Self.builtIn),
            avFoundation: Self.observation([Self.builtIn], defaultInput: Self.builtIn))
            == .agreed(uid: "BuiltInMicrophoneDevice"))

        #expect(Probe.compareDefaultInput(
            coreAudio: Self.observation([Self.builtIn], defaultInput: Self.builtIn),
            avFoundation: Self.observation([], defaultInput: Device(uid: "0x1100000", name: "")))
            == .divergent(coreAudio: "BuiltInMicrophoneDevice", avFoundation: "0x1100000"))

        // A Mac with no input hardware: nothing proved, nothing wrong.
        #expect(Probe.compareDefaultInput(coreAudio: Self.observation([]),
                                          avFoundation: Self.observation([])) == .neitherReportsOne)

        // ⚠️ One API sees a default input and the other sees none. The reads are bracketed against the
        // machine moving, so on a settled machine this is the two APIs disagreeing about the same
        // property — reported as its own category rather than folded into "agreed" or "nothing here".
        #expect(Probe.compareDefaultInput(
            coreAudio: Self.observation([Self.builtIn], defaultInput: Self.builtIn),
            avFoundation: Self.observation([Self.builtIn]))
            == .disagreedOnExistence(coreAudio: "BuiltInMicrophoneDevice", avFoundation: nil))
    }

    /// The bracketing itself: a machine whose devices change under the probe yields a failure to
    /// observe, **not** an observation. Driven through a fake that changes on every read, because a
    /// real machine cannot be asked to do this on cue.
    @Test("a machine that moves mid-probe is reported as unobserved, not as a divergence")
    func aMovingMachineIsNotADivergence() {
        let churning = ChurningDirectory()
        guard case .failure(let reason) = Probe.observeLive(churning, attempts: 3) else {
            Issue.record("a machine changing under the probe was reported as a settled observation")
            return
        }
        #expect(reason.reason.contains("changed while the probe was reading"))
        #expect(churning.reads >= 6, "the pass must actually have been retried")
    }

    /// ⚠️ **The warm-up this file depends on, guarded rather than left to a comment.** Deleting
    /// `MicrophoneIdentityProbe.warmUp()` from `main.swift` costs nothing visible here — the probe still
    /// passes — while taking the full gate from 7.6 s to 67 s and failing an unrelated pipeline test.
    /// A performance precondition nobody can see is one somebody will remove.
    @Test("AVFoundation's capture stack was warmed before the suite started")
    func theCaptureStackWasWarmedBeforeTheSuite() {
        #expect(MicrophoneIdentityProbe.isWarm, """
            main.swift no longer warms AVFoundation before the suite runs. The first DiscoverySession in \
            a process costs 221 ms of one-time initialization; paid concurrently with the pipeline \
            suites it makes SegmentWriter.finish exhaust its 30-second pendingWrites wait. See \
            docs/backlog/segment-finalisation-waits-under-parallel-tests.md
            """)
    }

    // MARK: - The live probe

    /// ⚠️ **The one test in this file that is worth anything, and it can only run on real hardware.**
    /// Everything above proves the oracle works; this is the observation. `.enabled(if:)` rather than an
    /// early `return`: a Mac that lists no input device covered nothing, and that has to read as
    /// *skipped* in the output, never as a pass.
    @Test("CoreAudio and AVFoundation name this machine's microphones identically",
          .enabled(if: MicrophoneIdentityProbe.shouldProbeThisMachine(),
                   "this Mac lists no input device: identity correspondence unverified"))
    func theTwoAPIsAgreeOnThisMachine() {
        guard case .success(let live) = Probe.observeLive(CoreAudioDeviceDirectory()) else {
            Issue.record("the machine could not be observed: identity correspondence unverified")
            return
        }
        let comparison = Probe.compare(coreAudio: live.coreAudio, avFoundation: live.avFoundation)
        Probe.report("\n[microphone identity probe] devices\n\(comparison.report)")

        // ⚠️ An "agreed" verdict over a read that could not describe part of the machine covers less
        // than it says. Reported rather than folded into the verdict, so the gap is named.
        if !live.coreAudio.uninspectable.isEmpty {
            let missing = live.coreAudio.uninspectable.joined(separator: ", ")
            Issue.record("the identity comparison is incomplete: the HAL would not describe \(missing)")
        }

        #expect(comparison.verdict == .agreed, """
            the two APIs disagree about this machine's microphone identities — \
            the priority list is keyed on a UID that ScreenCaptureKit may no longer accept:
            \(comparison.report)
            """)
    }

    /// The role-based half, which shares no mechanism with the one above: no names, no lists, one
    /// property read from each API.
    @Test("CoreAudio and AVFoundation name the same system default input",
          .enabled(if: MicrophoneIdentityProbe.shouldProbeThisMachine(),
                   "this Mac lists no input device: default-input correspondence unverified"))
    func theTwoAPIsAgreeOnTheDefaultInput() {
        guard case .success(let live) = Probe.observeLive(CoreAudioDeviceDirectory()) else {
            Issue.record("the machine could not be observed: default-input correspondence unverified")
            return
        }
        let finding = Probe.compareDefaultInput(coreAudio: live.coreAudio, avFoundation: live.avFoundation)
        Probe.report("[microphone identity probe] default input: \(finding)")

        switch finding {
        case .agreed, .neitherReportsOne:
            break
        case .divergent(let hal, let av):
            Issue.record("the two APIs name different system default inputs: CoreAudio=\(hal) AVFoundation=\(av)")
        case .disagreedOnExistence(let hal, let av):
            Issue.record("""
                the two APIs disagree that there is a system default input at all: \
                CoreAudio=\(hal ?? "<none>") AVFoundation=\(av ?? "<none>")
                """)
        }
    }

    /// ⚠️ **The device the feature exists for.** A Bluetooth headset is the one whose identity is least
    /// obviously stable — it is a MAC address with a scope suffix — and it is the device macOS keeps
    /// making the default input behind the user's back. Skipped **visibly** when nothing is paired:
    /// "no headset connected" is missing coverage, and reporting it as a pass is the failure mode this
    /// whole file is written against.
    @Test("the Bluetooth headset carries one identity across both APIs",
          .enabled(if: MicrophoneIdentityProbe.shouldProbeBluetooth(),
                   "no Bluetooth microphone is connected: the headset identity is unverified"))
    func theBluetoothHeadsetCorresponds() {
        expectCorresponded(MicrophoneIdentityProbe.liveCoverage(),
                           matching: \.isBluetooth, kind: "Bluetooth")
    }

    @Test("the built-in microphone carries one identity across both APIs",
          .enabled(if: MicrophoneIdentityProbe.shouldProbeBuiltIn(),
                   "this Mac has no built-in microphone: that identity is unverified"))
    func theBuiltInMicrophoneCorresponds() {
        expectCorresponded(MicrophoneIdentityProbe.liveCoverage(),
                           matching: { $0.transport == .builtIn }, kind: "built-in")
    }

    /// Shared by the two hardware-specific probes: the named devices must appear among the
    /// correspondences **and** agree. ⚠️ Absence from `agreed` is checked explicitly — a device that
    /// fell into `uncorrespondable` proved nothing, and silently accepting that is precisely how a
    /// discrepancy would be filed as "missing".
    private func expectCorresponded(_ coverage: Probe.Coverage,
                                     matching: (AudioInputDevice) -> Bool,
                                     kind: String) {
        // ⚠️ **An unreadable or partial enumeration is not "no such device".** The trait above only
        // skips on *proved* absence, so reaching here with anything but a complete read means the
        // machine could not be described — which is a finding, not a quiet pass over an empty list.
        if let complaint = coverage.complaint {
            Issue.record("the \(kind) identity is unverified — \(complaint)")
            return
        }
        let devices = coverage.devices.filter(matching)
        guard case .success(let live) = Probe.observeLive(CoreAudioDeviceDirectory()) else {
            Issue.record("the machine could not be observed: \(kind) identity unverified")
            return
        }
        let comparison = Probe.compare(coreAudio: live.coreAudio, avFoundation: live.avFoundation)
        Probe.report("[microphone identity probe] \(kind): \(devices.map(\.uid))")

        for device in devices {
            guard let pair = (comparison.agreed + comparison.divergent).first(where: { $0.halUID == device.uid })
            else {
                Issue.record("""
                    the \(kind) microphone \(device.uid) (\(device.name)) could not be corresponded across \
                    the APIs, so its identity is unproved: \(comparison.report)
                    """)
                continue
            }
            let complaint = "the \(kind) microphone is two different identities: "
                + "CoreAudio=\(pair.halUID) AVFoundation=\(pair.avUID)"
            #expect(pair.agrees, "\(complaint)")
        }
    }
}

/// A directory whose device list changes on every read — the one condition a real machine will not
/// reproduce on demand, and the one the bracketing exists for.
private final class ChurningDirectory: AudioDeviceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return counter }

    func enumerateInputDevices() -> DeviceEnumeration {
        lock.lock(); counter += 1; let n = counter; lock.unlock()
        return .devices([AudioInputDevice(uid: "Device_\(n)",
                                          name: "Device \(n)",
                                          transport: .usb,
                                          inputChannels: 1,
                                          canBeSystemDefault: .yes,
                                          isAlive: .yes,
                                          isRunningSomewhere: false)],
                        uninspectable: [])
    }

    func currentDefaultInput() -> DefaultInputRead { .none }
    func observe(_ handler: @escaping @Sendable (DeviceChange) -> Void) -> ObservationOutcome {
        .failed(reason: "not used by the probe")
    }
}
