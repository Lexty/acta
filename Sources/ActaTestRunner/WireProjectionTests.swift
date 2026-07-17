import ActaControlProtocol
import ActaKit
import ActaRuntime
import Foundation
import Testing

// The pure projection from the runtime's typed state into the wire types (Plan 1, Task 2). It has no
// I/O, no clock and no controller in reach, so every case is driven from literals — the same reason
// `ControlStateTests` can drive `ControlState(from:)` that way.

private func recording(_ name: String, manifest: SessionManifest? = nil) -> MeetingStore.Recording {
    MeetingStore.Recording(directory: URL(fileURLWithPath: "/tmp/Acta-test/\(name)", isDirectory: true),
                           manifest: manifest)
}

private let fixtureManifest = SessionManifest(status: .done,
                                              startedAt: Date(timeIntervalSince1970: 1_770_000_000),
                                              segmentSeconds: 30,
                                              segmentCount: 7,
                                              assemblyAttempts: 2)

// MARK: - Settings

@Test
func wireSettingsProjectionRoundTrips() {
    let settings = RecordingSettings(archivePath: "~/Acta-dev",
                                     segmentSeconds: 45,
                                     deleteSegmentsAfterAssembly: false)
    let wire = WireSettings(settings)
    #expect(wire.archivePath == "~/Acta-dev")
    #expect(wire.segmentSeconds == 45)
    #expect(wire.deleteSegmentsAfterAssembly == false)
    #expect(RecordingSettings(wire) == settings)
}

@Test
func wireSettingsProjectionDoesNotNormalise() {
    // Out of range on purpose: clamping is `saveSettings()`'s job, exactly as it is for the menu's
    // slider. A projection that silently clamped would make `settings_get` disagree with what
    // `settings_set` was told, with nothing in between having saved.
    let wire = WireSettings(archivePath: "", segmentSeconds: 9_999, deleteSegmentsAfterAssembly: true)
    #expect(RecordingSettings(wire).segmentSeconds == 9_999)
    #expect(RecordingSettings(wire).normalized().segmentSeconds == RecordingSettings.maxSegmentSeconds)
}

// MARK: - RecordingSummary

@Test
func recordingSummaryCarriesEveryManifestField() {
    let summary = RecordingSummary(recording("2026-07-17_1430__weekly-sync", manifest: fixtureManifest))
    #expect(summary.directoryName == "2026-07-17_1430__weekly-sync")
    #expect(summary.path == "/tmp/Acta-test/2026-07-17_1430__weekly-sync")
    #expect(summary.status == .done)
    #expect(summary.startedAt == fixtureManifest.startedAt)
    #expect(summary.segmentSeconds == 30)
    #expect(summary.segmentCount == 7)
    #expect(summary.assemblyAttempts == 2)
}

@Test
func recordingSummaryMintsTheIDThroughTheSharedHelper() {
    let summary = RecordingSummary(recording("2026-07-17_1430__weekly-sync", manifest: fixtureManifest))
    #expect(summary.id == RecordingID.make(directoryName: "2026-07-17_1430__weekly-sync"))
    // The two halves of the one home agree: what the projection mints, the lookup resolves.
    #expect(RecordingID.directoryName(fromID: summary.id) == summary.directoryName)
}

@Test
func recordingSummarySurvivesAMissingManifest() {
    // The load-bearing case: `MeetingStore.Recording.manifest` is optional, and a folder whose
    // `session.json` is gone is still a recording an agent may want to reveal.
    let summary = RecordingSummary(recording("2026-07-17_1430__weekly-sync"))
    #expect(summary.id == RecordingID.make(directoryName: "2026-07-17_1430__weekly-sync"))
    #expect(summary.directoryName == "2026-07-17_1430__weekly-sync")
    #expect(summary.path == "/tmp/Acta-test/2026-07-17_1430__weekly-sync")
    #expect(summary.status == .unknown)
    #expect(summary.startedAt == nil)
    #expect(summary.segmentSeconds == nil)
    #expect(summary.segmentCount == nil)
    #expect(summary.assemblyAttempts == nil)
}

