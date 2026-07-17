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
                            deleteSegmentsAfterAssembly: false)
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
                            deleteSegmentsAfterAssembly: false)
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

// MARK: - Helper

@MainActor
@available(macOS 15.0, *)
private func makeSocketDispatcher(_ state: ControlState = ControlState())
    -> (ControlDispatcher, FakeControlServing) {
    let fake = FakeControlServing()
    fake.currentState = state
    return (ControlDispatcher(service: fake, confinement: .socket), fake)
}
