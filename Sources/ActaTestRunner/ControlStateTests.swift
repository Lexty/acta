import ActaKit
import ActaRuntime
import Foundation
import Testing

// The `ControlAPI` façade's translation — `ControlState(from: ControllerSnapshot)` — over synthetic
// snapshots.
//
// This is where the un-inducible states are covered, and that is the whole reason the mapping is a
// pure function in the first place. A controller-level assembly failure, an `openArchive()` that
// fails, and an `openArchive()` overwriting a failure set while `phase == .error` cannot be produced
// through today's public surface (`RecordingControllerLifecycleTests` lists them as deliberately
// uncharacterized). Here they are three literals.
//
// No pipeline, no clock, no subprocess, no temp directory: if anything in this file ever needs one,
// the mapping has stopped being pure.

// The messages come from `ControllerMessage` — the type `RecordingController` itself writes from —
// never from a copy typed out here. A copy would assert only that this file agrees with itself: it
// would keep passing while a reworded controller message degraded to `.unknown` in production, which
// is exactly what it did before `ControllerMessage` existed.
@available(macOS 15.0, *)
private let assemblyFailedMessage = ControllerMessage.assemblyFailed.text

@available(macOS 15.0, *)
private let ffmpegMissingMessage = ControllerMessage.ffmpegMissing.text

@available(macOS 15.0, *)
private let startFailedMessage = ControllerMessage.startFailed(detail: "The folder could not be created.").text

// MARK: - The operation, and its precedence

@Test @available(macOS 15.0, *)
func idleSnapshotMapsToIdle() {
    let state = ControlState(from: ControllerSnapshot())
    #expect(state.operation == .idle)
    #expect(state.lifecycleFailure == nil)
    #expect(state.notice == nil)
    #expect(state.recoveryNotice == nil)
    #expect(state.canStart)
    #expect(!state.canStop)
    #expect(!state.hasWorkInFlight)
}

/// The startup window: capture may already be writing while `phase` is still `.idle`.
@Test @available(macOS 15.0, *)
func startingFromIdlePhaseMapsToStarting() {
    let state = ControlState(from: ControllerSnapshot(phase: .idle, isStarting: true))
    #expect(state.operation == .starting)
    #expect(state.hasWorkInFlight)
    #expect(!state.canStart)
    #expect(!state.canStop)
}

/// A retry after a failed start: `start()` sets `isStarting` and clears `errorMessage` but leaves
/// `phase == .error`. Reading the phase first would call a live start `.idle` — the precedence rule
/// exists for exactly this snapshot.
@Test @available(macOS 15.0, *)
func startingWinsOverAnErrorPhaseLeftByAFailedStart() {
    let state = ControlState(from: ControllerSnapshot(phase: .error, isStarting: true))
    #expect(state.operation == .starting)
    #expect(state.lifecycleFailure == nil)
}

@Test @available(macOS 15.0, *)
func recordingCarriesElapsedSeconds() {
    let state = ControlState(from: ControllerSnapshot(phase: .recording, elapsedSeconds: 42))
    #expect(state.operation == .recording(elapsedSeconds: 42))
    #expect(state.canStop)
    #expect(!state.canStart)
    #expect(state.hasWorkInFlight)
}

@Test @available(macOS 15.0, *)
func normalSavingMapsToSaving() {
    let state = ControlState(from: ControllerSnapshot(phase: .saving, isSaving: true))
    #expect(state.operation == .saving)
    #expect(state.lifecycleFailure == nil)
    #expect(state.hasWorkInFlight)
    #expect(!state.canStart)
    #expect(!state.canStop)
}

/// `isStarting` outranks a stop in flight too — the precedence is a total order, not two rules that
/// happen not to collide.
@Test @available(macOS 15.0, *)
func startingWinsOverSaving() {
    let state = ControlState(from: ControllerSnapshot(phase: .saving, isStarting: true, isSaving: true))
    #expect(state.operation == .starting)
}

// MARK: - The fatal stall: an error that is not an operation

/// The watchdog gave up mid-recording: `phase` is parked in `.error` while the assembly still runs.
/// The state must say `.saving` **and** carry the failure — that orthogonality is the point of the type.
@Test @available(macOS 15.0, *)
func fatalStallReadsSavingWhileCarryingItsFailure() {
    let state = ControlState(from: ControllerSnapshot(phase: .error, isSaving: true,
                                                      errorMessage: StartupFailure.noData.userMessage))
    #expect(state.operation == .saving)
    #expect(state.lifecycleFailure?.category == .startup(.noData))
    #expect(state.lifecycleFailure?.displayMessage == StartupFailure.noData.userMessage)
    #expect(state.hasWorkInFlight)
}

