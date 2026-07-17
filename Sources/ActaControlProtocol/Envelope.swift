import Foundation

/// The protocol version. Matched **exactly**: a request whose `version` is not `current` is answered
/// with `unsupported_version` carrying `supported`, never decoded as if it were v1.
///
/// Forward-compat rules for v1 (stated; no adapters are built):
/// - Unknown JSON keys are ignored (a keyed container drops them).
/// - Only **optional** fields may be added within v1.
/// - An unknown command `type` decodes to `.unsupportedCommand`; an unknown enum discriminator becomes
///   an `unsupported_value` error — never a decode crash.
/// - A version mismatch yields `unsupported_version` carrying `supported`.
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
    /// - `.malformed` — the bytes are not even a `{version, id, …}` envelope, so there is no id to reply
    ///   to.
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
            return .malformed("could not decode command: \(error)")
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
    case malformed(String)
}
