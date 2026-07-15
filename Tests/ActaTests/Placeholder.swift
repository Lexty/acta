import ActaKit

// A stub testTarget so that the `swift test` command from the plan passes from the very beginning.
//
// NOTE: under CLT-only (no full Xcode) `swift test` only BUILDS the test bundle but does NOT
// execute it — the `xctest` host utility is not present on the system. The real test run (which
// fails on an error) is done by the executable runner: `bash Scripts/test.sh` (a.k.a.
// `swift run ActaTestRunner`).
//
// There are deliberately no test cases here: they live in the ActaTestRunner target so that they
// actually execute.
enum ActaTestsPlaceholder {
    static let linkedModule = AppInfo.name
}
