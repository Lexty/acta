import ActaKit
import ActaRuntime
import Foundation
import Testing

/// `ReminderCoordinator` — the admission rules between a prompt and a recording.
///
/// ⚠️ **These belong in a test, not behind the panel's human-acceptance disclaimer.** The coordinator
/// lives in ActaRuntime with its service and reader injected; only the `NSPanel` drawing is manual. An
/// earlier commit message of mine claimed otherwise and Codex was right to correct it.
@Suite("Reminder coordinator")
@MainActor
struct ReminderCoordinatorTests {
    /// A reader whose snapshots are scripted.
    final class ScriptedReader: AudioProcessReading, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot = AudioProcessSnapshot(processes: [], isComplete: true)
        func set(_ next: AudioProcessSnapshot) { lock.lock(); snapshot = next; lock.unlock() }
        func readSnapshot() -> AudioProcessSnapshot {
            lock.lock(); defer { lock.unlock() }; return snapshot
        }
    }

    private static let slack = "com.tinyspeck.slackmacgap"

    private static func holding(_ bundle: String) -> AudioProcessSnapshot {
        AudioProcessSnapshot(processes: [AudioProcessObservation(pid: 501, bundleID: bundle,
                                                                 displayName: "Slack",
                                                                 processName: "Slack",
                                                                 isRunningInput: true)],
                             isComplete: true)
    }

    private static let quiet = AudioProcessSnapshot(processes: [], isComplete: true)

    /// Drive the coordinator to the point where a start offer is on screen.
    @available(macOS 15.0, *)
    private func offered(_ coordinator: ReminderCoordinator, _ reader: ScriptedReader) async -> UInt64? {
        reader.set(Self.quiet)
        coordinator.tick()                       // baseline
        reader.set(Self.holding(Self.slack))
        for _ in 0..<8 {
            coordinator.tick()
            if case .offerToRecord(let episodeID, _, _, _, _) = coordinator.prompt {
                return episodeID
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        return nil
    }

    @available(macOS 15.0, *)
    private func makeCoordinator() -> (ControllerHarness, ReminderCoordinator, ScriptedReader) {
        let harness = ControllerHarness(label: "reminders")
        let (_, _, _, manager) = makeTestMicrophoneManager(devices: [.builtInMic()],
                                                          defaultInput: "BuiltInMicrophoneDevice")
        manager.start()
        let api = ControlAPI(controller: harness.controller, microphone: manager)
        let reader = ScriptedReader()
        return (harness, ReminderCoordinator(service: api, reader: reader), reader)
    }

    @Test("an offer appears for an application that holds the input")
    @available(macOS 15.0, *)
    func anOfferIsRaised() async {
        let (harness, coordinator, reader) = makeCoordinator()
        defer { harness.tearDown() }
        let episodeID = await offered(coordinator, reader)
        #expect(episodeID != nil)
        if case .offerToRecord(_, let application, let bundleID, _, _) = coordinator.prompt {
            #expect(application == "Slack")
            #expect(bundleID == Self.slack)
        } else {
            Issue.record("no offer was raised")
        }
    }

    @Test("a quit already begun refuses a start and takes the prompt down")
    @available(macOS 15.0, *)
    func closingRefusesAStart() async {
        // ⚠️ The window the socket teardown exists to close: `applicationShouldTerminate` begins a
        // `.terminateLater` finalisation, and a prompt still on screen must not admit work into it.
        let (harness, coordinator, reader) = makeCoordinator()
        defer { harness.tearDown() }
        guard let episodeID = await offered(coordinator, reader) else {
            Issue.record("no offer to accept"); return
        }
        coordinator.beginClosing()
        #expect(coordinator.prompt == nil)
        coordinator.acceptStart(episodeID: episodeID)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(harness.controller.phase == .idle)
    }

    @Test("a quit that begins while the barrier is being awaited still refuses the start")
    @available(macOS 15.0, *)
    func closingDuringTheBarrierRefusesAStart() async {
        // ⚠️ **The gate that matters is the one after the await.** `acceptStart` waits on the same
        // microphone barrier a socket `start` waits on, and quit can begin inside that wait — which is
        // precisely the window `applicationShouldTerminate` exists to close. Clearing the prompt at
        // `beginClosing` is not enough on its own, because by then the click has already been accepted.
        let (harness, coordinator, reader) = makeCoordinator()
        defer { harness.tearDown() }
        guard let episodeID = await offered(coordinator, reader) else {
            Issue.record("no offer to accept"); return
        }
        coordinator.acceptStart(episodeID: episodeID)
        // Same turn, before the awaiting task resumes.
        coordinator.beginClosing()
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(harness.controller.phase == .idle)
    }

    @Test("a click carrying the wrong episode starts nothing")
    @available(macOS 15.0, *)
    func aMismatchedIdentityIsRefused() async {
        let (harness, coordinator, reader) = makeCoordinator()
        defer { harness.tearDown() }
        guard let episodeID = await offered(coordinator, reader) else {
            Issue.record("no offer to accept"); return
        }
        coordinator.acceptStart(episodeID: episodeID &+ 99)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(harness.controller.phase == .idle)
        // The real prompt is still standing: a stray click answered nothing and cancelled nothing.
        #expect(coordinator.prompt != nil)
    }

    @Test("an expiry for an old prompt does not dismiss the one that replaced it")
    @available(macOS 15.0, *)
    func dismissalIsIdentityScoped() async {
        let (harness, coordinator, reader) = makeCoordinator()
        defer { harness.tearDown() }
        guard let episodeID = await offered(coordinator, reader) else {
            Issue.record("no offer to accept"); return
        }
        let stale = ReminderPrompt.offerToRecord(episodeID: episodeID &+ 1, application: nil,
                                                 bundleID: nil, suggestedTitle: "x", microphone: "y")
        coordinator.dismiss(stale)
        #expect(coordinator.prompt != nil)
    }

    @Test("switching the reminder off takes its prompt down without acting")
    @available(macOS 15.0, *)
    func aPreferenceChangeDismissesWithoutActing() async {
        let (harness, coordinator, reader) = makeCoordinator()
        defer { harness.tearDown() }
        guard await offered(coordinator, reader) != nil else {
            Issue.record("no offer to accept"); return
        }
        var settings = harness.controller.settings
        settings.offersRecordingWhenMicrophoneBusy = false
        harness.controller.settings = settings
        harness.controller.saveSettings()

        coordinator.tick()
        #expect(coordinator.prompt == nil)
        #expect(harness.controller.phase == .idle)
    }
}