@Test
func recordingSummaryOmitsTheManifestFieldsRatherThanNullingThem() throws {
    let json = String(data: try ControlProtocolCodec.encode(
        RecordingSummary(recording("2026-07-17_1430__weekly-sync"))), encoding: .utf8)!
    #expect(!json.contains("started_at"))
    #expect(!json.contains("segment_count"))
    #expect(!json.contains("null"))
    #expect(json.contains("\"status\":\"unknown\""))
}

@Test(arguments: [(SessionManifest.Status.recording, RecordingSummary.Status.recording),
                  (.done, .done),
                  (.recovered, .recovered)])
func recordingSummaryProjectsEveryManifestStatus(manifest: SessionManifest.Status,
                                                 wire: RecordingSummary.Status) {
    var m = fixtureManifest
    m.status = manifest
    #expect(RecordingSummary(recording("folder", manifest: m)).status == wire)
}

// MARK: - The id → recording lookup

@Test
func lookupResolvesAMintedID() {
    let recordings = [recording("a"), recording("b"), recording("c")]
    let id = RecordingID.make(directoryName: "b")
    #expect(ControlRecordingLookup.recording(forID: id, in: recordings)?.directory.lastPathComponent == "b")
}

@Test
func lookupRejectsAnIDThatMatchesNoCurrentRecording() {
    // A well-formed id for a folder that is not in the listing — a recording deleted since the client
    // last read it. Not a trap and not a wrong folder: `nil`, which the dispatcher answers as
    // `unknown_recording`.
    let id = RecordingID.make(directoryName: "gone")
    #expect(ControlRecordingLookup.recording(forID: id, in: [recording("a")]) == nil)
}

@Test(arguments: ["", "not-an-id", "v1:!!!not-base64!!!", "v2:YQ", "YQ"])
func lookupRejectsAMalformedID(id: String) {
    #expect(ControlRecordingLookup.recording(forID: id, in: [recording("a")]) == nil)
}

// MARK: - WireControlState

@available(macOS 15.0, *)
@Test
func wireStateProjectsEveryOperation() {
    #expect(WireControlState(state: ControlState(operation: .idle)).operation.kind == .idle)
    #expect(WireControlState(state: ControlState(operation: .starting)).operation.kind == .starting)
    #expect(WireControlState(state: ControlState(operation: .saving)).operation.kind == .saving)

    let recordingState = WireControlState(state: ControlState(operation: .recording(elapsedSeconds: 42)))
    #expect(recordingState.operation.kind == .recording)
    #expect(recordingState.operation.elapsedSeconds == 42)
}

@available(macOS 15.0, *)
@Test(arguments: [ControlState.Operation.idle, .starting, .saving])
func wireStateCarriesElapsedSecondsOnlyWhileRecording(operation: ControlState.Operation) {
    // A zero here would read as "recording, 0s" in every other state; the field is optional so the
    // absence is the answer.
    #expect(WireControlState(state: ControlState(operation: operation)).operation.elapsedSeconds == nil)
}

@available(macOS 15.0, *)
@Test
func wireStateCarriesTheScalarFieldsAndTheGuards() {
    let state = ControlState(operation: .recording(elapsedSeconds: 1),
                             title: "Weekly sync",
                             suggestedTitle: "Meeting",
                             settings: RecordingSettings(archivePath: "~/Acta-dev",
                                                         segmentSeconds: 20,
                                                         deleteSegmentsAfterAssembly: false),
                             recordings: [recording("a", manifest: fixtureManifest), recording("b")])
    let wire = WireControlState(state: state)
    #expect(wire.title == "Weekly sync")
    #expect(wire.suggestedTitle == "Meeting")
    #expect(wire.settings == WireSettings(state.settings))
    #expect(wire.recordings.map(\.directoryName) == ["a", "b"])
    // The controller's own guards, carried rather than left for a client to re-derive.
    #expect(wire.canStart == false)
    #expect(wire.canStop == true)
    #expect(wire.canStart == state.canStart)
    #expect(wire.canStop == state.canStop)
}

