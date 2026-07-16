import ActaKit
import ActaRuntime
import Foundation
import Testing

/// Everything that spawns a harness child, under one roof — and the roof is the point.
///
/// `.serialized` is what makes the wall-clock budgets below mean anything: every test under here
/// spawns a subprocess that records with `AVAssetWriter` and then runs `ffmpeg`, and swift-testing
/// parallelizes by default. Nothing in the harness is process-global, but the machine is, and
/// children racing children turn a bound on a hang into a bound on the load.
///
/// The trait has to sit on a **shared parent** to do that. It serializes a suite's own subtree and
/// nothing else, so `.serialized` written separately on `Plumbing` and on `Crash` would leave the
/// two of them free to run against each other — which is the race worth preventing, since those are
/// the two that spawn children. Hence the empty parent: it carries the trait, and both nest in it.
@Suite(.serialized)
struct HarnessTests {}

/// The crash harness with the crash left out: spawn → readiness → graceful stop → recover-is-a-no-op.
///
/// It exists to fail *before* the kill does. Every step the `SIGKILL` scenario relies on is here —
/// locating and re-invoking the binary, the child reaching a real recording with no hardware, the
/// readiness signal, the stop request, the reap, and the fresh-process recover mode — so when the
/// crash scenario goes red, it is because recovery broke, not because the plumbing under it did. A
/// harness whose first test is the payoff cannot tell those apart.
extension HarnessTests {
    @Suite
    struct Plumbing {
        /// What the whole non-crash round trip may take. Generous — a cold `AVAssetWriter`, real
        /// segment finalisation and a real `ffmpeg` concat on a loaded machine are not fast — but
        /// asserted, because the failure this bounds is a hang, and a hang with no bound is a suite that
        /// never returns.
        private static let wallClockBudgetSeconds = 120.0

