import Foundation

/// The **complete, frozen** error-code set, defined here so no other layer invents a code. Every error
/// is `{code, message}` on the wire, plus the code-specific fields fixed below. `code` is the stable
/// machine string a client branches on; `message` is human-facing prose it never parses.
///
/// The cases and their extra fields:
/// - `bad_request` — `reason`: the request did not decode. ⚠️ **The one code that blames the client for
///   the bytes, and the reason it exists here rather than in the transport.** `decodeRequest` produces
///   `.undecodableCommand(id:reason:)` and goes out of its way to keep the id precisely so the failure
///   can be answered — but a decode failure is neither the recorder's guard refusing
///   (`command_rejected` never reached the recorder at all) nor a server fault (`internal`, which an
///   agent may sensibly retry — and would then retry a malformed request forever). A code set that is
///   frozen must cover the outcomes its own decoder can produce, so it is minted now, while minting is
///   free. `reason` carries the decoder's sanitized summary, never a `DecodingError` description.
/// - `command_rejected` — `reason`: a start (or other command) the recorder's own guard refused.
/// - `unknown_recording` — `id`: an `openInFinder` id that matches no current recording.
/// - `unsupported_command` — `raw`: a command `type` tag this build does not know.
/// - `unsupported_value` — `field`, `raw`: an enum discriminator this build does not know. ⚠️ **Reserved
///   — nothing produces it yet.** The one request-direction enum is the command `type`, which has its own
///   code (`unsupported_command`); every other enum is response-direction and throws on an unknown
///   discriminator, guarded by the exact-version match rather than by this code (see `ProtocolVersion`).
///   It is kept because the code set is frozen, and it is where the first request-direction enum will
///   land — not because a tolerant decode path exists.
/// - `unsupported_version` — `supported_versions`: the envelope `version` did not match.
/// - `not_recording` — no extra field: an operation that needs a live recording, when there is none.
/// - `internal` — no extra field: an unexpected failure the server could not classify.
public enum WireError: Error, Equatable, Sendable {
    case badRequest(reason: String, message: String)
    case commandRejected(reason: String, message: String)
    case unknownRecording(id: String, message: String)
    case unsupportedCommand(raw: String, message: String)
    case unsupportedValue(field: String, raw: String, message: String)
    case unsupportedVersion(supportedVersions: [Int], message: String)
    case notRecording(message: String)
    case internalError(message: String)

    /// The frozen wire `code` strings.
    public enum Code {
        public static let badRequest = "bad_request"
        public static let commandRejected = "command_rejected"
        public static let unknownRecording = "unknown_recording"
        public static let unsupportedCommand = "unsupported_command"
        public static let unsupportedValue = "unsupported_value"
        public static let unsupportedVersion = "unsupported_version"
        public static let notRecording = "not_recording"
        public static let internalError = "internal"
    }

    /// This error's stable machine code.
    public var code: String {
        switch self {
        case .badRequest: return Code.badRequest
        case .commandRejected: return Code.commandRejected
        case .unknownRecording: return Code.unknownRecording
        case .unsupportedCommand: return Code.unsupportedCommand
        case .unsupportedValue: return Code.unsupportedValue
        case .unsupportedVersion: return Code.unsupportedVersion
        case .notRecording: return Code.notRecording
        case .internalError: return Code.internalError
        }
    }

    /// The human-facing message.
    public var message: String {
        switch self {
        case .badRequest(_, let message),
             .commandRejected(_, let message),
             .unknownRecording(_, let message),
             .unsupportedCommand(_, let message),
             .unsupportedValue(_, _, let message),
             .unsupportedVersion(_, let message),
             .notRecording(let message),
             .internalError(let message):
            return message
        }
    }

    // MARK: - Convenience constructors with default messages

    public static func badRequest(reason: String) -> WireError {
        .badRequest(reason: reason, message: "The request could not be decoded: \(reason)")
    }

    public static func commandRejected(reason: String) -> WireError {
        .commandRejected(reason: reason, message: "The command was rejected: \(reason)")
    }

    public static func unknownRecording(id: String) -> WireError {
        .unknownRecording(id: id, message: "No recording matches the id '\(id)'.")
    }

    public static func unsupportedCommand(raw: String) -> WireError {
        .unsupportedCommand(raw: raw, message: "Unsupported command '\(raw)'.")
    }

    public static func unsupportedValue(field: String, raw: String) -> WireError {
        .unsupportedValue(field: field, raw: raw,
                          message: "Unsupported value '\(raw)' for '\(field)'.")
    }

    public static func unsupportedVersion(supportedVersions: [Int]) -> WireError {
        let list = supportedVersions.map(String.init).joined(separator: ", ")
        return .unsupportedVersion(supportedVersions: supportedVersions,
                                   message: "Unsupported protocol version; supported: \(list).")
    }

    public static func notRecording() -> WireError {
        .notRecording(message: "There is no recording in progress.")
    }

    public static func internalError() -> WireError {
        .internalError(message: "An internal error occurred.")
    }
}

extension WireError: Codable {
    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case reason
        case id
        case raw
        case field
        case supportedVersions = "supported_versions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(String.self, forKey: .code)
        let message = try c.decode(String.self, forKey: .message)
        switch code {
        case Code.badRequest:
            self = .badRequest(reason: try c.decode(String.self, forKey: .reason), message: message)
        case Code.commandRejected:
            self = .commandRejected(reason: try c.decode(String.self, forKey: .reason), message: message)
        case Code.unknownRecording:
            self = .unknownRecording(id: try c.decode(String.self, forKey: .id), message: message)
        case Code.unsupportedCommand:
            self = .unsupportedCommand(raw: try c.decode(String.self, forKey: .raw), message: message)
        case Code.unsupportedValue:
            self = .unsupportedValue(field: try c.decode(String.self, forKey: .field),
                                     raw: try c.decode(String.self, forKey: .raw),
                                     message: message)
        case Code.unsupportedVersion:
            self = .unsupportedVersion(supportedVersions: try c.decode([Int].self, forKey: .supportedVersions),
                                       message: message)
        case Code.notRecording:
            self = .notRecording(message: message)
        case Code.internalError:
            self = .internalError(message: message)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .code, in: c,
                debugDescription: "unknown error code '\(code)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(message, forKey: .message)
        switch self {
        case .badRequest(let reason, _),
             .commandRejected(let reason, _):
            try c.encode(reason, forKey: .reason)
        case .unknownRecording(let id, _):
            try c.encode(id, forKey: .id)
        case .unsupportedCommand(let raw, _):
            try c.encode(raw, forKey: .raw)
        case .unsupportedValue(let field, let raw, _):
            try c.encode(field, forKey: .field)
            try c.encode(raw, forKey: .raw)
        case .unsupportedVersion(let supportedVersions, _):
            try c.encode(supportedVersions, forKey: .supportedVersions)
        case .notRecording, .internalError:
            break
        }
    }
}
