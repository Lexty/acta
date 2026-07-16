import Foundation

/// The parent side of the crash harness: spawn this binary as a child, wait for what it publishes,
/// stop it or kill it, and read how it ended.
///
/// **Process control, done one way.** Everything here goes through Foundation's `Process`: it
/// spawns, it reaps, `terminationReason` says whether a signal ended the child, and
/// `terminationStatus` says which. Mixing `Process` with a direct `waitpid` on the same child is the
/// trap this type exists to avoid — Foundation reaps its children itself, so a hand-rolled `waitpid`
/// races it for the status and one of the two comes back with nothing. The one place this does not
/// take Foundation's obvious route is `waitUntilExit()`, which blocks; `waitForExit()` explains why
/// it suspends on `terminationHandler` instead. That is the same mechanism, not a second one.
final class HarnessProcess {
    /// The working directory the child was given: `<root>/archive` is the archive, everything else
    /// under it is the protocol.
    let root: URL

    private let process: Process
    private let stderr = Pipe()
    /// Read continuously rather than at exit: a child that filled the 64 KiB pipe buffer would block
    /// on its own diagnostics and hang, which would read here as a timeout with no explanation.
    private let collected = CollectedOutput()
    /// Fired from `terminationHandler`, awaited by `waitForExit()`.
    private let exited = OneShotEvent()

    /// Spawn `ActaTestRunner` again, in a harness mode, against a fresh working directory.
    ///
    /// The binary is located with `Bundle.main.executableURL`, canonicalised — not
    /// `CommandLine.arguments[0]`, which is whatever string the caller happened to `exec` with: a
    /// relative path resolved against a working directory nobody promised, or a name that was only
    /// ever found on `PATH`.
    init(mode: Harness.Mode) throws {
        root = mode.root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().standardized else {
            throw HarnessError.executableNotFound
        }
        process = Process()
        process.executableURL = executable
        process.arguments = Harness.arguments(for: mode)
        process.standardError = stderr
        // Nothing on stdout matters, and inheriting the parent's would interleave with the test
        // report; stdin is closed so a child that ever tried to read one gets EOF, not the runner's.
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        stderr.fileHandleForReading.readabilityHandler = { [collected] handle in
            let data = handle.availableData
            // Empty means EOF — the child is gone and its end of the pipe is closed. Tearing the
            // handler down here is not tidiness: the dispatch source stays readable at EOF forever,
            // so a handler that merely returns is re-invoked as fast as a core can do it. That spin
            // burns a CPU for the rest of the run and starves the pool the awaits above need.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            collected.append(data)
        }
        // Set before `run()`, so a child that exits immediately cannot beat the handler into place.
        process.terminationHandler = { [exited] _ in exited.fire() }
        try process.run()
    }

    /// The child's pid as this side sees it. The crash scenario signals the pid the *child* publishes
    /// instead, and compares the two: a kill aimed at a pid the child never claimed is a kill aimed
    /// at whatever inherited it.
    var processIdentifier: Int32 { process.processIdentifier }

    /// Whatever the child has said on stderr so far.
    var diagnostics: String { collected.text }

