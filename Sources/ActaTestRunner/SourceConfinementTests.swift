import Foundation
import Testing

/// The CoreAudio confinement — as a **test**, not an honour-system `grep`.
///
/// `CLAUDE.md` calls three confinements "grep-enforceable" and only one of them was ever a test; the
/// ScreenCaptureKit and TCC rules are held by a human remembering to run a command. The new rule gets
/// a test rather than joining that list.
@Suite("Source confinement")
struct SourceConfinementTests {
    // MARK: - The parser, tested before anything is asked of it

    /// ⚠️ **This fixture is the whole point of the rewrite.** The guard that shipped before matched
    /// `hasPrefix("import ")`, so an attributed import was invisible to it — and this codebase uses
    /// that form (`SCKCaptureSource.swift:5`). A guard whose reader has a hole is worse than no guard,
    /// because it is believed.
    @Test("an attributed import is seen")
    func attributedImportsAreSeen() {
        #expect(SourceConfinement.importedModules(in: "@preconcurrency import AppKit") == ["AppKit"])
        #expect(SourceConfinement.importedModules(in: "@_exported import Darwin") == ["Darwin"])
        #expect(SourceConfinement.importedModules(in: "import Foundation") == ["Foundation"])
        #expect(SourceConfinement.importedModules(in: "import struct Foundation.Data") == ["Foundation"])
    }

    /// ⚠️ And an import **named in a comment** is not one. Doc comments legitimately name these modules
    /// — the rule is about type references, and the fix for a false positive is to move the comment,
    /// never to contort the code.
    @Test("an import named in a comment is ignored")
    func commentedImportsAreIgnored() {
        #expect(SourceConfinement.importedModules(in: "// import AppKit").isEmpty)
        #expect(SourceConfinement.importedModules(in: "/// see `import AppKit` for why").isEmpty)
        #expect(SourceConfinement.importedModules(in: "/* import AppKit */\nimport Foundation")
            == ["Foundation"])
        // Nested block comments, which Swift allows.
        #expect(SourceConfinement.importedModules(in: "/* /* import AppKit */ */\nimport Foundation")
            == ["Foundation"])
    }

    @Test("a HAL symbol in a comment is not a use")
    func commentedHALSymbolsAreIgnored() {
        #expect(SourceConfinement.halSymbols(in: "// AudioObjectGetPropertyData is the HAL call").isEmpty)
        #expect(SourceConfinement.halSymbols(in: "let x = AudioObjectID(0)") == ["AudioObjectID"])
    }

    /// ⚠️ The narrowness is deliberate and worth pinning: audio **buffer** types belong to the writer
    /// and the capture path, and forbidding a type for belonging to an audio framework would make this
    /// a rule people route around rather than keep.
    @Test("unrelated audio types are not guarded")
    func unrelatedAudioTypesAreNotGuarded() {
        #expect(SourceConfinement.halSymbols(in: "var b: AudioBufferList").isEmpty)
        #expect(SourceConfinement.halSymbols(in: "func f(_ s: CMSampleBuffer) {}").isEmpty)
        #expect(SourceConfinement.halSymbols(in: "var d: AudioStreamBasicDescription").isEmpty)
    }

    // MARK: - The rules themselves

    /// The production targets. ⚠️ Named here rather than derived, so adding a target is a decision
    /// somebody makes about this rule rather than a silent gap.
    private static let productionTargets = ["ActaKit", "ActaRuntime", "ActaControlProtocol", "Acta"]

    /// The one file allowed to name the HAL.
    private static let allowedAdapter = "CoreAudioDeviceDirectory.swift"

    /// ⚠️ **The confinement Task 8 exists for.** Keeping the HAL in one file is what lets everything
    /// above it be tested without a sound card — and what stops a second CoreAudio directory being
    /// minted somewhere, which the app-lifetime ownership rule depends on.
    @Test("CoreAudio HAL symbols appear only in the adapter")
    func halSymbolsAreConfinedToTheAdapter() throws {
        var offenders: [String] = []
        for target in Self.productionTargets {
            let directory = SourceConfinement.sourcesRoot.appendingPathComponent(target)
            for file in SourceConfinement.swiftFiles(under: directory) {
                guard file.lastPathComponent != Self.allowedAdapter else { continue }
                let symbols = SourceConfinement.halSymbols(in: try String(contentsOf: file, encoding: .utf8))
                if !symbols.isEmpty {
                    offenders.append("\(target)/\(file.lastPathComponent): \(symbols.joined(separator: ", "))")
                }
            }
        }
        #expect(offenders.isEmpty,
                "the HAL must stay in \(Self.allowedAdapter): \(offenders.joined(separator: "; "))")
    }

    /// The adapter is where the HAL lives, so it had better name it — otherwise this whole suite could
    /// pass over a codebase that had quietly moved the HAL somewhere the scanner does not look.
    @Test("the adapter really is where the HAL lives")
    func theAdapterNamesTheHAL() throws {
        let adapter = SourceConfinement.sourcesRoot
            .appendingPathComponent("ActaRuntime").appendingPathComponent(Self.allowedAdapter)
        let symbols = SourceConfinement.halSymbols(in: try String(contentsOf: adapter, encoding: .utf8))
        #expect(symbols.count >= 5, "the adapter names almost no HAL symbols — has the HAL moved?")
    }

    /// ⚠️ **Deliberately excluded**: the live divergence probe of Task 9 must import `AVFoundation` and
    /// name device identities by design, and it lives outside the production targets for exactly that
    /// reason. Scanning only the four production targets is what keeps that possible without an
    /// exemption list nobody maintains.
    @Test("the guard scans production targets and nothing else")
    func theGuardScopesItselfToProduction() {
        #expect(Self.productionTargets.contains("ActaRuntime"))
        #expect(Self.productionTargets.contains("Acta"))
        #expect(Self.productionTargets.contains("ActaTestRunner") == false)
    }
}
