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
public struct FrameReader {
    private var buffer = Data()
    private var reachedEOF = false
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
    /// bare `LF`, and `truncatedFrame` when EOF leaves a non-empty unterminated tail.
    public mutating func next() throws -> Data? {
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
public struct FrameWriter {
    private let writer: ByteWriting

    public init(writer: ByteWriting) {
        self.writer = writer
    }

    /// Write one frame: `payload` followed by a single `LF`. Never assumes one `write` sends the whole
    /// frame — it loops until every byte is delivered.
    public func write(payload: Data) throws {
        // Build the frame fresh so its indices are zero-based regardless of whether `payload` was a
        // slice, keeping the offset arithmetic below unambiguous.
        var frame = Data()
        frame.append(payload)
        frame.append(lineFeed)
        var offset = 0
        while offset < frame.count {
            let written = try writer.write(frame.subdata(in: offset..<frame.count))
            guard written > 0 else { throw FramingError.writeStalled }
            offset += written
        }
    }
}