        @Test("The parser sends a harness flag to the harness and everything else to the tests")
        func argumentsBranchBeforeTheTestRunner() {
            let root = "/tmp/acta-harness"
            #expect(Harness.invocation(arguments: ["ActaTestRunner"]) == .tests)
            #expect(Harness.invocation(arguments: ["ActaTestRunner", "--filter", "Recovery"]) == .tests)
            #expect(Harness.invocation(arguments: ["ActaTestRunner", Harness.childFlag,
                                                   Harness.rootOption, root])
                    == .harness(.record(root: URL(fileURLWithPath: root, isDirectory: true))))
            #expect(Harness.invocation(arguments: ["ActaTestRunner", Harness.recoverFlag,
                                                   Harness.rootOption, root])
                    == .harness(.recover(root: URL(fileURLWithPath: root, isDirectory: true))))
        }

        /// The grammar's two readings, checked against each other. They live in one process here and in
        /// two when it matters, and a fault that the parent writes and the child does not read is a
        /// negative control that quietly controls nothing.
        @Test("What the parent asks for is what the child parses")
        @available(macOS 15.0, *)
        func theArgumentBuilderAndTheParserAgree() {
            let root = URL(fileURLWithPath: "/tmp/acta-harness", isDirectory: true)
            for mode: Harness.Mode in [.record(root: root),
                                       .record(root: root, fault: CrashRun.fault),
                                       .recover(root: root)] {
                #expect(Harness.invocation(arguments: ["ActaTestRunner"] + Harness.arguments(for: mode))
                        == .harness(mode))
            }
        }

        @Test("A drop that does not parse is malformed, not silently ignored")
        func anUnparseableDropIsMalformed() {
            // Silently dropping the fault would leave the negative control running a *healthy* child and
            // reporting the oracle's silence as the oracle working.
            #expect(Harness.invocation(arguments: ["ActaTestRunner", Harness.childFlag,
                                                   Harness.rootOption, "/tmp/x", Harness.dropOption, "4096"])
                    == .malformed("\(Harness.dropOption) requires <frames>@<bufferIndex>, got 4096"))
            // A hole at buffer zero is not a hole — the indices have not advanced yet.
            #expect(Harness.Fault.parse("4096@0") == nil)
            #expect(Harness.Fault.parse("4096@1") == Harness.Fault(frames: 4096, bufferIndex: 1))
            // And a hole at or past half the encoding's wrap is rejected rather than accepted and then
            // ignored by the source: at 48000 the oracle would report a truthful 17536-frame repetition
            // about audio that was actually lost, and the control would be testing nothing.
            #expect(Harness.Fault.parse("48000@1") == nil)
            #expect(Harness.Fault.parse("\(Harness.Fault.maxFrames)@1") == nil)
            #expect(Harness.Fault.parse("\(Harness.Fault.maxFrames - 1)@1")
                    == Harness.Fault(frames: Harness.Fault.maxFrames - 1, bufferIndex: 1))
        }

        /// A harness flag the parser cannot honour must not become a test run. Falling through would put
        /// the suite inside the child — and the suite spawns children.
        @Test("A harness flag with no root is a malformed invocation, not a test run")
        func aHarnessFlagWithoutARootNeverFallsThrough() {
            #expect(Harness.invocation(arguments: ["ActaTestRunner", Harness.childFlag])
                    == .malformed("\(Harness.childFlag) requires \(Harness.rootOption) <dir>"))
            #expect(Harness.invocation(arguments: ["ActaTestRunner", Harness.recoverFlag,
                                                   Harness.rootOption, "--other"])
                    == .malformed("\(Harness.rootOption) requires a directory, got --other"))
        }

        @Test("A child records, signals readiness, stops cleanly, and its archive needs no recovery")
        @available(macOS 15.0, *)
        func theChildRecordsAndStopsAndRecoveryThenHasNothingToDo() async throws {
            let started = Date()
            let child = try HarnessProcess(mode: .record(root: makeHarnessRoot("plumbing")))
            defer { child.tearDown() }

            let readiness = await child.waitForReadiness()
            try #require(readiness != nil, "the child never signalled readiness: \(child.diagnostics)")
            let ready = readiness!

            // The pid the child claims is the process this side spawned. The crash scenario signals the
            // published one, so a drift between the two would aim a `SIGKILL` at a stranger.
            #expect(ready.pid == child.processIdentifier)
            // Both tracks produced audio, and the count is a real one rather than a zero that would make
            // every later bound vacuously true.
            #expect(ready.systemFrames > 0)
            #expect(ready.micFrames > 0)

            // Readiness means the archive is worth crashing: per track, a finalised segment and an open
            // one holding audio, with the marker still `recording`. Re-checked from here because the
            // child's word for it is the child's word for it.
            let archive = Harness.archiveRoot(in: child.root)
            let meeting = archive.appendingPathComponent(ready.meeting, isDirectory: true)
            #expect(HarnessChild.isCrashWorthy(meeting: meeting))

            // And now the half the crash scenario replaces with a signal: ask, and it saves.
            try child.requestStop()
            let termination = await child.waitForExit()
            #expect(termination.exited(.ok), "the child did not stop cleanly: \(child.diagnostics)")
            #expect(try readSessionManifest(in: meeting).status == .done)
            #expect(await bothTracksAssembled(in: meeting))

            // A `.done` session leaves no interrupted marker, so a fresh process finds nothing to act on
            // — and reports that as success. This is why recover mode's success has to include
            // nothing-to-recover and not only `.recovered`: without it the plumbing could only ever be
            // exercised by a real crash, which is the thing it exists to de-risk.
            let recoverer = try HarnessProcess(mode: .recover(root: child.root))
            let recovery = await recoverer.waitForExit()
            #expect(recovery.exited(.ok), "recover mode failed: \(recoverer.diagnostics)")
            #expect(recoverer.diagnostics.contains("nothingToRecover"),
                    "recover mode should have found nothing to do: \(recoverer.diagnostics)")
            // Untouched: recovery acting on a folder it has no business in is exactly the bug the
            // `needsRecovery` guard exists to prevent.
            #expect(try readSessionManifest(in: meeting).status == .done)

            let elapsed = Date().timeIntervalSince(started)
            #expect(elapsed < Self.wallClockBudgetSeconds,
                    "the round trip took \(Int(elapsed))s, over the \(Int(Self.wallClockBudgetSeconds))s budget")
        }

        /// Recover mode's floor: an archive with no meeting in it at all must be a clean, quick
        /// success. It is the one case the crash tests cannot reach — they always hand recovery a
        /// folder to act on — and the case every `guard` in the scan walks through first, so a pass
        /// that threw, hung or exited non-zero on an empty directory would break the harness before
        /// any real crash got near it.
        @Test("Recover mode over an archive that was never recorded into finds nothing")
        @available(macOS 15.0, *)
        func recoverModeOverAnEmptyArchiveSucceeds() async throws {
            let root = makeHarnessRoot("empty")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: Harness.archiveRoot(in: root),
                                                    withIntermediateDirectories: true)

            let recoverer = try HarnessProcess(mode: .recover(root: root))
            defer { recoverer.tearDown() }
            let termination = await recoverer.waitForExit()
            #expect(termination.exited(.ok), "recover mode failed: \(recoverer.diagnostics)")
        }
    }
}
