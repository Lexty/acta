import Testing
import ActaKit
import ActaRuntime

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

// The dev build must be visibly distinct from stable — two flavors run side by side, and confusing
// them means recording into the wrong archive. The menu-bar tag and panel header both use this.
@Test
func devFlavorCarriesAVisibleSuffixAndStableDoesNot() {
    #expect(BuildFlavor.stable.appDisplayName == "Acta")
    #expect(BuildFlavor.dev.appDisplayName == "Acta Dev")
    #expect(BuildFlavor.dev.appDisplayName != BuildFlavor.stable.appDisplayName)
}
