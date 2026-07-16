import Foundation
import Testing

// Test runner entry point. In a CLT-only environment `swift test` does not execute the xctest
// bundle (there is no `xctest` host utility), so we run swift-testing directly through its public
// entry point. Exit code != 0 if at least one `@Test` failed. Run with: `bash Scripts/test.sh`.
//
// Before that, the harness branch. `SIGKILL` cannot be staged in-process — it is the one fault that
// runs no cleanup — so the crash-recovery scenarios need a real subprocess, and reaching a recording
// without hardware needs `FakeCaptureSource`, which lives in this executable target. SwiftPM cannot
// import an executable, so rather than extract the fixtures, this binary spawns itself: with a
// harness flag it runs the mode and exits, and never falls through to the tests. That last part is
// load-bearing — a child that fell through would run the suite, whose tests spawn children.
switch Harness.invocation(arguments: CommandLine.arguments) {
case .tests:
    break
case .malformed(let reason):
    FileHandle.standardError.write(Data("harness: \(reason)\n".utf8))
    exit(Harness.Exit.malformed.rawValue)
case .harness(let mode):
    guard #available(macOS 15.0, *) else {
        FileHandle.standardError.write(Data("harness: recording requires macOS 15+\n".utf8))
        exit(Harness.Exit.unsupported.rawValue)
    }
    await HarnessChild.run(mode)
}

await Testing.__swiftPMEntryPoint() as Never
