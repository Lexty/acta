import ActaControlProtocol
import Darwin
import Foundation
import os

/// The tunable per-connection deadlines. Defaults are generous enough for a healthy local client and
/// short enough that a stuck one is reaped promptly.
public struct ControlServingTimeouts: Sendable {
    /// Max wait for a client to deliver its (one) request frame.
    public var readIdle: DispatchTimeInterval
    /// Max wait for the socket to accept more bytes during a single frame write.
    public var write: DispatchTimeInterval

    public init(readIdle: DispatchTimeInterval = .seconds(10),
                write: DispatchTimeInterval = .seconds(10)) {
        self.readIdle = readIdle
        self.write = write
    }

    public static let `default` = ControlServingTimeouts()
}

/// Serves **one** connection: read a request, dispatch it on the main actor, write the reply — or, for
/// `watch`, stream events until the peer goes away. Every exit path closes the descriptor exactly once.
///
/// The request/response shape is deliberately one-shot: a normal command yields exactly one response
/// frame and the connection closes. `watch` is the sole streaming case.
@available(macOS 15.0, *)
public final class ControlConnection: @unchecked Sendable {
    private let io: ControlConnectionIO
    private let handler: any ControlRequestHandling
    private let timeouts: ControlServingTimeouts
    private let log: Logger

    public init(io: ControlConnectionIO,
                handler: any ControlRequestHandling,
                timeouts: ControlServingTimeouts,
                log: Logger) {
        self.io = io
        self.handler = handler
        self.timeouts = timeouts
        self.log = log
    }

    /// Serve the connection to completion. Never throws: every error is caught, logged and turned into a
    /// close.
    public func serve() async {
        defer { io.close() }
        do {
            guard let frame = try await readRequestFrame() else {
                // Clean EOF before any request — nothing to answer.
                return
            }
            try await dispatchAndReply(frame)
        } catch let error as ConnectionError {
            log.debug("control connection closed: \(String(describing: error), privacy: .public)")
        } catch {
            log.debug("control connection closed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Reading the request

    /// Read exactly one request frame, awaiting readability on `WouldBlock` and enforcing the read/idle
    /// deadline. `nil` on a clean EOF with no partial frame.
    private func readRequestFrame() async throws -> Data? {
        var reader = FrameReader(reader: IOByteReader(io: io),
                                 maxPayloadBytes: FramingLimits.maxRequestPayloadBytes)
        while true {
            do {
                return try reader.next()
            } catch is ControlConnectionIO.WouldBlock {
                switch await io.awaitReadable(deadline: .now() + timeouts.readIdle) {
                case .ready: continue
                case .timedOut: throw ConnectionError.idleTimeout
                case .cancelled: throw ConnectionError.cancelled
                }
            }
            // A `FramingError` (oversized/truncated/empty) escapes here and fails the connection — a
            // control socket has no reason to resume past a malformed frame.
        }
    }

    // MARK: - Dispatch + reply

    private func dispatchAndReply(_ frame: Data) async throws {
        switch ControlProtocolCodec.decodeRequest(from: frame) {
        case .malformed:
            // No id survived — there is nothing to address a reply to. Close.
            return
        case .versionMismatch(let id, _):
            try await writeResponse(.error(id: id,
                .unsupportedVersion(supportedVersions: ProtocolVersion.supported)))
        case .undecodableCommand(let id, let reason):
            try await writeResponse(.error(id: id, .badRequest(reason: reason)))
        case .request(let request):
            try await handle(request)
        }
    }

    private func handle(_ request: WireRequest) async throws {
        // Validation + dispatch + projection all happen on the main actor, inside `handle`.
        let response = await handler.handle(request.command)
        switch response {
        case .result(let result):
            try await writeResponse(.result(id: request.id, result))
        case .error(let error):
            try await writeResponse(.error(id: request.id, error))
        case .events(let stream):
            try await streamEvents(stream, id: request.id)
        }
    }

    private func writeResponse(_ response: WireResponse) async throws {
        let payload = try ControlProtocolCodec.encode(response)
        try await writeFrame(payload, limit: FramingLimits.maxResponsePayloadBytes)
    }

    // MARK: - watch

    /// Stream `watch` events until the peer goes away. Two children race: one pumps events out, the
    /// other watches the read side for the peer's EOF (or an unexpected byte). Whichever finishes first
    /// cancels the other, so a client that drops the connection tears the watch down rather than leaving
    /// a pump running forever.
    private func streamEvents(_ stream: AsyncStream<WatchEvent>, id: String) async throws {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                do { try await self.pumpEvents(stream, id: id) } catch { /* peer gone; end the group */ }
            }
            group.addTask { [weak self] in
                guard let self else { return }
                await self.awaitPeerDisconnect()
            }
            // The first child to finish (the pump on a write failure, or the monitor on EOF) ends the
            // watch; cancel the other and drain.
            await group.next()
            group.cancelAll()
            await group.waitForAll()
        }
    }

    private func pumpEvents(_ stream: AsyncStream<WatchEvent>, id: String) async throws {
        for await event in stream {
            let payload = try ControlProtocolCodec.encode(WireEvent(id: id, event: event))
            try await writeFrame(payload, limit: FramingLimits.maxResponsePayloadBytes)
        }
    }

    /// Resolve when the peer closes the connection (a 0-length read) or sends an unexpected byte on a
    /// `watch` stream (a protocol violation — a watcher does not talk). Either ends the watch. No
    /// deadline: an idle watch with a reading peer is legitimate and long-lived; it is bounded only by
    /// the write deadline on the next event and by the connection cap.
    private func awaitPeerDisconnect() async {
        while true {
            switch await io.awaitReadable(deadline: .distantFuture) {
            case .cancelled, .timedOut:
                return
            case .ready:
                do {
                    let data = try io.readAvailable(maxBytes: FramingLimits.maxReadChunkBytes)
                    // EOF or any unsolicited byte: stop watching.
                    if data.isEmpty { return }
                    return
                } catch is ControlConnectionIO.WouldBlock {
                    continue
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - Writing

    /// Frame `payload` with Plan 1's `FrameWriter` (validating the size limit and appending the `LF`),
    /// then push it out with backpressure and the write deadline.
    private func writeFrame(_ payload: Data, limit: Int) async throws {
        let sink = DataFrameSink()
        try FrameWriter(writer: sink, maxPayloadBytes: limit).write(payload: payload)
        try await io.write(sink.data, deadline: { [timeouts] in .now() + timeouts.write })
    }
}

/// Bridges `ControlConnectionIO`'s non-blocking read into Plan 1's `ByteReading`: hands the framer the
/// available bytes, an empty `Data` at EOF, or rethrows `WouldBlock` (which the framer does **not**
/// latch — it is a source error, not a framing error — so the serve loop can await readiness and retry).
@available(macOS 15.0, *)
private struct IOByteReader: ByteReading {
    let io: ControlConnectionIO
    func read(maxBytes: Int) throws -> Data {
        try io.readAvailable(maxBytes: maxBytes)
    }
}
