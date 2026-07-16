import ActaKit
import Foundation

/// The contract between the two sides of the crash harness: the argument grammar, the directory
/// layout, the readiness payload and the exit codes.
///
/// **Why the child is this same binary.** A `SIGKILL` cannot be simulated in-process — throwing,
/// cancelling and dropping all run cleanup, which is precisely what the signal does not — so
/// crash recovery can only be proved by a real subprocess that records, dies, and is recovered by a
/// *fresh* process. Reaching a recording with no hardware needs `FakeCaptureSource`, which lives in
/// this executable target, and SwiftPM cannot import an executable. So rather than extract the
/// fixtures into a library, `main.swift` branches on these arguments *before* the swift-testing
/// entry point: the child is `ActaTestRunner` re-invoked, and the parent is an ordinary `@Test`.
///
/// Everything crossing the process boundary is here, in one place, because both readings of it have
/// to agree and only one of them is in the process that fails.
enum Harness {
    // MARK: - Argument grammar

    /// Record into `--root`, signal readiness, then idle until stopped or killed.
    static let childFlag = "--harness-child"
    /// Recover the archive under `--root` in a fresh process, and report the outcome as an exit code.
    static let recoverFlag = "--harness-recover"
    /// The harness working directory, which is not the archive root — see `archiveRoot(in:)`.
    static let rootOption = "--root"
    /// `<frames>@<bufferIndex>`: record mode, but with audio deliberately lost. See `Fault`.
    static let dropOption = "--harness-drop"

    /// What this invocation of the binary is for.
    ///
    /// Three cases rather than an optional, because "a harness flag with no `--root`" must not be
    /// mistaken for "an ordinary test run". Falling through to the test runner there would have the
    /// child spawn a child — a fork bomb wearing a passing suite.
    enum Invocation: Equatable {
        /// No harness flag: run the tests.
        case tests
        /// A harness mode to run, after which the process exits.
        case harness(Mode)
        /// A harness flag that does not parse. The reason is for the exit message.
        case malformed(String)
    }

    /// Audio the child is told to lose on purpose — the negative control's whole content.
    ///
    /// **A hole of `frames`, not a whole dropped buffer, and the size is not arbitrary.** The
    /// encoding wraps every 65536 frames, so a lost run of *k* frames and a repeated run of
    /// `65536 - k` produce the same value delta: dropping one of the fake's one-second buffers (48000
    /// frames) would be reported, correctly but uselessly, as a 17536-frame repetition. A hole well
    /// under 32768 frames is a loss the oracle can name as a loss.
    ///
    /// It lands *before* the buffer at `bufferIndex`, so `bufferIndex > 0` is what "after the indices
    /// have advanced" means: a hole at the very start of a track is not a hole, it is a track that
    /// begins late.
    struct Fault: Equatable {
        let frames: Int
        let bufferIndex: Int

        /// The exclusive ceiling on a hole's width — half the encoding's 65536-frame wrap, so that a
        /// loss can never be arithmetically confused with a repetition. Enforced rather than merely
        /// documented: a fault wider than a buffer is silently ignored by the source, and a negative
        /// control that quietly runs a *healthy* child is a rubber stamp.
        static let maxFrames = 32_768

        /// The only way to make one, so the bounds hold wherever a fault comes from.
        ///
        /// A memberwise initialiser would leave them enforced on the command-line path alone — and
        /// the one fault that matters most, the negative control's, is built in Swift and would skip
        /// every check the parser makes. The rubber stamp `maxFrames` exists to prevent is exactly
        /// what that would allow back in.
        init?(frames: Int, bufferIndex: Int) {
            guard frames > 0, frames < Self.maxFrames, bufferIndex > 0 else { return nil }
            self.frames = frames
            self.bufferIndex = bufferIndex
        }

        /// `<frames>@<bufferIndex>`, the form the option takes on the command line.
        var argument: String { "\(frames)@\(bufferIndex)" }

