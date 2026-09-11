import ActaControlProtocol
import ActaKit
import ActaRuntime
import Foundation
import Testing

// The socket-confinement policy on `ControlDispatcher` (Plan 2, Task 2): a `.socket` dispatcher refuses
// to relocate the archive and rejects illegal wire strings, while a `.trusted` (UI) dispatcher does
// neither. Driven over the same `FakeControlServing` the other dispatcher suites use — no socket needed
// to prove the policy.

// MARK: - The archive-path substitution

@MainActor
@available(macOS 15.0, *)
@Test
func aSocketSettingsSetIgnoresTheWireArchivePathAndKeepsTheCurrentOne() async {
    let (dispatcher, fake) = makeSocketDispatcher()
    fake.settings = RecordingSettings(archivePath: "/Users/me/Acta",
                                      segmentSeconds: 30,
                                      deleteSegmentsAfterAssembly: true)

    let wire = WireSettings(archivePath: "/etc/somewhere-else",
                            segmentSeconds: 15,
                            deleteSegmentsAfterAssembly: false,
                            microphonePriority: [],
                            managesSystemDefaultInput: false,
                            captureMicrophoneChoice: .systemDefault)
    #expect(await dispatcher.handle(.settingsSet(wire)).result == .ok)

    // The wire path is dropped; the authoritative path stays. The other two fields are applied.
    #expect(fake.settings.archivePath == "/Users/me/Acta")
    #expect(fake.settings.segmentSeconds == 15)
    #expect(fake.settings.deleteSegmentsAfterAssembly == false)
}

@MainActor
@available(macOS 15.0, *)
@Test
func aTrustedSettingsSetWritesTheWireArchivePathThrough() async {
    let (dispatcher, fake) = makeDispatcher()   // .trusted by default
    let wire = WireSettings(archivePath: "/Users/me/Elsewhere",
                            segmentSeconds: 15,
                            deleteSegmentsAfterAssembly: false,
                            microphonePriority: [],
                            managesSystemDefaultInput: false,
                            captureMicrophoneChoice: .systemDefault)
    #expect(await dispatcher.handle(.settingsSet(wire)).result == .ok)
    // In-process, a human relocating their own archive is fine — the whole wire value is written.
    #expect(fake.settings == RecordingSettings(wire))
}

// MARK: - Wire-string validation

@MainActor
@available(macOS 15.0, *)
@Test
func aSocketRejectsAnOverLongTitleWithoutTouchingTheRecorder() async {
    let (dispatcher, fake) = makeSocketDispatcher(ControlState(operation: .idle))
    let tooLong = String(repeating: "a", count: ControlStringPolicy.maxLength + 1)

    let response = await dispatcher.handle(.start(title: tooLong))
    #expect(response.wireError?.code == "bad_request")
    // The recorder is never touched: the string is rejected before dispatch.
    #expect(!fake.calls.contains("start"))
}

@MainActor
@available(macOS 15.0, *)
@Test(arguments: ["line\nbreak", "nul\u{0}byte", "bell\u{7}"])
func aSocketRejectsAControlCharacterTitle(title: String) async {
    let (dispatcher, fake) = makeSocketDispatcher()
    let response = await dispatcher.handle(.titleSet(title))
    #expect(response.wireError?.code == "bad_request")
    #expect(!fake.calls.contains("title.set"))
}

@MainActor
@available(macOS 15.0, *)
@Test
func aSocketAcceptsAWellFormedTitle() async {
    let (dispatcher, fake) = makeSocketDispatcher(ControlState(operation: .idle))
    #expect(await dispatcher.handle(.titleSet("Weekly sync")).result == .ok)
    #expect(fake.titleWithoutRecording == "Weekly sync")
}

@MainActor
@available(macOS 15.0, *)
@Test
func aTrustedDispatcherAcceptsALongTitle() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .idle))
    // The UI is never adversarial: a long title is not validated, it is forwarded.
    let long = String(repeating: "a", count: ControlStringPolicy.maxLength + 100)
    #expect(await dispatcher.handle(.titleSet(long)).result == .ok)
    #expect(fake.titleWithoutRecording == long)
}

// MARK: - The microphone authority, which only the socket made caller-supplied

