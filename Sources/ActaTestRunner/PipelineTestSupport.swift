import ActaKit
import ActaRuntime
import Foundation

// Shared by `RecordingPipelineTests` and `RecordingPipelineFailureTests`: the settings, the
// dependency composition and the file-system readers every capture-backed scenario needs. They live
// here rather than in either suite because both drive the same pipeline and must describe it the
// same way — a second copy of `makeSettings` is how two suites quietly start testing two setups.

/// The wall-clock ceiling for a scenario that spends virtual seconds. The real code sleeps 2 s on
/// the startup probe alone, and the give-up path spends four of them — so a run anywhere near this
/// bound means the clock is not actually wired and the tests are waiting on real time.
let clockWiredWallClockBound = 1.5

/// Segment length for these tests: the shortest `RecordingSettings` allows. Combined with buffers a
/// second long, a couple of batches cross a boundary — which is the point.
let testSegmentSeconds = RecordingSettings.minSegmentSeconds

@available(macOS 15.0, *)
func makeSettings() -> RecordingSettings {
    RecordingSettings(archivePath: "", segmentSeconds: testSegmentSeconds,
                      deleteSegmentsAfterAssembly: false)
}

@available(macOS 15.0, *)
func makeDependencies(source: FakeCaptureSource,
                      permissions: FakePermissions,
                      clock: TestClock) -> RecordingDependencies {
    RecordingDependencies(makeSource: { source }, makePermissions: { permissions }, makeClock: { clock })
}

/// The session marker as it stands on disk.
func readSessionManifest(in directory: URL) throws -> SessionManifest {
    let data = try Data(contentsOf: directory.appendingPathComponent(SessionManifest.fileName))
    return try SessionManifest.decode(from: data)
}

/// The meeting folders sitting in an archive root — the subdirectories, and nothing else.
func meetingFolders(in root: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.filter { name in
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path,
                                                    isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

/// The segment files of one track, in order.
func segmentFiles(in directory: URL, track: String) -> [URL] {
    let trackDir = directory.appendingPathComponent(track)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: trackDir.path)) ?? []
    return SegmentLayout.orderedSegments(fromFileNames: names)
        .map { trackDir.appendingPathComponent($0.fileName) }
}

/// What the watchdog told the session, thread-safely: `onStall` is called from the watchdog's task,
/// not the test's.
final class ReportedStalls: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [StartupFailure] = []

    func record(_ failure: StartupFailure) { lock.lock(); failures.append(failure); lock.unlock() }
    var reported: [StartupFailure] { lock.lock(); defer { lock.unlock() }; return failures }
    var count: Int { reported.count }
}
