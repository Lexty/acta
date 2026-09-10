import Foundation

/// Reading Swift source well enough to guard a confinement — and no better.
///
/// ⚠️ **The parser is the thing under test here, not just a helper.** A confinement guard is only worth
/// what its reader is worth: the one that shipped before this matched `trimmed.hasPrefix("import ")`,
/// so `@preconcurrency import AppKit` was invisible to it — and `SCKCaptureSource.swift:5` proves that
/// form is in use in this codebase. A guard with a hole in its reader is worse than no guard, because
/// it is believed. `SourceConfinementTests` drives the functions below against fixtures for exactly
/// that reason.
enum SourceConfinement {
    /// Source with comments removed, so a doc comment naming a module or an API cannot trip a guard —
    /// and, more importantly, cannot be used to hide one.
    ///
    /// ⚠️ **Stated limits.** It removes `//` to end of line and `/* … */` including nesting, and it does
    /// **not** understand string literals: `"// not a comment"` is treated as one. That is acceptable
    /// here — the guards look for imports and HAL identifiers, neither of which is meaningful inside a
    /// string — and it is written down rather than discovered.
    static func strippingComments(_ source: String) -> String {
        var output = ""
        var depth = 0
        var index = source.startIndex
        while index < source.endIndex {
            let rest = source[index...]
            if depth == 0, rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                continue
            }
            if rest.hasPrefix("/*") {
                depth += 1
                index = source.index(index, offsetBy: 2)
                continue
            }
            if depth > 0, rest.hasPrefix("*/") {
                depth -= 1
                index = source.index(index, offsetBy: 2)
                continue
            }
            if depth == 0 { output.append(source[index]) }
            else if source[index] == "\n" { output.append("\n") }
            index = source.index(after: index)
        }
        return output
    }

    /// Every module imported by this source.
    ///
    /// Handles what this codebase actually writes: a bare `import X`, an attributed
    /// `@preconcurrency import X`, and a member import `import struct Foundation.Data`.
    static func importedModules(in source: String) -> [String] {
        strippingComments(source).split(separator: "\n").compactMap { line -> String? in
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            // ⚠️ Attributes are stripped before the prefix test, which is the hole this closes.
            while trimmed.hasPrefix("@") {
                guard let space = trimmed.firstIndex(of: " ") else { return nil }
                trimmed = String(trimmed[trimmed.index(after: space)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            guard trimmed.hasPrefix("import ") else { return nil }
            let rest = trimmed.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
            let kinds = ["struct", "class", "enum", "protocol", "typealias", "func", "var", "let"]
            let words = rest.split(separator: " ").map(String.init)
            let module = kinds.contains(words.first ?? "") ? words.dropFirst().first ?? "" : words.first ?? ""
            return module.split(separator: ".").first.map(String.init)
        }
    }

    /// The CoreAudio HAL identifiers a file may not name.
    ///
    /// ⚠️ **Symbol use, not imports**, because a transitive framework import exposes these with no
    /// `import CoreAudio` line at all — `AVFoundation` alone is enough.
    ///
    /// ⚠️ **Deliberately narrow.** It guards the *hardware abstraction layer* — the object/property API
    /// and its constants — and nothing else. `CMSampleBuffer`, `AudioBufferList`,
    /// `AudioStreamBasicDescription` and the rest of the audio buffer types belong to the writer and the
    /// capture path and are none of this rule's business; forbidding a type for belonging to an audio
    /// framework would make the guard something people route around instead of keep.
    static let halIdentifiers = [
        "AudioObjectGetPropertyData",
        "AudioObjectSetPropertyData",
        "AudioObjectGetPropertyDataSize",
        "AudioObjectHasProperty",
        "AudioObjectAddPropertyListenerBlock",
        "AudioObjectRemovePropertyListenerBlock",
        "AudioObjectPropertyAddress",
        "AudioObjectID",
        "AudioDeviceID",
        "kAudioHardware",
        "kAudioDevice",
        "kAudioObject",
    ]

    /// HAL identifiers named in this source, comments excluded.
    static func halSymbols(in source: String) -> [String] {
        let code = strippingComments(source)
        return halIdentifiers.filter { code.contains($0) }
    }

    /// The repository's `Sources` directory, resolved from this file rather than the working directory.
    ///
    /// ⚠️ A relative path would make every guard below a claim about where the runner happens to be
    /// started from — and these suites are the only thing standing behind the rules.
    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Sources/ActaTestRunner
            .deletingLastPathComponent()   // …/Sources
    }

    /// Every Swift file under `directory`, recursively.
    ///
    /// ⚠️ Recursive on purpose: `contentsOfDirectory` reads one level, so a file in a subdirectory would
    /// clear a guard while doing whatever it liked.
    static func swiftFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
