import Foundation

/// Byte-source injected into `FrameReader`. `read(maxBytes:)` returns up to `maxBytes` bytes, or an
/// **empty** `Data` at end of input. A well-behaved source returns at most `maxBytes`; the reader
/// defends against one that returns more.
///
/// ⚠️ **`EINTR` and other POSIX syscall behaviour are out of scope here** — a pure framer tested against
/// an injected reader cannot honestly cover them. They belong to Plan 2's descriptor adapter, which is
/// the only place that touches real syscalls.
public protocol ByteReading {
    func read(maxBytes: Int) throws -> Data
}

/// Byte-sink injected into `FrameWriter`. `write(_:)` returns the number of bytes actually written,
/// which may be **fewer** than offered (a short write); the writer loops until the whole frame lands.
public protocol ByteWriting {
    func write(_ data: Data) throws -> Int
}

/// The frozen size limits of the JSON-lines protocol. **Directional and exact**, measured as buffered
/// **payload bytes excluding the terminating `LF`**.
public enum FramingLimits {
    /// The request-direction payload limit: 64 KiB.
    public static let maxRequestPayloadBytes = 65536
    /// The response-direction payload limit: 1 MiB.
    public static let maxResponsePayloadBytes = 1_048_576
    /// The maximum bytes requested from the reader in one call: 64 KiB. A reader returning more is
    /// tolerated (the extra is buffered, never dropped), not trusted.
    public static let maxReadChunkBytes = 65536
}

/// The line feed that terminates every frame.
private let lineFeed: UInt8 = 0x0A

public enum FramingError: Error, Equatable, Sendable {
    /// A frame's payload exceeded the directional limit; the stream is failed immediately (a control
    /// socket has no reason to skip a frame and resume).
    case oversizedFrame(limit: Int)
    /// EOF arrived with a non-empty, unterminated tail in the buffer — a truncated frame.
    case truncatedFrame
    /// An empty line (a bare `LF` with no payload) is not a valid frame.
    case emptyLine
    /// A write sink made no progress (returned a non-positive count), so the frame cannot be delivered.
    case writeStalled
}

/// Reads length-delimited JSON frames — one UTF-8 JSON object then exactly one `LF` — from an injected
/// byte source. Handles a newline that spans reads, several frames in one read, and a reader that
/// over-delivers; fails immediately on an over-limit frame and reports a truncated tail at EOF.
///
/// ⚠️ **A framing failure is terminal and sticky.** Once `next()` has thrown a `FramingError`, every
/// later `next()` re-throws the same error rather than resuming at the following frame. The alternative
/// is worse than it looks: `takeFrame` removes the offending frame *before* validating it, so without
/// the latch an over-limit frame would be silently discarded and the *next* frame returned — precisely
/// the "skip a frame and resume" behaviour `oversizedFrame` documents as not happening. That also kept
/// the error honest in only half the cases: an over-limit tail whose `LF` had not arrived yet is caught
/// by the buffer check, which drains nothing and so re-threw, while the same violation with its `LF`
/// present did not — one error value meaning two different things. Errors thrown by the *source* are not
/// latched: those are the transport's to interpret, not the framing's.
public struct FrameReader {
    private var buffer = Data()
    private var reachedEOF = false
    private var failure: FramingError?
    private let reader: ByteReading
    private let maxPayloadBytes: Int
    private let maxReadChunkBytes: Int

    public init(reader: ByteReading,
                maxPayloadBytes: Int,
                maxReadChunkBytes: Int = FramingLimits.maxReadChunkBytes) {
        self.reader = reader
        self.maxPayloadBytes = maxPayloadBytes
        self.maxReadChunkBytes = maxReadChunkBytes
    }

    /// The next frame's payload (the bytes before its `LF`), `nil` at a clean EOF (no partial tail).
    ///
    /// Throws `oversizedFrame` the moment the buffered bytes cannot fit the limit, `emptyLine` for a
    /// bare `LF`, and `truncatedFrame` when EOF leaves a non-empty unterminated tail. Any of the three
    /// fails the reader for good: every later call re-throws it.
    public mutating func next() throws -> Data? {
        if let failure { throw failure }
        do {
            return try nextFrame()
        } catch let error as FramingError {
            failure = error
            throw error
        }
    }

