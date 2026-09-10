import Testing
import Foundation
import ActaControlProtocol

// The dependency-free wire protocol (Plan 1, Task 1): the Codable envelope + command/result/error
// algebra, the opaque recording id and the wire value types. All in-process, no socket — golden
// fixtures pin the wire shape. The framer lives in `ControlFramerTests`.

// MARK: - Helpers

/// Encode through the canonical codec and read the bytes back as a UTF-8 string, so a fixture can pin
/// the exact JSON (sorted keys, ISO-8601 dates).
private func jsonString<T: Encodable>(_ value: T) throws -> String {
    String(data: try ControlProtocolCodec.encode(value), encoding: .utf8)!
}

// MARK: - Opaque recording id

@Test
func recordingIDRoundTripsThroughBase64URL() {
    let name = "2026-07-17_14-30-00_Weekly sync"
    let id = RecordingID.make(directoryName: name)
    #expect(id.hasPrefix("v1:"))
    #expect(RecordingID.directoryName(fromID: id) == name)
}

@Test
func recordingIDUsesTheURLSafeAlphabet() {
    // `???>>>` is chosen because its UTF-8 bytes force both `+` and `/` in standard base64 ("Pz8/Pj4+").
    let id = RecordingID.make(directoryName: "???>>>")
    let body = String(id.dropFirst("v1:".count))
    #expect(!body.contains("+"))
    #expect(!body.contains("/"))
    #expect(RecordingID.directoryName(fromID: id) == "???>>>")
}

// Padding appears only when the input length is not a multiple of 3 — one `=` at 2 mod 3, two at 1 mod 3
// — so a length ≡ 0 pins nothing. Covering all three residues is what makes deleting the padding strip in
// `RecordingID.make` fail: the previous fixture here was 6 bytes, base64 emitted no `=` for it at all,
// and its `#expect(!body.contains("="))` passed whether or not the strip existed.
@Test(arguments: ["ab", "abc", "abcd"])
func recordingIDStripsBase64PaddingAtEveryLengthResidue(name: String) {
    let id = RecordingID.make(directoryName: name)
    #expect(!id.contains("="), "padding must be stripped for a \(name.utf8.count)-byte name")
    // The decoder has to re-add what `make` removed, or a stripped id would not survive the round trip.
    #expect(RecordingID.directoryName(fromID: id) == name)
}

@Test
func recordingIDRejectsAMalformedOrWrongPrefixID() {
    #expect(RecordingID.directoryName(fromID: "nope") == nil)
    #expect(RecordingID.directoryName(fromID: "v2:AAAA") == nil)
    // A "v1:" body that is not valid base64url.
    #expect(RecordingID.directoryName(fromID: "v1:!!!!") == nil)
}

// The bijection the type's doc promises is not free: `Data(base64Encoded:)` ignores the unused trailing
// bits, so every id below decodes to "A" and only the first is the one `make` mints. A round-trip test
// cannot see this — it only ever feeds back ids `make` produced — so the aliases are named explicitly.
@Test(arguments: ["v1:QR", "v1:QV", "v1:Qf"])
func recordingIDRejectsANonCanonicalEncodingOfANameItWouldOtherwiseResolve(alias: String) {
    // The canonical id for "A" resolves, which is what makes the aliases' rejection meaningful rather
    // than the decoder simply being broken for short names.
    #expect(RecordingID.directoryName(fromID: "v1:QQ") == "A")
    #expect(RecordingID.make(directoryName: "A") == "v1:QQ")
    // ...and the alias, which decodes to "A" byte-for-byte, is refused rather than aliasing onto it.
    #expect(RecordingID.directoryName(fromID: alias) == nil)
}

// MARK: - Command golden fixtures + custom decoding

@Test
func startCommandPinsItsDiscriminatorShape() throws {
    let req = WireRequest(id: "1", command: .start(title: "Standup"))
    #expect(try jsonString(req)
        == #"{"command":{"title":"Standup","type":"start"},"id":"1","version":2}"#)
}

@Test
func startWithoutATitleOmitsTheTitleKey() throws {
    #expect(try jsonString(WireRequest(id: "1", command: .start(title: nil)))
        == #"{"command":{"type":"start"},"id":"1","version":2}"#)
}

@Test
func voidCommandPinsItsShape() throws {
    #expect(try jsonString(WireRequest(id: "x", command: .stopAndWait))
        == #"{"command":{"type":"stop_and_wait"},"id":"x","version":2}"#)
}