/// The same stall once the assembly settles: `isSaving` drops, `phase` and `errorMessage` do not.
/// Leaving `.saving` is not clearing the failure.
@Test @available(macOS 15.0, *)
func settledFatalStallLeavesSavingButKeepsTheFailure() {
    let state = ControlState(from: ControllerSnapshot(phase: .error, isSaving: false,
                                                      errorMessage: StartupFailure.noData.userMessage))
    #expect(state.operation == .idle)
    #expect(state.lifecycleFailure?.category == .startup(.noData))
    #expect(state.lifecycleFailure?.displayMessage == StartupFailure.noData.userMessage)
    #expect(!state.hasWorkInFlight)
    // A settled failure is not work: the next start is allowed, exactly as the controller allows it.
    #expect(state.canStart)
}

// MARK: - The reverse lookup over the one untyped `errorMessage`

/// A failed start, per `StartupFailure`. The whole closed set, so a case added to the enum without a
/// thought for the lookup shows up here rather than in production as `.unknown`.
@Test(arguments: StartupFailure.allCases) @available(macOS 15.0, *)
func failedStartClassifiesEveryKnownStartupFailure(_ failure: StartupFailure) {
    let state = ControlState(from: ControllerSnapshot(phase: .error, errorMessage: failure.userMessage))
    #expect(state.operation == .idle)
    #expect(state.lifecycleFailure?.category == .startup(failure))
    // Byte-identical: the migrated UI must render exactly the string it renders today.
    #expect(state.lifecycleFailure?.displayMessage == failure.userMessage)
    #expect(state.notice == nil)
}

/// The generic start error — a start that threw something that was not a `StartupFailure`. The tail
/// interpolates `error.localizedDescription`, hence a prefix match.
@Test @available(macOS 15.0, *)
func genericStartErrorClassifiesAsStartFailed() {
    let state = ControlState(from: ControllerSnapshot(phase: .error, errorMessage: startFailedMessage))
    #expect(state.operation == .idle)
    #expect(state.lifecycleFailure?.category == .startFailed)
    #expect(state.lifecycleFailure?.displayMessage == startFailedMessage)
}

/// The assembly failed with no `ffmpeg` on the machine. Un-inducible in-process — the controller-level
/// assembly failure needs a seam no plan has added yet.
@Test @available(macOS 15.0, *)
func ffmpegMissingClassifiesAsAssemblyFailed() {
    let state = ControlState(from: ControllerSnapshot(phase: .error, errorMessage: ffmpegMissingMessage))
    #expect(state.operation == .idle)
    #expect(state.lifecycleFailure?.category == .assemblyFailed(ffmpegMissing: true))
    #expect(state.lifecycleFailure?.displayMessage == ffmpegMissingMessage)
}

/// The other assembly branch: `ffmpeg` is there and the concat failed anyway. A different category,
/// because the two are worded differently and promise different things about recovery.
@Test @available(macOS 15.0, *)
func assemblyFailureClassifiesAsAssemblyFailed() {
    let state = ControlState(from: ControllerSnapshot(phase: .error, errorMessage: assemblyFailedMessage))
    #expect(state.lifecycleFailure?.category == .assemblyFailed(ffmpegMissing: false))
    #expect(state.lifecycleFailure?.displayMessage == assemblyFailedMessage)
}

/// A string the lookup has never seen. `.unknown` rather than a guess — and the message still reaches
/// the user verbatim, which is what the classification is allowed to be wrong about and the display is not.
@Test @available(macOS 15.0, *)
func unrecognisedMessageIsAFailureOfUnknownCategory() {
    let state = ControlState(from: ControllerSnapshot(phase: .error, errorMessage: "Something new went wrong."))
    #expect(state.lifecycleFailure?.category == .unknown)
    #expect(state.lifecycleFailure?.displayMessage == "Something new went wrong.")
    #expect(state.notice == nil)
}

