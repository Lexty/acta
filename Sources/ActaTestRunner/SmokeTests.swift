import Testing
import ActaKit

// Scaffold: proves that the test runner actually executes tests and fails on an error.
// The substantive unit tests (ffmpeg arguments, recovery logic, the "data is not flowing"
// detector, slug/front-matter) are added alongside in Task 2-5, in this same target.
@Test
func bundleIdentifierIsStable() {
    #expect(AppInfo.bundleID == "dev.personal.acta")
}

@Test
func appNameIsActa() {
    #expect(AppInfo.name == "Acta")
}
