// swift-tools-version:6.0
import PackageDescription
import Foundation

// Acta — a menu-bar app that only records online meetings.
// No external dependencies (there is no transcription → WhisperKit is not needed).
//
// Target layout (important for testability in a Command-Line-Tools-ONLY environment):
//   • ActaControlProtocol
//                    — the control wire protocol: envelopes, commands, results, errors, the JSON-lines
//                      framer. It declares NO dependencies, and that emptiness is the design: the app
//                      and the future `actactl` binary must share one definition of the schema, and a
//                      target that cannot see ActaKit or ActaRuntime cannot weld the wire format to the
//                      runtime's representation. Do not add a dependency here to "reuse" a runtime type
//                      — the projection lives in ActaRuntime, pointing this way.
//   • ActaKit        — the library holding the pure logic (this is what we test; it grows in
//                      Task 2–7).
//   • ActaRuntime    — the library holding the recording pipeline: RecordingController,
//                      RecordingSession, RecoveryManager, AudioRecorder, SegmentWriter,
//                      SegmentAssembler, MeetingStore, SelfCheck and friends — everything that does
//                      real I/O. It exists because SwiftPM CANNOT import an executable target: while
//                      this code lived in `Acta`, nothing above pure logic could be reached from
//                      `ActaTestRunner` at all, and every criterion that mattered had to be verified
//                      by hand. A library target may import AppKit/SwiftUI, so the AppKit-touching
//                      types moved here unchanged.
//   • Acta           — the executable, @main + the SwiftUI menu bar and its views, and nothing else;
//                      depends on ActaRuntime + ActaKit.
//   • ActaTestRunner — an executable with swift-testing @Test functions plus an entry point
//                      (`Testing.__swiftPMEntryPoint`). This is the REAL test run
//                      (`swift run ActaTestRunner` / `bash Scripts/test.sh`).
//   • ActaTests      — a stub testTarget so that `swift test` passes (see below).
//
// Why it is done this way: under CLT-only (no full Xcode) `swift test` BUILDS the test bundle but
// does NOT execute it — the `xctest` host utility is not present on the system, so a failing test
// still yields exit 0. To make the tests actually run (and fail on an error), they are launched by
// the executable runner through the public swift-testing entry point. The testTarget is kept as a
// "stub" for the sake of the `swift test` command from the plan; the real run is
// `bash Scripts/test.sh`.

func developerDir() -> String {
    if let dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !dir.isEmpty {
        return dir
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    proc.arguments = ["-p"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty {
            return str
        }
    } catch {
        // ignore — we return the default below
    }
    return "/Library/Developer/CommandLineTools"
}

// Flags that provide swift-testing (Testing.framework, lib_TestingInterop.dylib, the TestingMacros
// macro plugin) in the CLT layout. With a full Xcode the paths differ and SwiftPM finds everything
// on its own — in that case we do not add the flags.
func swiftTestingSettings() -> (swift: [SwiftSetting], linker: [LinkerSetting]) {
    let dev = developerDir()
    let frameworks = "\(dev)/Library/Developer/Frameworks"
    let libDir = "\(dev)/Library/Developer/usr/lib"
    let pluginDir = "\(dev)/usr/lib/swift/host/plugins/testing"

    guard FileManager.default.fileExists(atPath: "\(frameworks)/Testing.framework") else {
        return ([], [])
    }

    let swift: [SwiftSetting] = [
        .unsafeFlags(["-F", frameworks, "-plugin-path", pluginDir])
    ]
    let linker: [LinkerSetting] = [
        .unsafeFlags([
            "-F", frameworks,
            "-L", libDir,
            "-Xlinker", "-rpath", "-Xlinker", frameworks,
            "-Xlinker", "-rpath", "-Xlinker", libDir
        ])
    ]
    return (swift, linker)
}

let testing = swiftTestingSettings()

let package = Package(
    name: "Acta",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "ActaKit",
            path: "Sources/ActaKit"
        ),
        // The dependency-free wire protocol for `actactl`. It lists NO `dependencies` ON PURPOSE:
        // the structural isolation (it cannot import ActaKit/ActaRuntime/AppKit/SwiftUI, so the wire
        // schema stays decoupled from the runtime representation) is enforced here, not only by an
        // import grep. It imports Foundation alone.
        .target(
            name: "ActaControlProtocol",
            path: "Sources/ActaControlProtocol"
        ),
        // Depends on ActaControlProtocol, never the other way round: the projection
        // (ControlState → WireControlState) and the dispatcher need both sides visible, while the wire
        // target must stay unable to see the runtime at all.
        .target(
            name: "ActaRuntime",
            dependencies: ["ActaKit", "ActaControlProtocol"],
            path: "Sources/ActaRuntime"
        ),
        .executableTarget(
            name: "Acta",
            dependencies: ["ActaKit", "ActaRuntime"],
            path: "Sources/Acta"
        ),
        .executableTarget(
            name: "ActaTestRunner",
            dependencies: ["ActaKit", "ActaRuntime", "ActaControlProtocol"],
            path: "Sources/ActaTestRunner",
            swiftSettings: testing.swift,
            linkerSettings: testing.linker
        ),
        .testTarget(
            name: "ActaTests",
            dependencies: ["ActaKit"],
            path: "Tests/ActaTests"
        )
    ]
)
