import ActaKit
import ActaRuntime
import Combine
import Foundation

// Fixtures for the `RecordingController` characterization scenarios: a controller wired to the same
// fakes the pipeline tests use, a recorder for the state the UI renders, and the archive folders a
// launch finds on disk.
//
// They live here rather than inside either scenario file for the reason `PipelineTestSupport` gives:
// both suites drive the same controller and must describe it the same way, and a second copy of the
// wiring is how two suites quietly start characterizing two different objects.

// MARK: - The controller under characterization

/// A `RecordingController` against a temp archive, wired to the injected seams — never
/// `RecordingController.shared`, which would reach for the real `~/Acta`, real TCC and real time.
///
/// The fakes go into the *session's* dependencies through the factory; everything the controller
/// itself does around them — the guards, the phase orchestration, the failed-start cleanup — stays
/// the shipped code. That is what makes these scenarios a contract over the controller rather than
/// over a rehearsal of it.
@MainActor
@available(macOS 15.0, *)
final class ControllerHarness {
    /// The archive root the controller writes meetings into.
    let root: URL
    let source: FakeCaptureSource
    let permissions: FakePermissions
    let clock: TestClock
    let wakeLock: CountingWakeLock
    let controller: RecordingController

    private let suiteName: String
    private let defaults: UserDefaults

    /// - Parameter emitDuringProbe: whether the source delivers audio while the self-diagnosis is
    ///   watching. `true` is a start that succeeds; `false` is one the probe refuses, because a
    ///   source that comes up and never delivers is the "mute recording" the diagnosis exists to
    ///   catch. A scenario that needs its own `onSleep` (to sample the probe window, or to break
    ///   something inside it) overrides the handler — the last one set wins.
    init(label: String,
         permissions: FakePermissions = FakePermissions(),
         emitDuringProbe: Bool = true) {
        // Bound to locals first: the session factory below is a closure, and `self` cannot be
        // captured until every stored property is initialized — `controller` is the last of them.
        let source = FakeCaptureSource()
        let clock = TestClock()
        let wakeLock = CountingWakeLock()
        let root = makeTemporaryDirectory(label)
        self.source = source
        self.clock = clock
        self.wakeLock = wakeLock
        self.permissions = permissions
        self.root = root

        // An isolated defaults suite: the settings are real `SettingsStore` state, and writing them
        // into `.standard` would point the developer's own app at a temp archive.
        suiteName = "acta-controller-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.save(RecordingSettings(archivePath: root.path,
                                             segmentSeconds: testSegmentSeconds,
                                             deleteSegmentsAfterAssembly: false))

        if emitDuringProbe {
            // Every wait the self-diagnosis takes is a wait during which, in production, audio would
            // be arriving — so that is what the fake does here.
            clock.onSleep { _ in source.emitBatch() }
        }

        controller = RecordingController(settingsStore: settingsStore) { directory, settings in
            RecordingSession(directory: directory, settings: settings,
                             wakeLock: wakeLock.makeWakeLock(),
                             dependencies: makeDependencies(source: source,
                                                            permissions: permissions,
                                                            clock: clock))
        }
    }

    /// The meeting folder the controller created, if it created exactly one.
    var meetingDirectory: URL? {
        let folders = meetingFolders(in: root)
        guard folders.count == 1 else { return nil }
        return root.appendingPathComponent(folders[0], isDirectory: true)
    }

    /// Not a `deinit`: the archive and the defaults suite must be gone before the next scenario runs,
    /// and a `deinit` on a `@MainActor` type is not a point in the test's own timeline.
    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - The state the UI renders

/// The published state of a `RecordingController`, recorded as it changes.
///
/// Two mechanisms, because the controller exposes two kinds of state and only one of them is a
/// publisher:
///
/// - `phase` is `@Published`, so `$phase` carries **every** value it is ever set to. That is the
///   ordered sequence the scenarios assert on — sampling "after the await" would miss `.saving`,
///   which on a fixture-sized recording lasts milliseconds, and a contract that cannot see `.saving`
///   would not notice a refactor deleting it.
/// - `isBusy`/`isSaving`/`isRecording`/`hasWorkInFlight` are **computed properties, not
///   `@Published`** — there is no `$isBusy` to subscribe to, and `isStopping`, which two of them
///   read, is `@Published private`. So they are *sampled*: `objectWillChange` says something is
///   about to change, and the settled values are read on the next main-actor turn. A sample, not a
///   stream, and the scenarios are written knowing it.
@MainActor
@available(macOS 15.0, *)
final class ControllerStateLog {
    /// The public derivations, as the menu would render them at one instant.
    struct Snapshot: Equatable {
        var phase: RecordingController.Phase
        var isRecording: Bool
        var isSaving: Bool
        var isBusy: Bool
        var hasWorkInFlight: Bool
    }

    /// Every value `phase` took, in order, starting with the one in place at subscription.
    private(set) var phases: [RecordingController.Phase] = []
    /// The derived flags, sampled after each change and deduplicated: consecutive identical samples
    /// say nothing, and several changes can land in one main-actor turn.
    private(set) var snapshots: [Snapshot] = []