        static func parse(_ text: String) -> Fault? {
            let parts = text.split(separator: "@")
            guard parts.count == 2, let frames = Int(parts[0]), let index = Int(parts[1]) else {
                return nil
            }
            return Fault(frames: frames, bufferIndex: index)
        }
    }

    /// A harness mode and the working directory it operates on.
    enum Mode: Equatable {
        case record(root: URL, fault: Fault? = nil)
        case recover(root: URL)

        /// The working directory, whichever mode this is.
        var root: URL {
            switch self {
            case .record(let root, _), .recover(let root): return root
            }
        }
    }

    /// Read the command line. Pure, so the branch `main.swift` takes is testable without spawning
    /// anything.
    static func invocation(arguments: [String]) -> Invocation {
        let flags = [childFlag, recoverFlag]
        guard let flag = arguments.first(where: { flags.contains($0) }) else { return .tests }
        guard let path = value(of: rootOption, in: arguments) else {
            return .malformed("\(flag) requires \(rootOption) <dir>")
        }
        guard !path.hasPrefix("--") else {
            return .malformed("\(rootOption) requires a directory, got \(path)")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard flag == childFlag else {
            // A fault only recover mode was asked for is a fault nothing will ever inject: recover
            // mode drives no capture. Rejecting it rather than returning before the option is read is
            // the same rule `anUnparseableDropIsMalformed` states — a fault the parent writes and the
            // child does not honour must not parse, or the negative control quietly runs healthy.
            guard !arguments.contains(dropOption) else {
                return .malformed("\(recoverFlag) does not take \(dropOption)")
            }
            return .harness(.recover(root: root))
        }

        guard let text = value(of: dropOption, in: arguments) else {
            // A bare `--harness-drop` with nothing after it is the silent drop in its quietest form:
            // `value(of:)` cannot tell "the option is absent" from "the option is last", so without
            // this the negative control's own command line parses as a *healthy* record run. Same rule
            // as recover mode one branch up — the option's presence, not its readability, is what
            // decides that a fault was asked for.
            guard !arguments.contains(dropOption) else {
                return .malformed("\(dropOption) requires <frames>@<bufferIndex>")
            }
            return .harness(.record(root: root))
        }
        guard let fault = Fault.parse(text) else {
            return .malformed("\(dropOption) requires <frames>@<bufferIndex>, got \(text)")
        }
        return .harness(.record(root: root, fault: fault))
    }

    /// The command line that asks for `mode` — the counterpart of `invocation(arguments:)`, so the
    /// two readings of the grammar sit next to each other rather than in the two processes that have
    /// to agree on it.
    static func arguments(for mode: Mode) -> [String] {
        switch mode {
        case .record(let root, let fault):
            return [childFlag, rootOption, root.path]
                + (fault.map { [dropOption, $0.argument] } ?? [])
        case .recover(let root):
            return [recoverFlag, rootOption, root.path]
        }
    }

    private static func value(of option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    // MARK: - Layout of the working directory

    /// The archive the child records into — a *subdirectory* of the working root.
    ///
    /// Separate so the harness's own files are nowhere the app's code will look: `RecoveryManager`
    /// scans the archive root for meeting folders, and control files sitting among them would be
    /// input to the very scan they exist to coordinate.
    static func archiveRoot(in root: URL) -> URL {
        root.appendingPathComponent("archive", isDirectory: true)
    }

    /// What the child publishes once the archive holds the state the parent asked for.
    static func readinessFile(in root: URL) -> URL { root.appendingPathComponent("ready.json") }

    /// Where readiness is written before it is renamed into place. The rename is what makes
    /// readiness atomic: `rename(2)` either happens or does not, so the parent can never read a
    /// half-written payload, and the file's existence at its final name *is* the signal. A pipe
    /// would do as well, but its EOF — which is what a child dying produces — is indistinguishable
    /// from silence unless a readiness byte is defined and the fd inheritance is got right; a file
    /// has no such edge.
    static func readinessStagingFile(in root: URL) -> URL {
        root.appendingPathComponent("ready.json.partial")
    }

    /// The parent's request for a graceful stop, renamed into place for the same reason.
    static func stopFile(in root: URL) -> URL { root.appendingPathComponent("stop") }
    static func stopStagingFile(in root: URL) -> URL { root.appendingPathComponent("stop.partial") }

    /// What the child knows at readiness and the parent cannot work out for itself.
    struct Readiness: Codable, Equatable {
        /// The child's own pid — the exact process to signal. Read from the child rather than
        /// assumed, so the parent's spawn and its kill cannot drift apart.
        var pid: Int32
        /// The meeting folder's name inside the archive.
        var meeting: String
        /// Frames emitted per track, by the time emission was frozen. The **upper bound** on what
        /// any recovered track may hold: emission stops before this is written, so nothing can be
        /// produced after it that the number does not cover.
        var systemFrames: Int
        var micFrames: Int

        func frames(_ track: Track) -> Int {
            track == .system ? systemFrames : micFrames
        }
    }

    // MARK: - Exit codes

    /// How the child reports itself. Distinct codes rather than a bare non-zero: a supervision test
    /// that cannot say *why* the child gave up reports a hang and a rejected start identically.
    enum Exit: Int32 {
        case ok = 0
        /// Recording needs macOS 15+ (`SCStreamConfiguration.captureMicrophone`), and so does
        /// everything the harness drives.
        case unsupported = 64
        /// `start()` never reached `.recording` — the pipeline rejected the start.
        case startFailed = 65
        /// The archive never reached the state readiness is defined as.
        case notReady = 66
        /// A requested stop did not leave the recording saved. Its own code rather than
        /// `startFailed`: a stop that loses the meeting and a start that never began are opposite
        /// failures, and codes that lie are worse than a bare non-zero.
        case stopFailed = 72
        /// Recovery ran and left audio outside a track.
        case recoveryIncomplete = 67
        /// Recovery could not read the archive at all. Its own code rather than `recoveryIncomplete`:
        /// that one means the pass looked and found audio it could not place, this one means it never
        /// looked, and a harness that cannot tell those apart is asserting through the ambiguity the
        /// verdict exists to resolve.
        case recoveryScanFailed = 73
        /// Recovery did not finish inside `recoveryTimeoutSeconds`.
        case recoveryTimedOut = 68
        /// `onLaunch()` started no pass at all — the seam returned `nil`.
        case recoveryDidNotRun = 69
        /// Nobody stopped or killed the child within `childLifetimeSeconds`.
        case abandoned = 70
        /// The arguments did not parse.
        case malformed = 71
    }

    /// How long the child waits to be stopped or killed before exiting on its own.
    ///
    /// A child is only ever ended by its parent, so reaching this means the parent died or hung —
    /// and a recording child left behind holds a wake lock and spins a watchdog forever. Generous
    /// enough that a loaded machine cannot trip it.
    static let childLifetimeSeconds = 180.0

    /// How long recover mode waits for the pass. It is a bound on a hang, not a duration anything is
    /// expected to spend: a fixture-sized archive assembles in well under a second, but `ffmpeg` on
    /// a cold, loaded machine is not something to be clever about.
    static let recoveryTimeoutSeconds = 120.0

    /// How long the child may spend driving audio into the archive before readiness must hold.
    static let readinessTimeoutSeconds = 60.0

    /// How long the parent waits for readiness — **derived, and it has to outlast the child.**
    ///
    /// The child spends this budget twice before it gives up: once waiting out `start()`, once
    /// driving the archive to a crash-worthy state. A parent that gave up sooner would kill a healthy
    /// child on a loaded machine and report it as "never ready", and `Exit.notReady` — the child's own
    /// word for that failure — could never be observed, because the parent would always speak first.
    /// The margin covers the spawn and the polling interval.
    static let readinessWaitSeconds = 2 * readinessTimeoutSeconds + 30.0
}
