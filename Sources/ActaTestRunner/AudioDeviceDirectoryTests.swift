import ActaKit
import ActaRuntime
import Foundation
import Testing

// The device-directory seam: the pure device model, the contract the fake and the real adapter share,
// and one live check against this machine's own CoreAudio.
//
// The theme running through the whole file is that **a refusal must never be expressible as an ordinary
// answer**. Every assertion here exists because some way of collapsing "the OS would not tell me" into
// `[]`, `false` or "no default" was available and had to be closed.

// MARK: - The device model

@Test
func aFailedEligibilityQueryIsNotIneligibility() {
    // The measured bug: `kAudioDevicePropertyDeviceCanBeDefaultDevice` in the global scope returns
    // `kAudioHardwareUnknownPropertyError` for *every* device, and a helper that ignores the `OSStatus`
    // hands back its zero-initialised buffer — indistinguishable from an honest "no". Keeping the third
    // case is what makes the difference representable.
    #expect(DeviceCapability.unknown != DeviceCapability.no)

    // And the decision that follows from it: an unanswered query counts as *eligible*. Being
    // pessimistic here is what turns one broken property read into a machine with no selectable
    // microphone at all, which is the failure this whole design is built to avoid.
    #expect(AudioInputDevice.unknownEligibility().isSystemDefaultCandidate)
    #expect(!AudioInputDevice.teamsLoopback().isSystemDefaultCandidate)
}

@Test
func bluetoothIsRecognisedThroughBothTransportConstants() {
    // `AudioHardwareBase.h` defines `'blue'` (line 616) and `'blea'` (line 617) separately, so any
    // caller matching `.bluetooth` alone has a hole. `isBluetooth` is the one place that closes it.
    var classic = AudioInputDevice.airPods()
    classic.transport = .bluetooth
    var lowEnergy = AudioInputDevice.airPods()
    lowEnergy.transport = .bluetoothLE

    #expect(classic.isBluetooth)
    #expect(lowEnergy.isBluetooth)
    #expect(!AudioInputDevice.builtInMic().isBluetooth)
    #expect(!AudioInputDevice.usbMic().isBluetooth)
}

@Test
func softwareEndpointsAreNotPhysicalEvenWhenTheyMayBeTheDefault() {
    // ⚠️ The fixtures record what was *measured*, not what is intuitive: BlackHole and the aggregate
    // device both answer "yes" to `canBeDefaultDevice`. So "can be the system default" cannot stand in
    // for "is a real microphone" — an earlier draft of the plan cited exactly these two as examples of
    // the opposite and was wrong.
    #expect(AudioInputDevice.blackHole().canBeSystemDefault == .yes)
    #expect(AudioInputDevice.aggregate().canBeSystemDefault == .yes)
    #expect(!AudioInputDevice.blackHole().isPhysical)
    #expect(!AudioInputDevice.aggregate().isPhysical)
    #expect(AudioInputDevice.builtInMic().isPhysical)
    #expect(AudioInputDevice.airPods().isPhysical)
}

@Test
func presenceIsNotAvailability() {
    // A device can stop being usable without leaving `kAudioHardwarePropertyDevices`, which is why the
    // directory carries `isAlive` and watches it separately from the device list.
    let dead = AudioInputDevice.builtInMic(alive: false)
    #expect(dead.inputChannels > 0)
    #expect(!dead.isAvailable)
    #expect(!dead.isCaptureCandidate)
    #expect(!dead.isSystemDefaultCandidate)
}

// MARK: - The directory contract

@Test
func anEnumerationFailureIsNotAnEmptyDeviceList() {
    let directory = FakeAudioDeviceDirectory(devices: [])
    #expect(directory.enumerateInputDevices() == .devices([]))

    directory.failEnumeration(reason: "OSStatus -4 ('who?')")
    guard case .failed = directory.enumerateInputDevices() else {
        Issue.record("a scripted enumeration failure must not read as an empty machine")
        return
    }
}

@Test
func observationIsBroadcastAndSubscriptionsAreIndependent() {
    // Two consumers subscribe — the reconciler and the recording-side observer — and neither may
    // silently win or lose the events. A single-consumer stream would make that ordering-dependent.
    let directory = FakeAudioDeviceDirectory(devices: [.builtInMic()])
    let first = Recorder()
    let second = Recorder()

    guard case .observing(let firstToken) = directory.observe({ first.append($0) }),
          case .observing(let secondToken) = directory.observe({ second.append($0) }) else {
        Issue.record("expected both subscriptions to be accepted")
        return
    }

    directory.emit(.deviceListChanged)
    #expect(first.changes == [.deviceListChanged])
    #expect(second.changes == [.deviceListChanged])

    // Cancelling one leaves the other delivering — the half a shared stream would break.
    firstToken.cancel()
    directory.emit(.defaultInputChanged)
    #expect(first.changes == [.deviceListChanged])
    #expect(second.changes == [.deviceListChanged, .defaultInputChanged])

    secondToken.cancel()
    directory.emit(.readinessChanged(uid: "BuiltInMicrophoneDevice"))
    #expect(second.changes == [.deviceListChanged, .defaultInputChanged])
    #expect(directory.subscriberCount == 0)
}

