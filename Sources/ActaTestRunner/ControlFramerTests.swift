import Testing
import Foundation
import ActaControlProtocol

// The JSON-lines framer (Plan 1, Task 1): payload + LF, directional size limits, driven through an
// injected byte source and sink. Split out of `ControlProtocolTests` — which pins the wire *shape* —
// because the two grew past the 400-line file limit together; the framer moves bytes, not schema.

// MARK: - Helpers

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

/// A sink that claims to have written more than it was handed — the mirror of a source that
/// over-delivers, which `FrameReader` already defends against.
private final class OverReportingWriter: ByteWriting {
    func write(_ data: Data) throws -> Int { data.count + 1 }
}

private func frame(_ s: String) -> Data { Data((s + "\n").utf8) }

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
func aFramingFailureIsStickyAndDoesNotResumeAtTheNextFrame() {
    // Two complete frames, the first over-limit. `takeFrame` removes a frame before validating it, so
    // without the latch the second `next()` would hand back "ok" — the reader silently skipping a frame
    // and resuming, which is exactly what `oversizedFrame` documents as not happening.
    var reader = FrameReader(reader: ScriptedReader([Data("xxxxxxxxx\nok\n".utf8)]), maxPayloadBytes: 8)
    #expect(throws: FramingError.oversizedFrame(limit: 8)) { try reader.next() }
    #expect(throws: FramingError.oversizedFrame(limit: 8)) { try reader.next() }
}

@Test
func anEmptyLineFailureIsStickyToo() {
    var reader = FrameReader(reader: ScriptedReader([Data("\nok\n".utf8)]),
                             maxPayloadBytes: FramingLimits.maxRequestPayloadBytes)
    #expect(throws: FramingError.emptyLine) { try reader.next() }
    #expect(throws: FramingError.emptyLine) { try reader.next() }
}

@Test
func writerLoopsOverShortWrites() throws {
    let sink = CollectingWriter()
    sink.chunkLimit = 1 // one byte per write call
    let writer = FrameWriter(writer: sink, maxPayloadBytes: FramingLimits.maxResponsePayloadBytes)
    try writer.write(payload: Data("hello".utf8))
    #expect(sink.written == Data("hello\n".utf8))
}

@Test
func writerFailsWhenTheSinkMakesNoProgress() {
    // The only thing between a sink returning 0 and an infinite write loop in a process that must stay
    // up for the length of a recording.
    let sink = CollectingWriter()
    sink.chunkLimit = 0
    let writer = FrameWriter(writer: sink, maxPayloadBytes: FramingLimits.maxResponsePayloadBytes)
    #expect(throws: FramingError.writeStalled) { try writer.write(payload: Data("hello".utf8)) }
}

@Test
func writerFailsWhenTheSinkOverReportsRatherThanRunningPastTheFrame() {
    // Trusting the count would push `offset` past the end and exit the loop as if the frame had landed.
    let writer = FrameWriter(writer: OverReportingWriter(),
                             maxPayloadBytes: FramingLimits.maxResponsePayloadBytes)
    #expect(throws: FramingError.writeStalled) { try writer.write(payload: Data("hello".utf8)) }
}

@Test
func writerRejectsTheTwoFramesItsReaderWouldReject() {
    let sink = CollectingWriter()
    let writer = FrameWriter(writer: sink, maxPayloadBytes: 8)
    // A bare LF is fatal to the reader, so the writer must not be able to emit one.
    #expect(throws: FramingError.emptyLine) { try writer.write(payload: Data()) }
    #expect(throws: FramingError.oversizedFrame(limit: 8)) {
        try writer.write(payload: Data("xxxxxxxxx".utf8))
    }
    #expect(sink.written.isEmpty, "a rejected frame must not put bytes on the wire")
}

@Test
func writerAcceptsAPayloadExactlyAtTheLimit() throws {
    let sink = CollectingWriter()
    try FrameWriter(writer: sink, maxPayloadBytes: 8).write(payload: Data("xxxxxxxx".utf8))
    #expect(sink.written == Data("xxxxxxxx\n".utf8))
}

@Test
func writerThenReaderRoundTripAFrame() throws {
    let sink = CollectingWriter()
    try FrameWriter(writer: sink, maxPayloadBytes: FramingLimits.maxResponsePayloadBytes)
        .write(payload: Data(#"{"type":"ok"}"#.utf8))
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
