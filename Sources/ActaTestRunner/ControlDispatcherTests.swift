import ActaControlProtocol
import ActaKit
import ActaRuntime
import Foundation
import Testing

// The `@MainActor` command dispatcher (Plan 1, Task 2), driven over a **fake `ControlServing`** — no
// socket, no controller, no TCC, no wall clock. That is the entire point of the narrow protocol: the
// policy that can be wrong (a busy `start`, honest immediate-vs-completion answers, `stopAndWait`'s
// ownership model, `watch`'s coalescing) is exercised here, before any descriptor code exists.
//
// Never `ControlAPI.shared`: it wraps `RecordingController.shared`, which reaches for the real `~/Acta`,
// real TCC and real time.

// MARK: - The read commands

@MainActor
@available(macOS 15.0, *)
@Test
func statusReturnsTheProjectedStateAndNeverRefreshes() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .recording(elapsedSeconds: 9),
                                                         title: "Weekly sync"))
    let response = await dispatcher.handle(.status)
    #expect(response.state?.operation.kind == .recording)
    #expect(response.state?.operation.elapsedSeconds == 9)
    #expect(response.state?.title == "Weekly sync")
    // A read that mutates is a read a client cannot poll.
    #expect(!fake.calls.contains("refresh"))
}

@MainActor
@available(macOS 15.0, *)
@Test
func listReturnsTheRecordingsAndNeverRefreshes() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(recordings: [fixtureRecording("a"), fixtureRecording("b")]))
    let response = await dispatcher.handle(.list)
    guard case .recordings(let summaries) = response.result else {
        Issue.record("expected a recordings result, got \(String(describing: response.result))")
        return
    }
    #expect(summaries.map(\.directoryName) == ["a", "b"])
    #expect(summaries.map(\.id) == [RecordingID.make(directoryName: "a"),
                                    RecordingID.make(directoryName: "b")])
    #expect(!fake.calls.contains("refresh"))
}

@MainActor
@available(macOS 15.0, *)
@Test
func settingsGetAndTitleGetReadThroughToTheService() async {
    let (dispatcher, fake) = makeDispatcher()
    fake.settings = RecordingSettings(archivePath: "~/Acta-dev",
                                      segmentSeconds: 20,
                                      deleteSegmentsAfterAssembly: false)
    fake.title = "Weekly sync"

    #expect(await dispatcher.handle(.settingsGet).result == .settings(WireSettings(fake.settings)))
    #expect(await dispatcher.handle(.titleGet).result == .title("Weekly sync"))
}

// MARK: - The write commands

@MainActor
@available(macOS 15.0, *)
@Test
func theVoidAcknowledgementsForwardAndReturnOK() async {
    let (dispatcher, fake) = makeDispatcher()
    #expect(await dispatcher.handle(.recover).result == .ok)
    #expect(await dispatcher.handle(.refresh).result == .ok)
    #expect(await dispatcher.handle(.openArchive).result == .ok)
    #expect(await dispatcher.handle(.settingsSave).result == .ok)
    #expect(await dispatcher.handle(.dismissRecoveryNotice).result == .ok)
    #expect(fake.calls.contains("recover"))
    #expect(fake.calls.contains("refresh"))
    #expect(fake.calls.contains("openArchive"))
    #expect(fake.calls.contains("saveSettings"))
    #expect(fake.calls.contains("dismissRecoveryNotice"))
}

@MainActor
@available(macOS 15.0, *)
@Test
func settingsSetWritesThroughWithoutSaving() async {
    let (dispatcher, fake) = makeDispatcher()
    let wire = WireSettings(archivePath: "~/Elsewhere",
                            segmentSeconds: 15,
                            deleteSegmentsAfterAssembly: false,
                                microphonePriority: ["BuiltInMicrophoneDevice"],
                                managesSystemDefaultInput: false,
                                captureMicrophoneChoice: .followPriority)
    #expect(await dispatcher.handle(.settingsSet(wire)).result == .ok)
    #expect(fake.settings == RecordingSettings(wire))
    // `settings_set` is the menu's binding, not its Save button: persisting is `settings_save`'s job.
    #expect(!fake.calls.contains("saveSettings"))
}

