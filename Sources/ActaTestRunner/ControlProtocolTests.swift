import Testing
import Foundation
import ActaControlProtocol

// The dependency-free wire protocol (Plan 1, Task 1): the Codable envelope + command/result/error
// algebra, the opaque recording id, the wire value types, and the JSON-lines framer. All in-process,
// no socket — golden fixtures pin the wire shape, and an injected reader/writer drives the framer.

// MARK: - Helpers

/// Encode through the canonical codec and read the bytes back as a UTF-8 string, so a fixture can pin
/// the exact JSON (sorted keys, ISO-8601 dates).
private func jsonString<T: Encodable>(_ value: T) throws -> String {
    String(data: try ControlProtocolCodec.encode(value), encoding: .utf8)!
}

/// A `ByteReading` that hands back scripted chunks in order, then an empty `Data` at EOF. It ignores
/// `maxBytes` on purpose — that is how a reader "returning a larger chunk than asked" is exercised.
private final class ScriptedReader: ByteReading {
    private var chunks: [Data]
    init(_ chunks: [Data]) { self.chunks = chunks }
    func read(maxBytes: Int) throws -> Data {
        guard !chunks.isEmpty else { return Data() }
        return chunks.removeFirst()
    }
}

/// A `ByteWriting` that records everything written and can be told to accept only `chunkLimit` bytes per
/// call — the short-write simulation.
private final class CollectingWriter: ByteWriting {
    private(set) var written = Data()
    var chunkLimit: Int?
    func write(_ data: Data) throws -> Int {
        let n = chunkLimit.map { min($0, data.count) } ?? data.count
        written.append(data.prefix(n))
        return n
    }
}

private func frame(_ s: String) -> Data { Data((s + "\n").utf8) }

// MARK: - Opaque recording id

@Test
func recordingIDRoundTripsThroughBase64URL() {
    let name = "2026-07-17_14-30-00_Weekly sync"
    let id = RecordingID.make(directoryName: name)
    #expect(id.hasPrefix("v1:"))
    #expect(RecordingID.directoryName(fromID: id) == name)
}

@Test
func recordingIDUsesURLSafeAlphabetWithNoPadding() {
    // A name whose UTF-8 bytes force `+`/`/` and `=` padding in standard base64, so the URL-safe
    // substitution and the stripped padding are actually observed.
    let id = RecordingID.make(directoryName: "???>>>")
    let body = String(id.dropFirst("v1:".count))
    #expect(!body.contains("+"))
    #expect(!body.contains("/"))
    #expect(!body.contains("="))
    #expect(RecordingID.directoryName(fromID: id) == "???>>>")
}

@Test
func recordingIDRejectsAMalformedOrWrongPrefixID() {
    #expect(RecordingID.directoryName(fromID: "nope") == nil)
    #expect(RecordingID.directoryName(fromID: "v2:AAAA") == nil)
    // A "v1:" body that is not valid base64url.
    #expect(RecordingID.directoryName(fromID: "v1:!!!!") == nil)
}

// MARK: - Command golden fixtures + custom decoding

@Test
func startCommandPinsItsDiscriminatorShape() throws {
    let req = WireRequest(id: "1", command: .start(title: "Standup"))
    #expect(try jsonString(req)
        == #"{"command":{"title":"Standup","type":"start"},"id":"1","version":1}"#)
}

@Test
func startWithoutATitleOmitsTheTitleKey() throws {
    #expect(try jsonString(WireRequest(id: "1", command: .start(title: nil)))
        == #"{"command":{"type":"start"},"id":"1","version":1}"#)
}

@Test
func voidCommandPinsItsShape() throws {
    #expect(try jsonString(WireRequest(id: "x", command: .stopAndWait))
        == #"{"command":{"type":"stop_and_wait"},"id":"x","version":1}"#)
}

@Test
func openInFinderCarriesTheOpaqueID() throws {
    #expect(try jsonString(WireRequest(id: "9", command: .openInFinder(id: "v1:AAAA")))
        == #"{"command":{"id":"v1:AAAA","type":"open_in_finder"},"id":"9","version":1}"#)
}