@Test
func openInFinderCarriesTheOpaqueID() throws {
    #expect(try jsonString(WireRequest(id: "9", command: .openInFinder(id: "v1:AAAA")))
        == #"{"command":{"id":"v1:AAAA","type":"open_in_finder"},"id":"9","version":2}"#)
}

@Test
func everyCommandRoundTrips() throws {
    let commands: [Command] = [
        .status, .list, .watch, .start(title: "T"), .start(title: nil), .stop, .stopAndWait,
        .recover, .refresh, .openArchive, .openInFinder(id: "v1:AAAA"), .settingsGet,
        .settingsSet(WireSettings(archivePath: "~/x", segmentSeconds: 30, deleteSegmentsAfterAssembly: false,
                                microphonePriority: ["BuiltInMicrophoneDevice"],
                                managesSystemDefaultInput: false,
                                captureMicrophoneChoice: .followPriority)),
        .settingsSave, .titleGet, .titleSet("Hello"), .dismissRecoveryNotice
    ]
    for command in commands {
        let data = try ControlProtocolCodec.encode(WireRequest(id: "r", command: command))
        let decoded = try ControlProtocolCodec.decode(WireRequest.self, from: data)
        #expect(decoded.command == command)
    }
}

@Test
func anUnknownCommandTypeDecodesToUnsupportedCommandNotAThrow() throws {
    let data = Data(#"{"command":{"type":"teleport"},"id":"1","version":2}"#.utf8)
    let decoded = try ControlProtocolCodec.decode(WireRequest.self, from: data)
    #expect(decoded.command == .unsupportedCommand(raw: "teleport"))
}

@Test
func unknownKeysAreIgnored() throws {
    // An extra top-level key and an extra key inside the command are both dropped.
    let data = Data(#"{"command":{"type":"stop","future":true},"id":"1","version":2,"extra":42}"#.utf8)
    let decoded = try ControlProtocolCodec.decode(WireRequest.self, from: data)
    #expect(decoded.command == .stop)
    #expect(decoded.id == "1")
}

// MARK: - Result golden fixtures

@Test
func okResultPinsItsShape() throws {
    #expect(try jsonString(WireResponse.result(id: "1", .ok))
        == #"{"id":"1","result":{"type":"ok"},"version":2}"#)
}

@Test
func titleResultPinsItsShape() throws {
    #expect(try jsonString(WireResponse.result(id: "1", .title("Hi")))
        == #"{"id":"1","result":{"title":"Hi","type":"title"},"version":2}"#)
}

@Test
func everyResultRoundTrips() throws {
    let state = WireControlState(operation: .init(kind: .idle), title: "", suggestedTitle: "",
                                 settings: WireSettings(archivePath: "", segmentSeconds: 30,
                                                        deleteSegmentsAfterAssembly: true,
                                microphonePriority: ["BuiltInMicrophoneDevice"],
                                managesSystemDefaultInput: false,
                                captureMicrophoneChoice: .followPriority),
                                 recordings: [], canStart: true, canStop: false)
    let results: [CommandResult] = [
        .state(state),
        .recordings([RecordingSummary(id: "v1:AAAA", directoryName: "d", path: "/p", status: .unknown)]),
        .settings(WireSettings(archivePath: "~/a", segmentSeconds: 20, deleteSegmentsAfterAssembly: false,
                                microphonePriority: ["BuiltInMicrophoneDevice"],
                                managesSystemDefaultInput: false,
                                captureMicrophoneChoice: .followPriority)),
        .title("t"),
        .ok
    ]
    for result in results {
        let data = try ControlProtocolCodec.encode(WireResponse.result(id: "1", result))
        let decoded = try ControlProtocolCodec.decode(WireResponse.self, from: data)
        #expect(decoded.payload == .result(result))
    }
}

// MARK: - Error fixtures + round-trip

@Test
func commandRejectedErrorPinsItsCodeSpecificField() throws {
    #expect(try jsonString(WireResponse.error(id: "1", .commandRejected(reason: "busy")))
        == #"{"error":{"code":"command_rejected","message":"The command was rejected: busy","reason":"busy"},"id":"1","version":2}"#)
}

@Test
func everyDecodeOutcomeThatKeepsAnIDHasAnErrorCodeToAnswerItWith() throws {
    // The frozen set must cover what the decoder can actually produce. `.undecodableCommand` preserves
    // the id precisely so the transport can address a reply — this pins the code that reply carries, so
    // the transport cannot be pushed into blaming the server (`internal`, which invites a retry loop on
    // a malformed request) or the recorder's guard (`command_rejected`, which never saw the command).
    let outcome = ControlProtocolCodec.decodeRequest(from: Data(#"""
    {"version":2,"id":"7","command":{"type":"title_set"}}
    """#.utf8))
    guard case .undecodableCommand(let id, let reason) = outcome else {
        Issue.record("expected .undecodableCommand, got \(outcome)")
        return
    }
    #expect(id == "7")
    let json = try jsonString(WireResponse.error(id: id, .badRequest(reason: reason)))
    #expect(json.contains(#""code":"bad_request""#))
    #expect(json.contains(#""reason":"could not decode command""#))
    // The reason stays free of decoder internals — no coding paths, no debug prose.
    #expect(!json.contains("CodingKeys"))
}

@Test
func unsupportedVersionErrorCarriesTheSupportedVersions() throws {
    let json = try jsonString(WireResponse.error(id: "1", .unsupportedVersion(supportedVersions: [1])))
    #expect(json.contains(#""code":"unsupported_version""#))
    #expect(json.contains(#""supported_versions":[1]"#))
}

@Test
func everyErrorRoundTrips() throws {
    let errors: [WireError] = [
        .badRequest(reason: "could not decode command"),
        .commandRejected(reason: "busy"),
        .unknownRecording(id: "v1:AAAA"),
        .unsupportedCommand(raw: "teleport"),
        .unsupportedValue(field: "status", raw: "frozen"),
        .unsupportedVersion(supportedVersions: [1]),
        .notRecording(),
        .internalError()
    ]
    for error in errors {
        let data = try ControlProtocolCodec.encode(WireResponse.error(id: "1", error))
        let decoded = try ControlProtocolCodec.decode(WireResponse.self, from: data)
        #expect(decoded.payload == .error(error))
    }
}

// MARK: - Wire state / summary

@Test
func aRecordingWithoutAManifestOmitsTheOptionalFields() throws {
    let summary = RecordingSummary(id: "v1:AAAA", directoryName: "d", path: "/p", status: .unknown)
    #expect(try jsonString(summary)
        == #"{"directory_name":"d","id":"v1:AAAA","path":"/p","status":"unknown"}"#)
}

@Test
func aFullRecordingSummaryEncodesEveryFieldWithAnISO8601Date() throws {
    let started = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
    let summary = RecordingSummary(id: "v1:AAAA", directoryName: "d", path: "/p", status: .done,
                                   startedAt: started, segmentSeconds: 30, segmentCount: 4,
                                   assemblyAttempts: 1)
    let json = try jsonString(summary)
    #expect(json.contains(#""started_at":"2023-11-14T22:13:20Z""#))
    #expect(json.contains(#""segment_count":4"#))
    let decoded = try ControlProtocolCodec.decode(RecordingSummary.self, from: Data(json.utf8))
    #expect(decoded == summary)
}

@Test
func recordingOperationCarriesElapsedSecondsButIdleDoesNot() throws {
    #expect(try jsonString(WireControlState.Operation(kind: .recording, elapsedSeconds: 42))
        == #"{"elapsed_seconds":42,"kind":"recording"}"#)
    #expect(try jsonString(WireControlState.Operation(kind: .idle))
        == #"{"kind":"idle"}"#)
}

@Test
func wireControlStateRoundTripsWithFailuresAndNotices() throws {
    let state = WireControlState(
        operation: .init(kind: .saving),
        lifecycleFailure: .init(code: "assembly_failed", message: "Assembly failed."),
        notice: nil,
        recoveryNotice: .init(code: "recovered", message: "Recovered 2."),
        title: "Sync", suggestedTitle: "Meeting",
        settings: WireSettings(archivePath: "~/Acta", segmentSeconds: 30, deleteSegmentsAfterAssembly: true,
                                microphonePriority: ["BuiltInMicrophoneDevice"],
                                managesSystemDefaultInput: false,
                                captureMicrophoneChoice: .followPriority),
        recordings: [RecordingSummary(id: "v1:AAAA", directoryName: "d", path: "/p", status: .recovered)],
        canStart: false, canStop: false)
    let data = try ControlProtocolCodec.encode(state)
    #expect(try ControlProtocolCodec.decode(WireControlState.self, from: data) == state)
}

// MARK: - Watch event envelope

@Test
func watchEventEnvelopeCarriesSequenceAndState() throws {
    let state = WireControlState(operation: .init(kind: .idle), title: "", suggestedTitle: "",
                                 settings: WireSettings(archivePath: "", segmentSeconds: 30,
                                                        deleteSegmentsAfterAssembly: true,
                                microphonePriority: ["BuiltInMicrophoneDevice"],
                                managesSystemDefaultInput: false,
                                captureMicrophoneChoice: .followPriority),
                                 recordings: [], canStart: true, canStop: false)
    let event = WireEvent(id: "sub", event: WatchEvent(sequence: 7, state: state))
    let data = try ControlProtocolCodec.encode(event)
    let decoded = try ControlProtocolCodec.decode(WireEvent.self, from: data)
    #expect(decoded == event)
    #expect(decoded.event.sequence == 7)
}

// MARK: - Version policy

@Test
func aCurrentVersionRequestDecodesToRequest() {
    let data = Data(#"{"command":{"type":"status"},"id":"1","version":2}"#.utf8)
    guard case .request(let req) = ControlProtocolCodec.decodeRequest(from: data) else {
        Issue.record("expected .request"); return
    }
    #expect(req.command == .status)
}

@Test
func aVersionMismatchIsReportedWithItsIDPreserved() {
    // Even a command shape newer than the current version must still yield the id, so the header is
    // read first.
    let data = Data(#"{"command":{"type":"future","payload":{}},"id":"abc","version":3}"#.utf8)
    #expect(ControlProtocolCodec.decodeRequest(from: data) == .versionMismatch(id: "abc", requested: 3))
}

@Test
func nonEnvelopeBytesAreMalformed() {
    guard case .malformed = ControlProtocolCodec.decodeRequest(from: Data("not json".utf8)) else {
        Issue.record("expected .malformed"); return
    }
}

// A known command tag with a bad payload — the ordinary client bug. The envelope decoded, so the id is
// in hand and the reply can be addressed; answering `.malformed` here would strand the request on a
// socket carrying several at once.
@Test(arguments: [#"{"command":{"type":"title_set"},"id":"7","version":2}"#,
                  #"{"command":{"type":"open_in_finder"},"id":"7","version":2}"#])
func aV1EnvelopeWithAnUndecodableCommandKeepsItsID(json: String) {
    guard case .undecodableCommand(let id, _) = ControlProtocolCodec.decodeRequest(from: Data(json.utf8))
    else {
        Issue.record("expected .undecodableCommand for \(json)"); return
    }
    #expect(id == "7")
}

@Test
func anUndecodableCommandReasonDoesNotLeakDecoderInternals() {
    let data = Data(#"{"command":{"type":"title_set"},"id":"7","version":2}"#.utf8)
    guard case .undecodableCommand(_, let reason) = ControlProtocolCodec.decodeRequest(from: data) else {
        Issue.record("expected .undecodableCommand"); return
    }
    // A raw `DecodingError` description carries coding paths and debug prose; a client gets a stable
    // reason instead.
    #expect(!reason.contains("CodingKeys"))
    #expect(!reason.contains("debugDescription"))
}

// MARK: - Response envelope decoding

@Test
func aResponseCarryingNeitherAResultNorAnErrorIsRejected() {
    // The shape an older client meets when a server is broken — exactly when a clear error matters.
    let data = Data(#"{"id":"1","version":2}"#.utf8)
    #expect(throws: (any Error).self) {
        try ControlProtocolCodec.decode(WireResponse.self, from: data)
    }
}

// The twin of the case above, and the one that actually bites: "never both" was prose the decoder did not
// enforce. Checking `result` first and returning on the first hit renders a server's error as `ok` — a
// client told its command succeeded when the same payload carried the failure.
@Test
func aResponseCarryingBothAResultAndAnErrorIsRejectedRatherThanReadAsSuccess() {
    let data = Data(#"""
    {"id":"1","version":2,"result":{"type":"ok"},"error":{"code":"internal","message":"boom"}}
    """#.utf8)
    #expect(throws: (any Error).self) {
        try ControlProtocolCodec.decode(WireResponse.self, from: data)
    }
}

// The exact-version rule (see `ProtocolVersion`) holds on responses/events too, not just requests: both
// check `version` before the payload.
//
// ⚠️ **Both payloads are otherwise valid, and that is what makes this test mean anything.** The event
// half used to carry `{"event":{}}`, which throws for being an undecodable `WatchEvent` whatever the
// version says — delete the version check entirely and it still passed. A payload that would decode
// cleanly at the current version isolates the rule under test.
@Test
func aNonCurrentVersionIsRejectedOnBothResponseAndEvent() throws {
    // Built by encoding real values, so "otherwise valid" is a fact rather than a claim about a
    // hand-written string.
    let response = try ControlProtocolCodec.encode(WireResponse(id: "1", payload: .result(.ok)))
    let event = try ControlProtocolCodec.encode(
        WireEvent(id: "sub", event: WatchEvent(sequence: 1, state: minimalWireState))
    )

    // Both decode at the current version — this is what stops the test from passing for the wrong
    // reason. The event half used to carry `{"event":{}}`, which throws for being an undecodable
    // `WatchEvent` whatever the version says: delete the version check entirely and it still passed.
    #expect(throws: Never.self) { try ControlProtocolCodec.decode(WireResponse.self, from: response) }
    #expect(throws: Never.self) { try ControlProtocolCodec.decode(WireEvent.self, from: event) }

    // Now nothing differs but the version.
    #expect(throws: (any Error).self) {
        try ControlProtocolCodec.decode(WireResponse.self, from: withVersion(3, response))
    }
    #expect(throws: (any Error).self) {
        try ControlProtocolCodec.decode(WireEvent.self, from: withVersion(3, event))
    }
}

/// A `WireControlState` with nothing interesting in it — enough to make an envelope decodable.
private let minimalWireState = WireControlState(
    operation: .init(kind: .idle),
    lifecycleFailure: nil, notice: nil, recoveryNotice: nil,
    title: "", suggestedTitle: "",
    settings: WireSettings(archivePath: "", segmentSeconds: 30, deleteSegmentsAfterAssembly: true,
                           microphonePriority: [], managesSystemDefaultInput: false,
                           captureMicrophoneChoice: .followPriority),
    recordings: [], canStart: true, canStop: false)

/// Rewrite only the `version` field of an encoded envelope.
private func withVersion(_ version: Int, _ data: Data) -> Data {
    let text = String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "\"version\":\(ProtocolVersion.current)",
                              with: "\"version\":\(version)")
    return Data(text.utf8)
}

// MARK: - The dependency confinement

@Test
func controlProtocolSourcesImportOnlyFoundation() throws {
    // Structural isolation is enforced by Package.swift (no package dependency); this guards the other
    // half — an `import AppKit` compiles without any package dep at all.
    //
    // ⚠️ An **allowlist**, deliberately: a denylist of known-bad modules passes `import Darwin`, and the
    // framer is exactly where someone reaches for it (its `EINTR` note is out of scope for that reason).
    // Read `^import` lines rather than substrings, so a doc comment naming AppKit does not fail a build.
    //
    // ⚠️ **Recursive, and anchored to `#filePath` rather than the cwd.** `contentsOfDirectory` reads one
    // level, so a file under `ActaControlProtocol/Sub/` would clear both halves of the invariant while
    // importing anything it liked — `Darwin` and `AppKit` need no package dependency, which is the whole
    // reason this test exists alongside the package graph. And a relative path makes the guard a claim
    // about the runner's working directory: this suite is the only thing standing behind the rule, so it
    // resolves the target from its own source location instead.
    // ⚠️ **The reader is shared with the CoreAudio guard now, and this one had the hole.** It matched
    // `trimmed.hasPrefix("import ")`, so `@preconcurrency import AppKit` under `ActaControlProtocol/`
    // would have **passed** it — and that form is in use elsewhere in this codebase, so the hole was
    // reachable rather than theoretical. `SourceConfinementTests` drives the reader against fixtures.
    let root = SourceConfinement.sourcesRoot.appendingPathComponent("ActaControlProtocol")
    let files = SourceConfinement.swiftFiles(under: root)
    #expect(!files.isEmpty)
    for file in files {
        let imported = SourceConfinement.importedModules(in: try String(contentsOf: file, encoding: .utf8))
        #expect(Set(imported) == ["Foundation"],
                "\(file.lastPathComponent) must import Foundation and nothing else, got \(imported)")
    }
}
