import Foundation
import Testing

/// The CoreAudio confinement — as a **test**, not an honour-system `grep`.
///
/// `CLAUDE.md` calls three confinements "grep-enforceable" and only one of them was ever a test; the
/// ScreenCaptureKit and TCC rules are held by a human remembering to run a command. The new rule gets
/// a test rather than joining that list.
@Suite("Source confinement")
struct SourceConfinementTests {
    /// A regression guard for one leak that actually happened: the Settings window was introduced so
    /// configuration would stop living in two places, its own commit said the microphone controls had
    /// moved, and `Toggle("Keep the Mac's input on my list")` went on standing in `ActaApp.swift`
    /// beside the identical one in `SettingsWindow.swift` for four commits, through several reviews.
    ///
    /// ⚠️ **What this actually establishes, stated narrowly because the first version of this comment
    /// claimed more.** Each of the **listed literal strings** occurs in exactly one file under
    /// `Sources/Acta`, and that file is `SettingsWindow.swift`. It does **not**: count occurrences
    /// *within* that file, recognise the same setting written under a different label, or cover a
    /// persistent control added later. A new control is caught only when someone adds its label below
    /// — deliberately, which is the intended cost. It is a guard against this leak recurring, not a
    /// general rule that configuration cannot appear in the panel, and nothing here should be reported
    /// as the latter.
    ///
    /// ⚠️ The check runs on **comment-stripped** source, so the doc comment in `ActaApp.swift` that
    /// explains why the control is not there does not trip it — which is the same reason the parser
    /// strips comments for the import guards.
    @Test("the listed persistent controls appear only in the Settings window")
    func persistentControlsLiveOnlyInSettings() {
        // The labels of controls that write a *setting* — as opposed to acting on what is happening
        // now, which is what the panel keeps. Extend this list by hand when a persistent control is
        // added; it is a list of known labels, not a definition of what a persistent control is.
        let persistentControls = [
            "Keep the Mac's input on my list",
            "Offer to start recording when another app uses microphone input",
            "Offer to stop after low audio activity",
            "Delete segments after assembly",
        ]
        let app = SourceConfinement.swiftFiles(under: SourceConfinement.sourcesRoot
            .appendingPathComponent("Acta"))
        for label in persistentControls {
            let homes = app.filter { file in
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { return false }
                return SourceConfinement.strippingComments(source).contains(label)
            }
            #expect(homes.count == 1,
                    Comment(rawValue: "\(label.debugDescription) has \(homes.count) editors: "
                            + homes.map(\.lastPathComponent).joined(separator: ", ")))
            #expect(homes.first?.lastPathComponent == "SettingsWindow.swift",
                    Comment(rawValue: "\(label.debugDescription) is edited in "
                            + (homes.first?.lastPathComponent ?? "nowhere")))
        }
    }

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

    /// The files allowed to name the HAL.
    ///
    /// ⚠️ **Widened on purpose, and the reason is written here rather than discovered later.** The
    /// device inventory is not the right owner of "which applications are using the microphone": that
    /// is a different question over different objects, and making one adapter answer both would tie the
    /// app-lifetime device inventory to a feature that can be switched off. So there are two adapters,
    /// each over one family of HAL objects — and still no third.
    private static let allowedAdapters: Set<String> = ["CoreAudioDeviceDirectory.swift",
                                                       "AudioProcessReader.swift"]

    /// ⚠️ **The process reader may only read.** The device adapter writes the Mac's default input,
    /// which is the one thing Acta changes outside itself; the reader answering "who is recording" has
    /// no business writing anything at all, and this is what keeps it that way.
    private static let readOnlyAdapters: Set<String> = ["AudioProcessReader.swift"]

    /// ⚠️ **The confinement Task 8 exists for.** Keeping the HAL in one file is what lets everything
    /// above it be tested without a sound card — and what stops a second CoreAudio directory being
    /// minted somewhere, which the app-lifetime ownership rule depends on.
    @Test("CoreAudio HAL symbols appear only in the adapter")
    func halSymbolsAreConfinedToTheAdapter() throws {
        var offenders: [String] = []
        for target in Self.productionTargets {
            let directory = SourceConfinement.sourcesRoot.appendingPathComponent(target)
            for file in SourceConfinement.swiftFiles(under: directory) {
                guard !Self.allowedAdapters.contains(file.lastPathComponent) else { continue }
                let symbols = SourceConfinement.halSymbols(in: try String(contentsOf: file, encoding: .utf8))
                if !symbols.isEmpty {
                    offenders.append("\(target)/\(file.lastPathComponent): \(symbols.joined(separator: ", "))")
                }
            }
        }
        let allowed = Self.allowedAdapters.sorted().joined(separator: " or ")
        let found = offenders.joined(separator: "; ")
        #expect(offenders.isEmpty, "the HAL must stay in \(allowed): \(found)")
    }

    /// The half that keeps the widening honest: a read-only adapter that starts writing HAL properties
    /// fails here rather than in a review.
    @Test("the process reader never writes a HAL property")
    func theProcessReaderIsReadOnly() throws {
        for name in Self.readOnlyAdapters {
            let file = SourceConfinement.sourcesRoot
                .appendingPathComponent("ActaRuntime").appendingPathComponent(name)
            let code = try String(contentsOf: file, encoding: .utf8)
            #expect(!SourceConfinement.halSymbols(in: code).contains("AudioObjectSetPropertyData"),
                    "\(name) must not write HAL properties")
        }
    }

    /// The adapter is where the HAL lives, so it had better name it — otherwise this whole suite could
    /// pass over a codebase that had quietly moved the HAL somewhere the scanner does not look.
    @Test("the adapter really is where the HAL lives")
    func theAdapterNamesTheHAL() throws {
        for name in Self.allowedAdapters {
            let adapter = SourceConfinement.sourcesRoot
                .appendingPathComponent("ActaRuntime").appendingPathComponent(name)
            let symbols = SourceConfinement.halSymbols(in: try String(contentsOf: adapter,
                                                                      encoding: .utf8))
            #expect(symbols.count >= 5, "\(name) names almost no HAL symbols — has the HAL moved?")
        }
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
