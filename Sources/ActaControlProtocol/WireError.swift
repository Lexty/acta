import Foundation

/// The **complete, frozen** error-code set, defined here so no other layer invents a code. Every error
/// is `{code, message}` on the wire, plus the code-specific fields fixed below. `code` is the stable
/// machine string a client branches on; `message` is human-facing prose it never parses.
///
/// The cases and their extra fields:
/// - `command_rejected` — `reason`: a start (or other command) the recorder's own guard refused.
/// - `unknown_recording` — `id`: an `openInFinder` id that matches no current recording.
/// - `unsupported_command` — `raw`: a command `type` tag this build does not know.
/// - `unsupported_value` — `field`, `raw`: an enum discriminator this build does not know.
/// - `unsupported_version` — `supported_versions`: the envelope `version` did not match.
/// - `not_recording` — no extra field: an operation that needs a live recording, when there is none.
/// - `internal` — no extra field: an unexpected failure the server could not classify.
public enum WireError: Error, Equatable, Sendable {
    case commandRejected(reason: String, message: String)
    case unknownRecording(id: String, message: String)
    case unsupportedCommand(raw: String, message: String)
    case unsupportedValue(field: String, raw: String, message: String)
    case unsupportedVersion(supportedVersions: [Int], message: String)
    case notRecording(message: String)
    case internalError(message: String)

    /// The frozen wire `code` strings.
    public enum Code {
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
        case .commandRejected(_, let message),
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
        case .commandRejected(let reason, _):
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