@MainActor
@available(macOS 15.0, *)
@Test
func titleSetWritesThrough() async {
    let (dispatcher, fake) = makeDispatcher()
    #expect(await dispatcher.handle(.titleSet("Weekly sync")).result == .ok)
    #expect(fake.titleWithoutRecording == "Weekly sync")
}

// MARK: - start

@MainActor
@available(macOS 15.0, *)
@Test
func startForwardsTheTitleAndAnswersWithTheStateAsItIsNow() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .idle))
    let response = await dispatcher.handle(.start(title: "Weekly sync"))
    #expect(fake.calls.contains("start"))
    #expect(fake.titleWithoutRecording == "Weekly sync")
    // ⚠️ "Accepted", not "capture started": the fake has not moved off `.idle`, and the answer says so
    // rather than claiming a recording that may not be live for another turn.
    #expect(response.state?.operation.kind == .idle)
}

@MainActor
@available(macOS 15.0, *)
@Test(arguments: [ControlState.Operation.starting,
                  .recording(elapsedSeconds: 3),
                  .saving])
func aBusyStartIsRejectedWithoutChangingTheTitle(operation: ControlState.Operation) async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: operation))
    fake.title = "Original"

    let response = await dispatcher.handle(.start(title: "Hijacked"))

    #expect(response.wireError == .commandRejected(reason: ControlDispatcher.Rejection.busy))
    #expect(response.wireError?.code == "command_rejected")
    // The whole reason the guard is here and not left to the controller: `ControlAPI.start(title:)`
    // sets the title *before* the controller's own guard no-ops the start, so a naive forward would
    // rename a live recording and answer as though nothing had happened.
    #expect(fake.titleWithoutRecording == "Original")
    #expect(!fake.calls.contains("start"))
}

// MARK: - A cancelled connection does not mutate the recorder

@MainActor
@available(macOS 15.0, *)
@Test
func aCancelledDispatchRefusesTheCommandBeforeTouchingTheRecorder() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .idle))

    // A `.start` whose delivering connection has been cancelled (an orderly quit cancels every
    // connection task) must not still begin a recording. The command reaches `handle` because Swift
    // cancellation is cooperative — the frame was already read — so the dispatcher's own cancellation
    // gate is the last thing between a torn-down connection and a recording begun during quit
    // finalisation. Deterministic: the child runs `handle` only once this test suspends at
    // `await task.value`, by which point `cancel()` has already marked it.
    let task = Task { @MainActor in await dispatcher.handle(.start(title: "Ghost")) }
    task.cancel()
    let response = await task.value

    #expect(response.wireError == .commandRejected(reason: ControlDispatcher.Rejection.closing))
    #expect(!fake.calls.contains("start"))
    #expect(fake.titleWithoutRecording.isEmpty)
}

// MARK: - stop

@MainActor
@available(macOS 15.0, *)
@Test
func stopInitiatesAndAnswersImmediately() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .recording(elapsedSeconds: 5)))
    let response = await dispatcher.handle(.stop)
    #expect(fake.calls.contains("stop"))
    // "Stop initiated", not "saved": the fake has not settled anything, and the answer reports what is
    // true right now.
    #expect(response.state?.operation.kind == .recording)
}

@MainActor
@available(macOS 15.0, *)
@Test
func stopWithNothingInFlightIsNotRecording() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .idle))
    let response = await dispatcher.handle(.stop)
    #expect(response.wireError?.code == "not_recording")
    #expect(!fake.calls.contains("stop"))
}

@MainActor
@available(macOS 15.0, *)
@Test(arguments: [(ControlState.Operation.starting, ControlDispatcher.Rejection.starting),
                  (.saving, ControlDispatcher.Rejection.saving)])
func stopWithWorkInFlightIsRefusedWithoutDenyingTheRecordingExists(
    operation: ControlState.Operation, reason: String
) async {
    // The controller stops only from `.recording`, so the command is still refused — but `not_recording`
    // would be a false statement here. `.starting` has capture already writing segments (the frozen
    // controller contract), and `.saving` means a stop already landed; telling a client "there is no
    // recording in progress" contradicts the state this same dispatcher projects and invites it to
    // abandon a recording that keeps running to disk.
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: operation))
    let response = await dispatcher.handle(.stop)
    #expect(response.wireError?.code == "command_rejected")
    #expect(response.wireError == .commandRejected(reason: reason))
    #expect(!fake.calls.contains("stop"))
}
