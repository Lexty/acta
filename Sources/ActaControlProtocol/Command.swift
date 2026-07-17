import Foundation

/// The full command algebra the transport accepts — defined **here**, once, so the dispatcher and the
/// CLI invent nothing. Each case is discriminated on the wire by a `type` tag (snake_case) plus its
/// associated payload.
///
/// ⚠️ **Decoding is hand-written for forward-compat.** A synthesized `Codable` enum would *throw* on an
/// unknown discriminator — before the dispatcher could answer it — so an unknown `type` decodes to
/// `.unsupportedCommand(raw:)` instead, which the dispatcher maps to an `unsupported_command` error.
/// A decode never crashes and never throws on an unknown tag.
public enum Command: Equatable, Sendable {
    case status
    case list
    case watch
    case start(title: String?)
    case stop
    case stopAndWait
    case recover
    case refresh
    case openArchive
    case openInFinder(id: String)
    case settingsGet
    case settingsSet(WireSettings)
    case settingsSave
    case titleGet
    case titleSet(String)
    case dismissRecoveryNotice
    /// A `type` tag this build does not know. Carried as data, not thrown, so the dispatcher can reply
    /// `unsupported_command` with the raw tag.
    case unsupportedCommand(raw: String)

    /// The frozen wire tags. `unsupportedCommand` has no tag of its own — it is the absence of a known
    /// one.
    public enum Tag {
        public static let status = "status"
        public static let list = "list"
        public static let watch = "watch"
        public static let start = "start"
        public static let stop = "stop"
        public static let stopAndWait = "stop_and_wait"
        public static let recover = "recover"
        public static let refresh = "refresh"
        public static let openArchive = "open_archive"
        public static let openInFinder = "open_in_finder"
        public static let settingsGet = "settings_get"
        public static let settingsSet = "settings_set"
        public static let settingsSave = "settings_save"
        public static let titleGet = "title_get"
        public static let titleSet = "title_set"
        public static let dismissRecoveryNotice = "dismiss_recovery_notice"
    }
}

extension Command: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case id
        case settings
    }

    // swiftlint:disable:next cyclomatic_complexity
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case Tag.status: self = .status
        case Tag.list: self = .list
        case Tag.watch: self = .watch
        case Tag.start:
            self = .start(title: try c.decodeIfPresent(String.self, forKey: .title))
        case Tag.stop: self = .stop
        case Tag.stopAndWait: self = .stopAndWait
        case Tag.recover: self = .recover
        case Tag.refresh: self = .refresh
        case Tag.openArchive: self = .openArchive
        case Tag.openInFinder:
            self = .openInFinder(id: try c.decode(String.self, forKey: .id))
        case Tag.settingsGet: self = .settingsGet
        case Tag.settingsSet:
            self = .settingsSet(try c.decode(WireSettings.self, forKey: .settings))
        case Tag.settingsSave: self = .settingsSave
        case Tag.titleGet: self = .titleGet
        case Tag.titleSet:
            self = .titleSet(try c.decode(String.self, forKey: .title))
        case Tag.dismissRecoveryNotice: self = .dismissRecoveryNotice
        default:
            // The load-bearing branch: an unknown tag is data, not a throw.
            self = .unsupportedCommand(raw: type)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status: try c.encode(Tag.status, forKey: .type)
        case .list: try c.encode(Tag.list, forKey: .type)
        case .watch: try c.encode(Tag.watch, forKey: .type)
        case .start(let title):
            try c.encode(Tag.start, forKey: .type)
            try c.encodeIfPresent(title, forKey: .title)
        case .stop: try c.encode(Tag.stop, forKey: .type)
        case .stopAndWait: try c.encode(Tag.stopAndWait, forKey: .type)
        case .recover: try c.encode(Tag.recover, forKey: .type)
        case .refresh: try c.encode(Tag.refresh, forKey: .type)
        case .openArchive: try c.encode(Tag.openArchive, forKey: .type)
        case .openInFinder(let id):
            try c.encode(Tag.openInFinder, forKey: .type)
            try c.encode(id, forKey: .id)
        case .settingsGet: try c.encode(Tag.settingsGet, forKey: .type)
        case .settingsSet(let settings):
            try c.encode(Tag.settingsSet, forKey: .type)
            try c.encode(settings, forKey: .settings)
        case .settingsSave: try c.encode(Tag.settingsSave, forKey: .type)
        case .titleGet: try c.encode(Tag.titleGet, forKey: .type)
        case .titleSet(let title):
            try c.encode(Tag.titleSet, forKey: .type)
            try c.encode(title, forKey: .title)
        case .dismissRecoveryNotice: try c.encode(Tag.dismissRecoveryNotice, forKey: .type)
        case .unsupportedCommand(let raw):
            // Round-trips the unknown tag verbatim — an unknown command re-encodes to what it decoded
            // from, rather than to a lie.
            try c.encode(raw, forKey: .type)
        }
    }
}
