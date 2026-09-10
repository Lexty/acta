import ActaKit
import Foundation
import Testing

// The selection policy, driven entirely from literals.
//
// This is why the decision is a pure function and not a method on the reconciler: an override whose
// device vanished, a list whose every entry is absent, a device present but not default-eligible — a
// live machine can almost never be persuaded to produce those on demand, and each of them is a case
// where getting it wrong is silent.

private func devices(_ list: AudioInputDevice...) -> [AudioInputDevice] { list }

@Test
func theOrderOfTheListIsTheOrderOfPreference() {
    let priority = MicrophonePriority(order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
    let selection = MicrophonePolicy.select(from: devices(.builtInMic(), .usbMic(), .airPods()),
                                            priority: priority, purpose: .systemDefault)
    #expect(selection == .selected(.usbMic()))
}

@Test
func anAbsentPreferredDeviceIsSkippedForTheNextOneOnTheList() {
    // The everyday case the whole feature exists for: the USB mic is unplugged, so the built-in wins —
    // and the headset, which is on the machine but not on the list, does not.
    let priority = MicrophonePriority(order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
    let selection = MicrophonePolicy.select(from: devices(.builtInMic(), .airPods()),
                                            priority: priority, purpose: .systemDefault)
    #expect(selection == .selected(.builtInMic()))
}

@Test
func aDeviceThatIsPresentButNotAliveIsNotSelected() {
    // Presence is not availability. A device can stay in the OS's list after it has stopped working.
    let priority = MicrophonePriority(order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
    var deadUSB = AudioInputDevice.usbMic()
    deadUSB.isAlive = .no
    let selection = MicrophonePolicy.select(from: devices(deadUSB, .builtInMic()),
                                            priority: priority, purpose: .systemDefault)
    #expect(selection == .selected(.builtInMic()))
}

@Test
func anUnansweredLivenessQueryDoesNotDisqualifyADevice() {
    // The other half of the rule above: "I could not ask" is not "it is dead". Being pessimistic here
    // is how one broken property read turns into a Mac with no selectable microphone.
    let priority = MicrophonePriority(order: ["USBAudioDevice_UID", "BuiltInMicrophoneDevice"])
    var uncertainUSB = AudioInputDevice.usbMic()
    uncertainUSB.isAlive = .unknown
    let selection = MicrophonePolicy.select(from: devices(uncertainUSB, .builtInMic()),
                                            priority: priority, purpose: .systemDefault)
    #expect(selection == .selected(uncertainUSB))
}

@Test
func theOverrideOutranksTheWholeList() {
    let priority = MicrophonePriority(order: ["BuiltInMicrophoneDevice"], override: "00-00-5E-00-53-01:input")
    let selection = MicrophonePolicy.select(from: devices(.builtInMic(), .airPods()),
                                            priority: priority, purpose: .systemDefault)
    #expect(selection == .selected(.airPods()))
}

@Test
func anOverrideWhoseDeviceIsGoneSelectsNothingOfItsOwn() {
    // `Use now` on a headset that has since been put away: selection falls back to the list. Retiring
    // the stale override belongs to the reconciler — a pure function must not edit its own input.
    let priority = MicrophonePriority(order: ["BuiltInMicrophoneDevice"], override: "00-00-5E-00-53-01:input")
    let selection = MicrophonePolicy.select(from: devices(.builtInMic()),
                                            priority: priority, purpose: .systemDefault)
    #expect(selection == .selected(.builtInMic()))
}

@Test
func anEmptyListIsWaitingRatherThanBroken() {
    // Nothing configured is an ordinary state, and it must not read as "this machine has no
    // microphones" — the user is looking at one.
    let selection = MicrophonePolicy.select(from: devices(.builtInMic(), .airPods()),
                                            priority: .empty, purpose: .systemDefault)
    #expect(selection == .noPreferredDeviceAvailable)
}

@Test
func aListWhoseEveryEntryIsAbsentIsAlsoWaiting() {
    let priority = MicrophonePriority(order: ["USBAudioDevice_UID", "SomeOtherMic_UID"])
    let selection = MicrophonePolicy.select(from: devices(.builtInMic(), .airPods()),
                                            priority: priority, purpose: .systemDefault)
    #expect(selection == .noPreferredDeviceAvailable)
}

@Test
func aMachineWithNothingUsableIsADifferentAnswerEntirely() {
    var dead = AudioInputDevice.builtInMic()
    dead.isAlive = .no
    let priority = MicrophonePriority(order: ["BuiltInMicrophoneDevice"])
    #expect(MicrophonePolicy.select(from: devices(dead), priority: priority,
                                    purpose: .systemDefault) == .noEligibleDevice)
    #expect(MicrophonePolicy.select(from: [], priority: priority,
                                    purpose: .systemDefault) == .noEligibleDevice)
}

@Test
func theTwoPurposesDisagreeAboutTheSameDeviceOnPurpose() {
    // The Teams loopback driver measured `canBeDefaultDevice == 0` in the input scope. It must never be
    // made the system default — and whether ScreenCaptureKit could capture it is a *different*
    // question, so the capture purpose does not consult that property at all.
    let priority = MicrophonePriority(order: ["MSLoopbackDriverDevice_UID"])
    let loopback = AudioInputDevice.teamsLoopback()

    #expect(MicrophonePolicy.select(from: devices(loopback), priority: priority,
                                    purpose: .systemDefault) == .noEligibleDevice)
    #expect(MicrophonePolicy.select(from: devices(loopback), priority: priority,
                                    purpose: .capture) == .selected(loopback))
}

@Test
func aCandidateTheOSRefusedIsSteppedOverRatherThanRetriedForever() {
    // ⚠️ The trap this parameter exists for. An unanswered eligibility query counts as eligible, so the
    // policy will happily choose a device the OS then refuses to accept. Without excluding it for the
    // pass, the reconciler re-picks the same doomed candidate every time and never reaches the
    // known-good device below it — a livelock that looks exactly like a fight with another app.
    let priority = MicrophonePriority(order: ["MysteryDevice_UID", "BuiltInMicrophoneDevice"])
    let all = devices(.unknownEligibility(), .builtInMic())

    #expect(MicrophonePolicy.select(from: all, priority: priority,
                                    purpose: .systemDefault) == .selected(.unknownEligibility()))
    #expect(MicrophonePolicy.select(from: all, priority: priority, purpose: .systemDefault,
                                    refused: ["MysteryDevice_UID"]) == .selected(.builtInMic()))
}

@Test
func absenceFromAnIncompleteSnapshotIsNotADisconnect() {
    // ⚠️ Consumers act destructively on absence — an override expires, a recording fails over — so
    // concluding "gone" from a snapshot that admits it could not describe every device would turn one
    // unreadable driver into a lost recording.
    let present = devices(.builtInMic())
    #expect(MicrophonePolicy.presence(of: "BuiltInMicrophoneDevice", in: present,
                                      snapshotComplete: true) == .present)
    #expect(MicrophonePolicy.presence(of: "USBAudioDevice_UID", in: present,
                                      snapshotComplete: true) == .absent)
    #expect(MicrophonePolicy.presence(of: "USBAudioDevice_UID", in: present,
                                      snapshotComplete: false) == .unknown)
    // Even an incomplete snapshot proves *presence* when the device is in it.
    #expect(MicrophonePolicy.presence(of: "BuiltInMicrophoneDevice", in: present,
                                      snapshotComplete: false) == .present)
}