// ⚠️ **This is where the two branches met.** The priority list and the management flag arrived with the
// microphone feature, the untrusted caller arrived with the socket, and neither branch could have a test
// for the other's half. Between them they decide whether Acta writes the **Mac's** system-wide default
// input and which device it writes — so they are substituted on the socket path exactly as the archive
// path is, and for a stronger reason than the archive path has.

@MainActor
@available(macOS 15.0, *)
@Test
func aSocketSettingsSetCannotRewriteTheMicrophonePriorityList() async {
    let (dispatcher, fake) = makeSocketDispatcher()
    fake.settings = RecordingSettings(archivePath: "/Users/me/Acta",
                                      segmentSeconds: 30,
                                      deleteSegmentsAfterAssembly: true,
                                      microphonePriority: ["BuiltInMicrophoneDevice"],
                                      managesSystemDefaultInput: true,
                                      captureMicrophoneChoice: .followPriority)

    let wire = wireSettings(microphonePriority: ["AttackerChosenDevice", "AnotherOne"],
                            managesSystemDefaultInput: false,
                            captureMicrophoneChoice: .systemDefault)
    #expect(await dispatcher.handle(.settingsSet(wire)).result == .ok)

    // The two authority fields keep their authoritative values...
    #expect(fake.settings.microphonePriority == ["BuiltInMicrophoneDevice"])
    #expect(fake.settings.managesSystemDefaultInput == true)
    // ...while the field that governs only Acta's own recording comes from the wire, as do the rest.
    #expect(fake.settings.captureMicrophoneChoice == .systemDefault)
    #expect(fake.settings.segmentSeconds == 15)
}

@MainActor
@available(macOS 15.0, *)
@Test
func aSocketCannotPlantAPriorityListForLaterEnablement() async {
    // ⚠️ The converse of the test above, and the reason **both** fields are substituted rather than the
    // enable flag alone: with enforcement off, a caller that could write the list would be leaving one
    // to take effect the moment the user switches management on in the menu.
    let (dispatcher, fake) = makeSocketDispatcher()
    fake.settings = RecordingSettings(archivePath: "/Users/me/Acta",
                                      segmentSeconds: 30,
                                      deleteSegmentsAfterAssembly: true,
                                      microphonePriority: [],
                                      managesSystemDefaultInput: false)

    let wire = wireSettings(microphonePriority: ["AttackerChosenDevice"],
                            managesSystemDefaultInput: false,
                            captureMicrophoneChoice: .followPriority)
    #expect(await dispatcher.handle(.settingsSet(wire)).result == .ok)
    #expect(fake.settings.microphonePriority.isEmpty)
}

@MainActor
@available(macOS 15.0, *)
@Test
func aTrustedSettingsSetWritesTheMicrophoneFieldsThrough() async {
    // The menu is a person choosing their own microphones; nothing is substituted on that path, and a
    // check that discarded the fields everywhere would pass the two tests above.
    let (dispatcher, fake) = makeDispatcher()
    let wire = wireSettings(microphonePriority: ["Shure", "BuiltIn"],
                            managesSystemDefaultInput: true,
                            captureMicrophoneChoice: .followPriority)
    #expect(await dispatcher.handle(.settingsSet(wire)).result == .ok)
    #expect(fake.settings.microphonePriority == ["Shure", "BuiltIn"])
    #expect(fake.settings.managesSystemDefaultInput == true)
}

// MARK: - Helper

@MainActor
@available(macOS 15.0, *)
private func makeSocketDispatcher(_ state: ControlState = ControlState())
    -> (ControlDispatcher, FakeControlServing) {
    let fake = FakeControlServing()
    fake.currentState = state
    return (ControlDispatcher(service: fake, confinement: .socket), fake)
}

@available(macOS 15.0, *)
private func wireSettings(microphonePriority: [String],
                          managesSystemDefaultInput: Bool,
                          captureMicrophoneChoice: WireSettings.CaptureChoice) -> WireSettings {
    WireSettings(archivePath: "/Users/me/Acta",
                 segmentSeconds: 15,
                 deleteSegmentsAfterAssembly: true,
                 microphonePriority: microphonePriority,
                 managesSystemDefaultInput: managesSystemDefaultInput,
                 captureMicrophoneChoice: captureMicrophoneChoice)
}

