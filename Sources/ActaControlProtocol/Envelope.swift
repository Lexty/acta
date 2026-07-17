import Foundation

/// The protocol version. Matched **exactly**: a request whose `version` is not `current` is answered
/// with `unsupported_version` carrying `supported`, never decoded as if it were v1.
///
/// Forward-compat rules for v1 (stated; no adapters are built):
/// - Unknown JSON keys are ignored (a keyed container drops them).
/// - Only **optional** fields may be added within v1.
/// - An unknown command `type` decodes to `.unsupportedCommand` — data, never a throw — because the
///   server has to answer it.
/// - A well-formed envelope whose command payload does not decode keeps its id
///   (`.undecodableCommand`), so the error reply can be addressed.
/// - A version mismatch yields `unsupported_version` carrying `supported`.
///
/// ⚠️ **The enum rule is narrower than it looks, and the exact-version match is what carries it.** Every
/// *other* enum in the protocol (`RecordingSummary.Status`, `WireControlState.Operation.Kind`,
/// `CommandResult`'s `type`, `WireError`'s `code`) is **response-direction** and decodes with a plain
/// `decode`, which **throws** on a discriminator this build does not know. That is tolerable only
/// because `version` is matched exactly: a peer that could send a new `status` value is by definition
/// not v1, and is refused before any of it is decoded. It is *not* a licence to add a value to one of
/// those enums within v1 — doing so would make the whole enclosing response undecodable to an older
/// `actactl`, not just the one field. `WireError.unsupportedValue` is **reserved for the first
/// request-direction enum** and has no producer today; do not read its presence as a claim that
/// tolerant decoding exists.
public enum ProtocolVersion {
    public static let current = 1
    public static let supported = [1]
}

/// A request envelope: `{version, id, command}`.
public struct WireRequest: Equatable, Sendable, Codable {
    public var version: Int
    public var id: String
    public var command: Command

    public init(id: String, command: Command, version: Int = ProtocolVersion.current) {
        self.version = version
        self.id = id
        self.command = command
    }
}

/// A response envelope: `{version, id, result}` **or** `{version, id, error}` — never both.
public struct WireResponse: Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case result(CommandResult)
        case error(WireError)
    }

    public var version: Int
    public var id: String
    public var payload: Payload

    public init(id: String, payload: Payload, version: Int = ProtocolVersion.current) {
        self.version = version
        self.id = id
        self.payload = payload
    }

    public static func result(id: String, _ result: CommandResult) -> WireResponse {
        WireResponse(id: id, payload: .result(result))
    }

    public static func error(id: String, _ error: WireError) -> WireResponse {
        WireResponse(id: id, payload: .error(error))
    }
}

extension WireResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        id = try c.decode(String.self, forKey: .id)
        if let result = try c.decodeIfPresent(CommandResult.self, forKey: .result) {
            payload = .result(result)
        } else if let error = try c.decodeIfPresent(WireError.self, forKey: .error) {
            payload = .error(error)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .result, in: c,
                debugDescription: "response carries neither a result nor an error")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        switch payload {
        case .result(let result): try c.encode(result, forKey: .result)
        case .error(let error): try c.encode(error, forKey: .error)
        }
    }
}

/// One `watch` event, wrapped in its own envelope: `{version, id, event}`. The `id` echoes the
/// originating `watch` request's id, so a client can demultiplex events per subscription.
public struct WireEvent: Equatable, Sendable, Codable {
    public var version: Int
    public var id: String
    public var event: WatchEvent

    public init(id: String, event: WatchEvent, version: Int = ProtocolVersion.current) {
        self.version = version
        self.id = id
        self.event = event
    }
}

/// A single `watch` event payload: a monotonically increasing `sequence` and the state it carries. The
/// sequence is assigned **before** the transport's coalescing, so a gap in the numbers tells a client
/// that intervening states were dropped rather than pretending none were.
public struct WatchEvent: Equatable, Sendable, Codable {
    public var sequence: Int
    public var state: WireControlState

    public init(sequence: Int, state: WireControlState) {
        self.sequence = sequence
        self.state = state
    }
}

/// The canonical JSON codec for the whole protocol. **Explicit** date handling (ISO-8601, not the
/// encoder default of a numeric interval) and **sorted keys**, so a re-encode is byte-stable and the
/// golden fixtures are deterministic. Every wire type is encoded and decoded through here.
public enum ControlProtocolCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    /// Decode a request while enforcing the exact-version rule, keeping the `id` even on mismatch so the
    /// server can address its error reply.
    ///
    /// - `.request` — a v1 request that decoded.
    /// - `.versionMismatch` — the envelope carried a different `version`; the id is preserved so the
    ///   server can reply `unsupported_version`.
    /// - `.undecodableCommand` — a well-formed v1 envelope whose `command` payload did not decode (a
    ///   known `type` missing a required field). The id is preserved: the header decoded, so the server
    ///   can and must address its error reply.
    /// - `.malformed` — the bytes are not even a `{version, id, …}` envelope, so there really is no id
    ///   to reply to. This is the *only* outcome for which that is true.
    public static func decodeRequest(from data: Data) -> RequestDecodeOutcome {
        // First read only the envelope header, so a request whose *command* shape is newer than v1
        // still yields its id and version for the mismatch reply.
        guard let header = try? makeDecoder().decode(EnvelopeHeader.self, from: data) else {
            return .malformed("not a control-protocol envelope")
        }
        guard header.version == ProtocolVersion.current else {
            return .versionMismatch(id: header.id, requested: header.version)
        }
        do {
            return .request(try makeDecoder().decode(WireRequest.self, from: data))
        } catch {
            // `header.id` decoded a line ago and is right here: answering `.malformed` would throw away
            // an id the server holds, leaving an ordinary client bug (a `title_set` with no `title`)
            // uncorrelatable on a socket carrying several requests at once. An unknown command *tag* does
            // not reach this path at all — `Command` decodes that to `.unsupportedCommand`, which is data.
            // The reason is deliberately not the `DecodingError`, whose description carries coding paths
            // and debug prose a client has no use for and should not be handed.
            return .undecodableCommand(id: header.id, reason: "could not decode command")
        }
    }

    private struct EnvelopeHeader: Decodable {
        var version: Int
        var id: String
    }
}

/// The outcome of `ControlProtocolCodec.decodeRequest(from:)`.
public enum RequestDecodeOutcome: Equatable, Sendable {
    case request(WireRequest)
    case versionMismatch(id: String, requested: Int)
    case undecodableCommand(id: String, reason: String)
    case malformed(String)
}