/// The closed set, swept: **every** message production can write is classified as something, and never
/// as `.unknown`. This is the test that fails when a new `ControllerMessage` case is added and
/// `category(of:)` is not taught about it — without it, the new message degrades to `.unknown` in
/// production while `displayMessage` keeps working, so nothing user-visible breaks and no other test
/// notices. `.archiveOpenFailed` is a notice rather than a failure, hence the two branches.
@Test(arguments: ControllerMessage.allMessages) @available(macOS 15.0, *)
func everyProductionMessageIsClassified(_ message: ControllerMessage) {
    let state = ControlState(from: ControllerSnapshot(phase: .error, errorMessage: message.text))
    // ⚠️ The notice-routed messages are the ones where **nothing about the recording has failed**:
    // the archive would not open, or the microphone changed under a recording that is still capturing.
    // Routing any of them to `lifecycleFailure` would park `phase` in `.error` and no-op `stop()`.
    let noticeCategories: [Notice.Category?] = {
        switch message {
        case .archiveOpenFailed: return [.archiveOpenFailed]
        case .microphoneSwitched: return [.microphoneSwitched]
        case .microphoneSwitchFailed: return [.microphoneSwitchFailed]
        default: return []
        }
    }()
    if let expected = noticeCategories.first {
        #expect(state.notice?.category == expected)
        #expect(state.lifecycleFailure == nil)
    } else {
        #expect(state.lifecycleFailure?.category != .unknown,
                "\(message) is not recognised by the reverse lookup")
        #expect(state.notice == nil)
    }
}

// MARK: - The notice, and the last-write rule it proves

/// `openArchive()` failing mid-recording: a notice, and the operation is untouched. The controller
/// deliberately never moves `phase` here, and neither may the mapping.
@Test @available(macOS 15.0, *)
func archiveOpenFailureIsANoticeAndLeavesTheOperationAlone() {
    let message = ControllerMessage.archiveOpenFailed(detail: "The folder does not exist.").text
    let state = ControlState(from: ControllerSnapshot(phase: .recording, errorMessage: message,
                                                      elapsedSeconds: 7))
    #expect(state.operation == .recording(elapsedSeconds: 7))
    #expect(state.notice?.category == .archiveOpenFailed)
    #expect(state.notice?.displayMessage == message)
    #expect(state.lifecycleFailure == nil)
}

/// ⚠️ The lossy rule, stated as a test: `openArchive()` overwrote a lifecycle failure that was set
/// while `phase == .error`, so the snapshot holds the archive prefix **on an error phase**. The prefix
/// wins over the phase — a notice, no lifecycle failure — because the earlier message is genuinely gone
/// from the controller and classifying by phase would attach the Finder message to the recording.
@Test @available(macOS 15.0, *)
func archivePrefixWinsOverAnErrorPhase() {
    let message = ControllerMessage.archiveOpenFailed(detail: "Permission denied.").text
    let state = ControlState(from: ControllerSnapshot(phase: .error, errorMessage: message))
    #expect(state.notice?.category == .archiveOpenFailed)
    #expect(state.notice?.displayMessage == message)
    #expect(state.lifecycleFailure == nil)
    #expect(state.operation == .idle)
}

// MARK: - The recovery banner, which is a separate field and stays one

@Test @available(macOS 15.0, *)
func recoveryNoticeMapsFromItsOwnField() {
    let state = ControlState(from: ControllerSnapshot(recoveredBanner: "Recovered 1 recording."))
    #expect(state.recoveryNotice == RecoveryNotice(message: "Recovered 1 recording."))
    #expect(state.lifecycleFailure == nil)
    #expect(state.notice == nil)
    #expect(state.operation == .idle)
}

/// Independent of a failure — `recoveredBanner` is a field of its own, so unlike the notice/failure
/// pair it can never be crowded out.
@Test @available(macOS 15.0, *)
func recoveryNoticeCoexistsWithALifecycleFailure() {
    let state = ControlState(from: ControllerSnapshot(phase: .error,
                                                      errorMessage: StartupFailure.streamNotStarted.userMessage,
                                                      recoveredBanner: "Recovered 2 recordings."))
    #expect(state.recoveryNotice == RecoveryNotice(message: "Recovered 2 recordings."))
    #expect(state.lifecycleFailure?.category == .startup(.streamNotStarted))
}

// MARK: - Pass-through fields

@Test @available(macOS 15.0, *)
func passThroughFieldsAreCarriedVerbatim() {
    let settings = RecordingSettings(archivePath: "/tmp/archive", segmentSeconds: 30,
                                     deleteSegmentsAfterAssembly: false)
    let recordings = [MeetingStore.Recording(directory: URL(fileURLWithPath: "/tmp/archive/m"), manifest: nil)]
    let state = ControlState(from: ControllerSnapshot(title: "Standup", suggestedTitle: "Meet — 10:00",
                                                      settings: settings, recordings: recordings))
    #expect(state.title == "Standup")
    #expect(state.suggestedTitle == "Meet — 10:00")
    #expect(state.settings == settings)
    #expect(state.recordings == recordings)
}
