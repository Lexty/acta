import Foundation

/// The full result algebra — the `result` payload of a successful response, defined **here** so the
/// dispatcher and the CLI agree on every case. Discriminated by a `type` tag plus its payload.
///
/// The mapping from command to result is fixed: `status`/`start`/`stop`/`stopAndWait` all return the
/// projected `state`; `list` returns `recordings`; `settingsGet` returns `settings`; `titleGet` returns
/// `title`; and every void acknowledgement (`recover`/`refresh`/`openArchive`/`openInFinder`/
/// `settingsSet`/`settingsSave`/`titleSet`/`dismissRecoveryNotice`) returns `ok`.
public enum CommandResult: Equatable, Sendable {
    case state(WireControlState)
    case recordings([RecordingSummary])
    case settings(WireSettings)
    case title(String)
    case ok

    public enum Tag {
        public static let state = "state"
        public static let recordings = "recordings"
        public static let settings = "settings"
        public static let title = "title"
        public static let ok = "ok"
    }
}

extension CommandResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case state
        case recordings
        case settings
        case title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case Tag.state:
            self = .state(try c.decode(WireControlState.self, forKey: .state))
        case Tag.recordings:
            self = .recordings(try c.decode([RecordingSummary].self, forKey: .recordings))
        case Tag.settings:
            self = .settings(try c.decode(WireSettings.self, forKey: .settings))
        case Tag.title:
            self = .title(try c.decode(String.self, forKey: .title))
        case Tag.ok:
            self = .ok
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown result type '\(type)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .state(let state):
            try c.encode(Tag.state, forKey: .type)
            try c.encode(state, forKey: .state)
        case .recordings(let recordings):
            try c.encode(Tag.recordings, forKey: .type)
            try c.encode(recordings, forKey: .recordings)
        case .settings(let settings):
            try c.encode(Tag.settings, forKey: .type)
            try c.encode(settings, forKey: .settings)
        case .title(let title):
            try c.encode(Tag.title, forKey: .type)
            try c.encode(title, forKey: .title)
        case .ok:
            try c.encode(Tag.ok, forKey: .type)
        }
    }
}