    private var cancellables: Set<AnyCancellable> = []

    init(_ controller: RecordingController) {
        record(controller)
        controller.$phase.sink { phase in
            // `@Published` publishes from the setter, and every one of the controller's setters runs
            // on the main actor — so this callback does too.
            MainActor.assumeIsolated { self.phases.append(phase) }
        }.store(in: &cancellables)

        controller.objectWillChange.sink { _ in
            MainActor.assumeIsolated {
                // `objectWillChange` fires *before* the change lands, so reading here would record
                // the state that is being replaced. The read is deferred by one main-actor turn,
                // which is where the settled value is. Typed explicitly: `Task`'s initializers are
                // ambiguous for a body this short.
                let deferred: Task<Void, Never> = Task { @MainActor in self.record(controller) }
                _ = deferred
            }
        }.store(in: &cancellables)
    }

    private func record(_ controller: RecordingController) {
        let snapshot = Snapshot(phase: controller.phase,
                                isRecording: controller.isRecording,
                                isSaving: controller.isSaving,
                                isBusy: controller.isBusy,
                                hasWorkInFlight: controller.hasWorkInFlight)
        if snapshots.last != snapshot { snapshots.append(snapshot) }
    }
}

// MARK: - Waiting

/// Poll `condition` on the main actor until it holds or `timeout` elapses; returns whether it held.
///
/// The main-actor twin of `waitUntil`: the controller's state is main-actor isolated, so it cannot be
/// read from `waitUntil`'s `@Sendable` closure at all. Real time, deliberately — this waits on the
/// test's own progress (a background stop task getting round to finishing), not on anything the
/// injected clock controls. The timeout is a deadlock guard, not a duration the tests spend.
@MainActor
func waitUntilOnMain(timeout: Double = 10.0, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

/// Long enough for a recovery pass over a fixture-sized archive to have finished, had one run.
///
/// Used only where a scenario asserts an **absence** (the second `onLaunch` recovering nothing,
/// `onAppear` recovering nothing). An absence asserted instantly asserts nothing at all: the pass
/// would simply not have started yet, and the guard could be gone without the test noticing.
func waitOutARecoveryPass() async {
    try? await Task.sleep(nanoseconds: 500_000_000)
}

// MARK: - Observations from a `@Sendable` callback

/// A flag a `@Sendable` clock callback can raise and the test can read afterwards. The clock's
/// handler runs on whatever task is sleeping — the startup probe's, not the test's — so anything it
/// observes needs real synchronization to travel back.
final class ObservedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() { lock.lock(); raised = true; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}

// MARK: - Archive fixtures

/// The folder a crash leaves in the archive: `status=recording`, an `info.md` to patch, and healthy
/// segments on both tracks that a recovery pass can really assemble with a real `ffmpeg`.
///
/// Fixture bytes rather than a fake store, for the reason the assembler tests give: recovery takes an
/// archive root, so a folder of real segments is the honest input — the scan, the segment plan and
/// `ffmpeg` all read it exactly as they would read a recording a `kill -9` interrupted.
@discardableResult
func placeInterruptedMeeting(in root: URL, named name: String) throws -> URL {
    let directory = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try makeRecording(in: directory, systemSegments: 2, micSegments: 2)

    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let manifest = SessionManifest(status: .recording, startedAt: startedAt,
                                   segmentSeconds: 15, segmentCount: 2)
    try manifest.encoded().write(to: directory.appendingPathComponent(SessionManifest.fileName))
    try MeetingInfo(title: name, date: startedAt, source: "Slack",
                    durationSeconds: 0, status: .recording)
        .rendered()
        .write(to: directory.appendingPathComponent(MeetingArchive.infoFileName),
               atomically: true, encoding: .utf8)
    return directory
}

/// Size and modification time of every file under a recording folder.
///
/// What "a second stop changed nothing" has to mean on disk. Bytes alone would not do: re-running an
/// assembly that produces identical output is still a second `ffmpeg` over the same files, and the
/// modification time is what makes that visible.
func artifactFingerprint(of directory: URL) throws -> [String: String] {
    let manager = FileManager.default
    var fingerprint: [String: String] = [:]
    for item in try manager.subpathsOfDirectory(atPath: directory.path) {
        let attributes = try manager.attributesOfItem(atPath: directory.appendingPathComponent(item).path)
        let size = (attributes[.size] as? Int) ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        fingerprint[item] = "\(size)@\(modified)"
    }
    return fingerprint
}

/// Whether both assembled tracks are playable audio.
///
/// "Assembled track", defined structurally — an `AVAsset` with an audio track, a positive duration
/// and more than a bare header — reusing the pipeline tests' own `isRealAudioFile`. Not frame-level
/// fidelity: the deterministic audio oracle is parked, so this is the floor. "Two paths exist" is
/// what it exists to refuse.
@available(macOS 15.0, *)
func bothTracksAssembled(in directory: URL) async -> Bool {
    for name in [SegmentLayout.systemTrackFileName, SegmentLayout.micTrackFileName] {
        guard await isRealAudioFile(directory.appendingPathComponent(name)) else { return false }
    }
    return true
}