    private mutating func nextFrame() throws -> Data? {
        while true {
            if let frame = try takeFrame() {
                return frame
            }
            // No complete frame buffered. A buffer already past the limit can never become a legal
            // frame — even the next byte being `LF` would yield an over-limit payload — so fail now
            // rather than read more.
            if buffer.count > maxPayloadBytes {
                throw FramingError.oversizedFrame(limit: maxPayloadBytes)
            }
            if reachedEOF {
                if buffer.isEmpty {
                    return nil
                }
                throw FramingError.truncatedFrame
            }
            let chunk = try reader.read(maxBytes: maxReadChunkBytes)
            if chunk.isEmpty {
                reachedEOF = true
            } else {
                // Buffer the whole chunk. A source that returned more than `maxReadChunkBytes` does not
                // get its excess dropped — that would corrupt the stream; the limit check above bounds
                // memory instead.
                buffer.append(chunk)
            }
        }
    }

    /// Split off the first complete frame in the buffer, if any. Validates the size and emptiness of the
    /// frame it removes.
    private mutating func takeFrame() throws -> Data? {
        guard let lfIndex = buffer.firstIndex(of: lineFeed) else { return nil }
        // `buffer` may not be zero-based after earlier removals; work in offsets from `startIndex`.
        let payloadLength = buffer.distance(from: buffer.startIndex, to: lfIndex)
        let payload = buffer.subdata(in: buffer.startIndex..<lfIndex)
        // Drop the payload and its terminating LF.
        buffer.removeSubrange(buffer.startIndex...lfIndex)
        if payloadLength == 0 {
            throw FramingError.emptyLine
        }
        if payloadLength > maxPayloadBytes {
            throw FramingError.oversizedFrame(limit: maxPayloadBytes)
        }
        return payload
    }
}

/// Writes length-delimited JSON frames — a payload then exactly one `LF` — to an injected byte sink,
/// looping over short writes until the whole frame has landed.
///
/// **The writer validates against the same limit its reader does**, and takes it explicitly for the same
/// reason `FrameReader` does: the limits are *directional*, so only the caller knows which side of the
/// hop it is on. Without the check, a producer could emit a frame that no conforming reader will accept
/// — the violation would then surface at the far end, as a framing error on a stream that had already
/// been failed, rather than at the one place that can still do something about it. `emptyLine` is
/// rejected here for the same reason: the reader treats a bare `LF` as fatal, so a writer that can emit
/// one is a latent stream-killer.
///
/// ⚠️ A limit rejection at write time is **not** a fix for an unbounded payload — it converts a far-end
/// framing failure into a near-end error the server can classify, and nothing more. A response that
/// genuinely does not fit (a `list` over a large enough archive) still has no answer in v1; bounding
/// that payload is Plan 2's problem, and `WireError` has no code for it yet.
public struct FrameWriter {
    private let writer: ByteWriting
    private let maxPayloadBytes: Int

    public init(writer: ByteWriting, maxPayloadBytes: Int) {
        self.writer = writer
        self.maxPayloadBytes = maxPayloadBytes
    }

    /// Write one frame: `payload` followed by a single `LF`. Never assumes one `write` sends the whole
    /// frame — it loops until every byte is delivered.
    ///
    /// Throws `emptyLine` for an empty payload and `oversizedFrame` for one past the limit — the two
    /// frames a conforming `FrameReader` would reject — and `writeStalled` if the sink stops making
    /// progress.
    public func write(payload: Data) throws {
        if payload.isEmpty {
            throw FramingError.emptyLine
        }
        if payload.count > maxPayloadBytes {
            throw FramingError.oversizedFrame(limit: maxPayloadBytes)
        }
        // Build the frame fresh so its indices are zero-based regardless of whether `payload` was a
        // slice, keeping the offset arithmetic below unambiguous.
        var frame = Data()
        frame.append(payload)
        frame.append(lineFeed)
        var offset = 0
        while offset < frame.count {
            let remaining = frame.count - offset
            let written = try writer.write(frame.subdata(in: offset..<frame.count))
            // A sink that over-reports is not trusted, mirroring the reader's defence against a source
            // that over-delivers: taking the count at face value would push `offset` past the end and
            // exit the loop as though the frame had landed.
            guard written > 0, written <= remaining else { throw FramingError.writeStalled }
            offset += written
        }
    }
}
