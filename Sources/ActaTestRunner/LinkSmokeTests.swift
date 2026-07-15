import Foundation
import Testing
import ActaKit
import ActaRuntime

// The link proof for Task 11. Until `ActaRuntime` was extracted, the whole pipeline lived in the
// `Acta` executable target, and SwiftPM cannot import an executable — so none of the types below
// could be named from a test at all, let alone constructed. That is why every criterion that
// mattered in Tasks 2-10 had to be closed as "manual test (skipped - not automatable)".
//
// This is deliberately NOT an end-to-end test and must not be mistaken for one: it constructs the
// top-level entry points and asserts on what construction alone establishes. Nothing starts capture
// (that needs TCC, a display and a live audio session), and no fake, seam or harness appears here —
// those are the backlog's job, and they are easier to design now that the code is importable.

/// A temporary directory for the types whose `init` touches the FS — `AudioRecorder` creates its
/// `system/`/`mic/` segment directories eagerly, so it cannot be pointed at a path we do not own.
private func withTemporaryDirectory(_ body: (URL) throws -> Void) rethrows {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acta-link-smoke-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}

@Test
@available(macOS 15.0, *)
func recordingSessionIsReachableFromTests() {
    withTemporaryDirectory { directory in
        let session = RecordingSession(directory: directory,
                                       settings: RecordingSettings.default)
        #expect(session.directory == directory)
    }
}

@Test
@available(macOS 15.0, *)
func audioRecorderIsReachableFromTests() {
    withTemporaryDirectory { directory in
        let recorder = AudioRecorder(directory: directory, segmentSeconds: 15)
        // Constructed but never started: no stream, no buffers, no segments yet.
        #expect(!recorder.isStreaming)
        #expect(recorder.receivedBufferCounts == (system: 0, mic: 0))
        #expect(recorder.finalizedSegmentCount == 0)
        // The writers create their track directories eagerly — the one observable thing `init` does.
        let system = directory.appendingPathComponent(SegmentLayout.systemDirName)
        let mic = directory.appendingPathComponent(SegmentLayout.micDirName)
        #expect(FileManager.default.fileExists(atPath: system.path))
        #expect(FileManager.default.fileExists(atPath: mic.path))
        #expect(recorder.segmentBytesOnDisk == 0)
    }
}

@Test
func recoveryManagerIsReachableFromTests() {
    withTemporaryDirectory { directory in
        let manager = RecoveryManager(archiveRoot: directory,
                                      tracks: RecordingSettings.default.trackSelection)
        #expect(manager.archiveRoot == directory)
        // An empty archive: nothing to recover, and scanning it must not throw.
        #expect(manager.recoverInterruptedSessions().isEmpty)
    }
}

@Test
@MainActor
@available(macOS 15.0, *)
func recordingControllerIsReachableFromTests() {
    // A fresh `UserDefaults` suite rather than `.standard`: the runner must not read or write the
    // real app's saved settings.
    let suite = "dev.personal.acta.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let controller = RecordingController(settingsStore: SettingsStore(defaults: defaults))
    #expect(controller.phase == .idle)
    #expect(!controller.isRecording)
    #expect(!controller.isBusy)
    #expect(!controller.hasWorkInFlight)
    #expect(controller.errorMessage.isEmpty)
    #expect(controller.recoveredBanner.isEmpty)
    #expect(controller.elapsedString == "00:00:00")
    #expect(controller.settings == RecordingSettings.default)
}

@Test
func meetingStoreIsReachableFromTests() {
    withTemporaryDirectory { directory in
        let store = MeetingStore(archiveRoot: directory)
        #expect(store.archiveRoot == directory)
        #expect(store.listRecordings().isEmpty)
    }
}