@Test
func everyCommandRoundTrips() throws {
    let commands: [Command] = [
        .status, .list, .watch, .start(title: "T"), .start(title: nil), .stop, .stopAndWait,
        .recover, .refresh, .openArchive, .openInFinder(id: "v1:AAAA"), .settingsGet,
        .settingsSet(WireSettings(archivePath: "~/x", segmentSeconds: 30, deleteSegmentsAfterAssembly: false)),
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
    let data = Data(#"{"command":{"type":"teleport"},"id":"1","version":1}"#.utf8)
    let decoded = try ControlProtocolCodec.decode(WireRequest.self, from: data)
    #expect(decoded.command == .unsupportedCommand(raw: "teleport"))
}

@Test
func unknownKeysAreIgnored() throws {
    // An extra top-level key and an extra key inside the command are both dropped.
    let data = Data(#"{"command":{"type":"stop","future":true},"id":"1","version":1,"extra":42}"#.utf8)
    let decoded = try ControlProtocolCodec.decode(WireRequest.self, from: data)
    #expect(decoded.command == .stop)
    #expect(decoded.id == "1")
}

// MARK: - Result golden fixtures

@Test
func okResultPinsItsShape() throws {
    #expect(try jsonString(WireResponse.result(id: "1", .ok))
        == #"{"id":"1","result":{"type":"ok"},"version":1}"#)
}

@Test
func titleResultPinsItsShape() throws {
    #expect(try jsonString(WireResponse.result(id: "1", .title("Hi")))
        == #"{"id":"1","result":{"title":"Hi","type":"title"},"version":1}"#)
}

@Test
func everyResultRoundTrips() throws {
    let state = WireControlState(operation: .init(kind: .idle), title: "", suggestedTitle: "",
                                 settings: WireSettings(archivePath: "", segmentSeconds: 30,
                                                        deleteSegmentsAfterAssembly: true),
                                 recordings: [], canStart: true, canStop: false)
    let results: [CommandResult] = [
        .state(state),
        .recordings([RecordingSummary(id: "v1:AAAA", directoryName: "d", path: "/p", status: .unknown)]),
        .settings(WireSettings(archivePath: "~/a", segmentSeconds: 20, deleteSegmentsAfterAssembly: false)),
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
        == #"{"error":{"code":"command_rejected","message":"The command was rejected: busy","reason":"busy"},"id":"1","version":1}"#)
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
        settings: WireSettings(archivePath: "~/Acta", segmentSeconds: 30, deleteSegmentsAfterAssembly: true),
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
                                                        deleteSegmentsAfterAssembly: true),
                                 recordings: [], canStart: true, canStop: false)
    let event = WireEvent(id: "sub", event: WatchEvent(sequence: 7, state: state))
    let data = try ControlProtocolCodec.encode(event)
    let decoded = try ControlProtocolCodec.decode(WireEvent.self, from: data)
    #expect(decoded == event)
    #expect(decoded.event.sequence == 7)
}

// MARK: - Version policy

@Test
func aV1RequestDecodesToRequest() {
    let data = Data(#"{"command":{"type":"status"},"id":"1","version":1}"#.utf8)
    guard case .request(let req) = ControlProtocolCodec.decodeRequest(from: data) else {
        Issue.record("expected .request"); return
    }
    #expect(req.command == .status)
}

@Test
func aVersionMismatchIsReportedWithItsIDPreserved() {
    // Even a command shape newer than v1 must still yield the id, so the header is read first.
    let data = Data(#"{"command":{"type":"future","payload":{}},"id":"abc","version":2}"#.utf8)
    #expect(ControlProtocolCodec.decodeRequest(from: data) == .versionMismatch(id: "abc", requested: 2))
}

@Test
func nonEnvelopeBytesAreMalformed() {
    guard case .malformed = ControlProtocolCodec.decodeRequest(from: Data("not json".utf8)) else {
        Issue.record("expected .malformed"); return
    }
}

// MARK: - The JSON-lines framer

@Test
func framerReadsOneFramePerLine() throws {
    var reader = FrameReader(reader: ScriptedReader([frame("hello"), frame("world")]),
                             maxPayloadBytes: FramingLimits.maxRequestPayloadBytes)
    #expect(try reader.next() == Data("hello".utf8))
    #expect(try reader.next() == Data("world".utf8))
    #expect(try reader.next() == nil)
}

@Test
func framerHandlesMultipleFramesInOneRead() throws {
    var reader = FrameReader(reader: ScriptedReader([Data("a\nbb\nccc\n".utf8)]),
                             maxPayloadBytes: FramingLimits.maxRequestPayloadBytes)
    #expect(try reader.next() == Data("a".utf8))
    #expect(try reader.next() == Data("bb".utf8))
    #expect(try reader.next() == Data("ccc".utf8))
    #expect(try reader.next() == nil)
}

@Test
func framerReassemblesAFrameAndItsNewlineSplitAcrossReads() throws {
    // The payload is fragmented AND the terminating LF arrives in a later read than its payload.
    var reader = FrameReader(reader: ScriptedReader([Data("hel".utf8), Data("lo".utf8), Data("\n".utf8)]),
                             maxPayloadBytes: FramingLimits.maxRequestPayloadBytes)
    #expect(try reader.next() == Data("hello".utf8))
    #expect(try reader.next() == nil)
}

@Test
func framerRejectsAnEmptyLine() {
    var reader = FrameReader(reader: ScriptedReader([Data("\n".utf8)]),
                             maxPayloadBytes: FramingLimits.maxRequestPayloadBytes)
    #expect(throws: FramingError.emptyLine) { try reader.next() }
}

@Test
func framerRejectsATruncatedFrameAtEOF() {
    var reader = FrameReader(reader: ScriptedReader([Data("abc".utf8)]),
                             maxPayloadBytes: FramingLimits.maxRequestPayloadBytes)
    #expect(throws: FramingError.truncatedFrame) { try reader.next() }
}

@Test
func framerAcceptsAPayloadExactlyAtTheLimit() throws {
    let payload = String(repeating: "x", count: 8)
    var reader = FrameReader(reader: ScriptedReader([frame(payload)]), maxPayloadBytes: 8)
    #expect(try reader.next() == Data(payload.utf8))
}

@Test
func framerFailsImmediatelyOnAnOverLimitFrame() {
    // Nine payload bytes against a limit of eight — rejected the moment the buffer passes the limit,
    // without discarding to the next LF.
    var reader = FrameReader(reader: ScriptedReader([frame("xxxxxxxxx")]), maxPayloadBytes: 8)
    #expect(throws: FramingError.oversizedFrame(limit: 8)) { try reader.next() }
}

@Test
func framerFailsOnAnOverLimitTailEvenBeforeItsNewlineArrives() {
    // No LF yet, but the buffer already exceeds the limit: fail now rather than read on forever.
    var reader = FrameReader(reader: ScriptedReader([Data("xxxxxxxxx".utf8)]), maxPayloadBytes: 8)
    #expect(throws: FramingError.oversizedFrame(limit: 8)) { try reader.next() }
}

@Test
func framerBuffersAReaderThatOverDeliversWithoutLosingBytes() throws {
    // The reader ignores `maxBytes` and dumps a chunk larger than the read-chunk cap; the framer must
    // buffer all of it, not slice-and-drop.
    let big = Data(String(repeating: "z", count: 200_000).utf8)
    var reader = FrameReader(reader: ScriptedReader([big + Data("\n".utf8)]),
                             maxPayloadBytes: 1_048_576,
                             maxReadChunkBytes: 4096)
    #expect(try reader.next() == big)
}

@Test
func writerLoopsOverShortWrites() throws {
    let sink = CollectingWriter()
    sink.chunkLimit = 1 // one byte per write call
    let writer = FrameWriter(writer: sink)
    try writer.write(payload: Data("hello".utf8))
    #expect(sink.written == Data("hello\n".utf8))
}

@Test
func writerThenReaderRoundTripAFrame() throws {
    let sink = CollectingWriter()
    try FrameWriter(writer: sink).write(payload: Data(#"{"type":"ok"}"#.utf8))
    var reader = FrameReader(reader: ScriptedReader([sink.written]),
                             maxPayloadBytes: FramingLimits.maxResponsePayloadBytes)
    #expect(try reader.next() == Data(#"{"type":"ok"}"#.utf8))
}

@Test
func framingLimitsAreTheFrozenDirectionalConstants() {
    #expect(FramingLimits.maxRequestPayloadBytes == 65536)
    #expect(FramingLimits.maxResponsePayloadBytes == 1_048_576)
    #expect(FramingLimits.maxReadChunkBytes == 65536)
}

@Test
func controlProtocolSourcesImportOnlyFoundation() throws {
    // Structural isolation is enforced by Package.swift (no package dependency); this guards the other
    // half — no AppKit/SwiftUI/runtime imports, which compile even without a package dep.
    let dir = "Sources/ActaControlProtocol"
    let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".swift") }
    #expect(!files.isEmpty)
    let forbidden = ["import AppKit", "import SwiftUI", "import ActaKit", "import ActaRuntime",
                     "import ScreenCaptureKit", "import Combine"]
    for file in files {
        let text = try String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)
        for token in forbidden {
            #expect(!text.contains(token), "\(file) must not contain '\(token)'")
        }
    }
}