@Test
func cancellingTwiceIsHarmless() {
    let directory = FakeAudioDeviceDirectory(devices: [])
    guard case .observing(let token) = directory.observe({ _ in }) else {
        Issue.record("expected a subscription"); return
    }
    token.cancel()
    token.cancel()
    #expect(directory.subscriberCount == 0)
}

@Test
func aFailedSubscriptionIsReportedRatherThanPassingForAQuietMachine() {
    // The third outcome, and the one that hides: a directory that never registered its listeners looks
    // exactly like a machine where nothing is happening — no events, no error, no difference.
    let directory = FakeAudioDeviceDirectory(devices: [.builtInMic()])
    directory.failObservation(reason: "listener registration refused")
    guard case .failed = directory.observe({ _ in }) else {
        Issue.record("a failed registration must not present as a live subscription")
        return
    }
}

@Test
func aWriteThatFailsIsStillRecordedAsAttempted() {
    // "It tried and the OS refused" and "it never tried" are different bugs, and only one of them is
    // the reconciler's fault. The fake keeps them apart so a test can tell.
    let directory = FakeAudioDeviceDirectory(devices: [.builtInMic()], defaultInput: "00-00-5E-00-53-01:input")
    directory.scriptWrites([.failed(reason: "OSStatus 560227702")], thereafter: .written)

    #expect(directory.setDefaultInput(uid: "BuiltInMicrophoneDevice") == .failed(reason: "OSStatus 560227702"))
    #expect(directory.attemptedWrites == ["BuiltInMicrophoneDevice"])
    // The failed write left the default where it was: a fake that "succeeded anyway" would hide every
    // fight-back bug the reconciler exists to survive.
    #expect(directory.currentDefaultInput() == .device(uid: "00-00-5E-00-53-01:input"))

    #expect(directory.setDefaultInput(uid: "BuiltInMicrophoneDevice") == .written)
    #expect(directory.currentDefaultInput() == .device(uid: "BuiltInMicrophoneDevice"))
}

/// Collects changes from a subscription. A class, because the handler is `@Sendable` and the assertions
/// run after it.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DeviceChange] = []
    func append(_ change: DeviceChange) { lock.lock(); storage.append(change); lock.unlock() }
    var changes: [DeviceChange] { lock.lock(); defer { lock.unlock() }; return storage }
}

// MARK: - The real adapter, against this machine

@Test
func theCoreAudioAdapterEnumeratesThisMachine() {
    // Not a fixture: the real HAL. It cannot assert *which* devices exist, but it can assert that the
    // adapter got an answer at all, and that every device it reports is well formed.
    let directory = CoreAudioDeviceDirectory()
    guard case .devices(let devices) = directory.enumerateInputDevices() else {
        Issue.record("CoreAudio enumeration failed on this machine")
        return
    }
    for device in devices {
        #expect(!device.uid.isEmpty)
        #expect(!device.name.isEmpty)
        #expect(device.inputChannels > 0, "an input device with no input channels must be filtered out")
    }
    // Reading the default must not report a failure on a working machine. `.none` stays legal: a Mac
    // with no input hardware is a real configuration.
    if case .failed(let reason) = directory.currentDefaultInput() {
        Issue.record("reading the default input failed: \(reason)")
    }
}

@Test
func theEligibilityQueryUsesTheScopeThatActuallyAnswers() {
    // ⚠️ **The regression test for the measured scope trap.** Asked in `kAudioObjectPropertyScopeGlobal`
    // this property returns `kAudioHardwareUnknownPropertyError` for every device, so the adapter would
    // report `.unknown` across the board — and nothing else in the suite would notice, because
    // `.unknown` is a legitimate value for any single device. It is only *universal* `.unknown` that
    // identifies the bug. Skipped visibly rather than silently when the machine lists no input device.
    let directory = CoreAudioDeviceDirectory()
    guard case .devices(let devices) = directory.enumerateInputDevices(), !devices.isEmpty else {
        Issue.record("no input devices on this machine: eligibility scope unverified")
        return
    }
    #expect(devices.contains { $0.canBeSystemDefault != .unknown },
            "every device reported unknown eligibility — the query is being asked in the wrong scope")
}