@available(macOS 15.0, *)
@Test
func wireStateLeavesEveryBannerNilWhenThereIsNone() {
    let wire = WireControlState(state: ControlState())
    #expect(wire.lifecycleFailure == nil)
    #expect(wire.notice == nil)
    #expect(wire.recoveryNotice == nil)
}

/// Every `ControlFailure.Category` and the stable code it must project to. Written out rather than
/// derived: a table that computed the expectation the way the projection does would assert only that
/// the projection agrees with itself.
@available(macOS 15.0, *)
private let failureCodes: [(ControlFailure.Category, String)] = [
    (.startup(.noScreenRecordingPermission), "startup_no_screen_recording_permission"),
    (.startup(.noMicrophonePermission), "startup_no_microphone_permission"),
    (.startup(.streamNotStarted), "startup_stream_not_started"),
    (.startup(.diskWriteFailed), "startup_disk_write_failed"),
    (.startup(.noData), "startup_no_data"),
    (.startFailed, "start_failed"),
    (.assemblyFailed(ffmpegMissing: false), "assembly_failed"),
    (.assemblyFailed(ffmpegMissing: true), "assembly_failed_ffmpeg_missing"),
    (.unknown, "unknown_failure")
]

@available(macOS 15.0, *)
@Test
func wireStateProjectsEveryFailureCategoryOntoItsFrozenCode() {
    for (category, code) in failureCodes {
        let failure = ControlFailure(category: category, displayMessage: "prose the client never parses")
        let wire = WireControlState(state: ControlState(operation: .idle, lifecycleFailure: failure))
        #expect(wire.lifecycleFailure?.code == code)
        // The message is the controller's own string, byte for byte — the code is what a client branches
        // on, the message is what a human reads.
        #expect(wire.lifecycleFailure?.message == "prose the client never parses")
    }
}

@available(macOS 15.0, *)
@Test
func wireStateProjectsTheStartupFailureOfEveryCase() {
    // `StartupFailure` is `CaseIterable`, so a new case added to the closed set fails here rather than
    // reaching a client as a code nobody minted.
    for failure in StartupFailure.allCases {
        let state = ControlState(lifecycleFailure: ControlFailure(category: .startup(failure),
                                                                  displayMessage: failure.userMessage))
        let code = WireControlState(state: state).lifecycleFailure?.code
        #expect(code != nil)
        #expect(failureCodes.contains { $0.1 == code })
    }
}

@available(macOS 15.0, *)
@Test
func wireStateProjectsTheNoticeAndTheRecoveryNotice() {
    let state = ControlState(operation: .idle,
                             notice: Notice(category: .archiveOpenFailed, displayMessage: "no archive"),
                             recoveryNotice: RecoveryNotice(message: "Recovered 2 recordings."))
    let wire = WireControlState(state: state)
    #expect(wire.notice == WireControlState.Message(code: "archive_open_failed", message: "no archive"))
    #expect(wire.recoveryNotice == WireControlState.Message(code: "recovery_completed",
                                                            message: "Recovered 2 recordings."))
    // Independent of each other, exactly as on `ControlState`: an error can never crowd out the banner.
    #expect(wire.lifecycleFailure == nil)
}

@available(macOS 15.0, *)
@Test
func wireStateSurvivesAJSONRoundTrip() throws {
    let state = ControlState(operation: .recording(elapsedSeconds: 12),
                             lifecycleFailure: ControlFailure(category: .assemblyFailed(ffmpegMissing: true),
                                                              displayMessage: "ffmpeg is not installed"),
                             recoveryNotice: RecoveryNotice(message: "Recovered 1 recording."),
                             title: "Weekly sync",
                             suggestedTitle: "Meeting",
                             settings: .default,
                             recordings: [recording("a", manifest: fixtureManifest), recording("b")])
    let wire = WireControlState(state: state)
    let data = try ControlProtocolCodec.encode(wire)
    #expect(try ControlProtocolCodec.decode(WireControlState.self, from: data) == wire)
}