    /// Wait for the child to publish readiness; `nil` if it never does.
    ///
    /// Bounded, and it gives up rather than hanging: a child that dies before signalling would
    /// otherwise leave the suite waiting forever, and "the test never finished" is not a test result.
    /// The bound is `Harness.readinessWaitSeconds` rather than a number of this side's own, because
    /// it is only correct in relation to the child's — see that constant.
    func waitForReadiness() async -> Harness.Readiness? {
        let file = Harness.readinessFile(in: root)
        let deadline = Date().addingTimeInterval(Harness.readinessWaitSeconds)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let readiness = try? JSONDecoder().decode(Harness.Readiness.self, from: data) {
                return readiness
            }
            // A child that has already exited will never signal, so stop waiting out the timeout for
            // it — the caller wants the diagnostics now, not in a minute and a half.
            guard process.isRunning else { return nil }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    /// Ask the child to stop the recording and exit cleanly. Renamed into place for the same reason
    /// readiness is: the request must be seen whole or not at all.
    func requestStop() throws {
        let staging = Harness.stopStagingFile(in: root)
        try Data().write(to: staging, options: .atomic)
        try FileManager.default.moveItem(at: staging, to: Harness.stopFile(in: root))
    }

    /// `SIGKILL` the child. Uncatchable and uncleanable-after, which is the whole point: it is the
    /// one fault an in-process test cannot stage.
    func kill() {
        _ = Foundation.kill(process.processIdentifier, SIGKILL)
    }

    /// Whether the child is still alive right now.
    var isRunning: Bool { process.isRunning }

    /// Reap the child and report how it ended.
    ///
    /// Suspends on `terminationHandler` rather than calling `waitUntilExit()`. That call *blocks*,
    /// and there is nowhere here it may block: on the caller's thread it stalls the actor the test
    /// runs on, and inside a `Task.detached` it pins one of the cooperative pool's few threads —
    /// with a handful of children reaped at once, the pool runs out and the runtime deadlocks with
    /// every stack sitting in `mach_msg`, looking for all the world like a hung child.
    func waitForExit() async -> Termination {
        await exited.wait()
        stderr.fileHandleForReading.readabilityHandler = nil
        // Anything written between the last handler call and the exit: the handler is torn down
        // above, so this read is the one that sees the tail.
        if let rest = try? stderr.fileHandleForReading.readToEnd(), !rest.isEmpty {
            collected.append(rest)
        }
        return Termination(reason: process.terminationReason, status: process.terminationStatus)
    }

    /// How a child process ended.
    struct Termination: Equatable {
        let reason: Process.TerminationReason
        /// The exit code for a normal exit, the signal number for a signalled one.
        let status: Int32

        /// Whether the child exited normally with `code`.
        func exited(_ code: Harness.Exit) -> Bool {
            reason == .exit && status == code.rawValue
        }

        /// Whether a signal ended the child, and that signal was `signal`.
        ///
        /// The assertion the crash scenario cannot do without: a child that exited normally means
        /// the kill raced the recording and arrived after it was already over — the run would then
        /// prove that a clean stop recovers, which is a different (and already tested) claim.
        func signalled(by signal: Int32) -> Bool {
            reason == .uncaughtSignal && status == signal
        }
    }

    /// Kill the child if a test left it alive, and remove the working directory. Not a `deinit`: the
    /// archive must go at a point in the test's own timeline, not whenever the last reference drops.
    ///
    /// It waits for nothing, which is what lets it be a `defer` in an async test: `SIGKILL` needs no
    /// reaping from here — Foundation reaps its own children — and the temp directory is not
    /// something a dying process can hold on to.
    func tearDown() {
        if process.isRunning { kill() }
        stderr.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(at: root)
        removeDefaultsSuite()
    }

    /// Remove the defaults suite the child recorded through — from here, because the child may never
    /// have had the chance: `SIGKILL` runs no cleanup. That is why the name is derived from `root`
    /// rather than minted inside the child; see `Harness.defaultsSuiteName(in:)`.
    ///
    /// The domain *and* the file. `removePersistentDomain` empties the plist but leaves it behind in
    /// `~/Library/Preferences`, so on its own it would still mean one file per run accumulating there
    /// forever — only an empty one.
    private func removeDefaultsSuite() {
        let suite = Harness.defaultsSuiteName(in: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    enum HarnessError: Error {
        /// `Bundle.main` could not name the running binary, so there is nothing to re-invoke.
        case executableNotFound
    }
}

/// A one-shot event: fired once from an arbitrary queue, awaited any number of times.
///
/// It exists so nothing here blocks a thread. Every waiter parked before the fire is resumed by it,
/// and every waiter after it resumes at once — the flag and the waiter list move under one lock, so
/// a `wait()` that races the `fire()` cannot park after the resume has already gone out.
private final class OneShotEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        fired = true
        let parked = waiters
        waiters = []
        lock.unlock()
        parked.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !fired else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// A child's stderr, accumulated from Foundation's reader queue and read back from the test's.
private final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// A working directory for one harness run, under the system temp directory.
func makeHarnessRoot(_ label: String) -> URL {
    makeTemporaryDirectory("harness-\(label)")
}