// MARK: - The microphone application barrier

// ⚠️ **The second place the two branches met, and this one is a race rather than a policy.** Settings
// reach the microphone owner asynchronously: `saveSettings()` chains the application and returns, and the
// capture policy is published several suspension points later. In-process that never mattered — the menu
// writes the settings and the same person clicks Start seconds afterwards. A socket client receives `ok`
// and can send `start` in the very next frame, so the acknowledgement has to mean *applied*.
//
// Both tests park the barrier deliberately: proving the dispatcher waits requires holding it open, not
// hoping the scheduler is slow.

@MainActor
@available(macOS 15.0, *)
@Test
func aSettingsSaveIsNotAcknowledgedUntilItsMicrophoneApplicationLands() async {
    let (dispatcher, fake) = makeSocketDispatcher(ControlState(operation: .idle))
    fake.parksMicrophoneSettlement = true

    let reply = Task { await dispatcher.handle(.settingsSave) }
    await waitUntil("the save to park in the microphone barrier") { fake.parkedInSettlement == 1 }
    // Evidence the work was actually entered — "nothing happened" is also what deleting the call looks
    // like. The save itself has been issued; only the acknowledgement is being withheld.
    #expect(fake.calls.contains("saveSettings"))

    fake.releaseMicrophoneSettlement()
    #expect(await reply.value.result == .ok)
}

@MainActor
@available(macOS 15.0, *)
@Test
func aStartWaitsForAQueuedMicrophoneApplication() async {
    let (dispatcher, fake) = makeSocketDispatcher(ControlState(operation: .idle))
    fake.parksMicrophoneSettlement = true

    let reply = Task { await dispatcher.handle(.start(title: "Weekly sync")) }
    await waitUntil("the start to park in the microphone barrier") { fake.parkedInSettlement == 1 }
    // ⚠️ The assertion that matters: the recorder has **not** been touched. A start admitted here would
    // resolve its microphone under the policy the pending application is replacing.
    #expect(!fake.calls.contains("start"))

    fake.releaseMicrophoneSettlement()
    _ = await reply.value
    #expect(fake.calls.contains("start"))
}

@MainActor
@available(macOS 15.0, *)
@Test
func aTrustedDispatcherWaitsForTheSameBarrier() async {
    // ⚠️ Deliberately **not** confined to the socket. The menu cannot lose this race in practice, but the
    // barrier is a statement about what `ok` means, and making it a socket-only rule would leave the
    // in-process client with a weaker guarantee for no reason anyone could state.
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .idle))
    fake.parksMicrophoneSettlement = true

    let reply = Task { await dispatcher.handle(.start(title: nil)) }
    await waitUntil("the trusted start to park") { fake.parkedInSettlement == 1 }
    #expect(!fake.calls.contains("start"))
    fake.releaseMicrophoneSettlement()
    _ = await reply.value
    #expect(fake.calls.contains("start"))
}

@MainActor
@available(macOS 15.0, *)
@Test
func aStartCancelledWhileWaitingForTheBarrierIsRefused() async {
    // ⚠️ **The await moved the start behind the entry gate.** `handle` checks `Task.isCancelled` on
    // entry, which was the whole gate while nothing suspended before `start(title:)`. Joining an
    // unstructured task does not throw when the *waiter* is cancelled, so a start parked in the barrier
    // survives the quit that cancelled its connection and lands inside the finalisation window — the
    // exact failure the entry gate exists to prevent.
    let (dispatcher, fake) = makeSocketDispatcher(ControlState(operation: .idle))
    fake.parksMicrophoneSettlement = true

    let reply = Task { await dispatcher.handle(.start(title: "Weekly sync")) }
    await waitUntil("the start to park in the microphone barrier") { fake.parkedInSettlement == 1 }
    // Quit: the socket is torn down and every connection task cancelled, while this start is parked.
    reply.cancel()
    fake.releaseMicrophoneSettlement()

    #expect(await reply.value.wireError?.code == "command_rejected")
    #expect(!fake.calls.contains("start"), "a cancelled start must not reach the recorder")
    #expect(fake.titleWithoutRecording.isEmpty, "nor edit the title on its way past")
}
