import Testing

// Test runner entry point. In a CLT-only environment `swift test` does not execute the xctest
// bundle (there is no `xctest` host utility), so we run swift-testing directly through its public
// entry point. Exit code != 0 if at least one `@Test` failed. Run with: `bash Scripts/test.sh`.
await Testing.__swiftPMEntryPoint() as Never
