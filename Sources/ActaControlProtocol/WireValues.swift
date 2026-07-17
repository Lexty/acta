import Foundation

// The wire types nest an enum/`CodingKeys` inside `Operation` inside `WireControlState`, which mirrors
// the JSON shape faithfully; the two extra levels are the schema, not accidental structure.
// swiftlint:disable nesting

/// The wire form of `RecordingSettings` — its **own** type, deliberately not a re-export of the runtime
/// `RecordingSettings`. The wire schema must be free to evolve (or stay frozen) independently of the
/// runtime representation, so the two are kept structurally distinct; the projection in `ActaRuntime`
/// converts between them.
public struct WireSettings: Codable, Equatable, Sendable {
    public var archivePath: String
    public var segmentSeconds: Int
    public var deleteSegmentsAfterAssembly: Bool

    public init(archivePath: String, segmentSeconds: Int, deleteSegmentsAfterAssembly: Bool) {
        self.archivePath = archivePath
        self.segmentSeconds = segmentSeconds
        self.deleteSegmentsAfterAssembly = deleteSegmentsAfterAssembly
    }

    private enum CodingKeys: String, CodingKey {
        case archivePath = "archive_path"
        case segmentSeconds = "segment_seconds"
        case deleteSegmentsAfterAssembly = "delete_segments_after_assembly"
    }
}

/// The wire form of one saved recording. **Every field must survive a missing manifest** — a folder
/// whose `session.json` is absent or unreadable — so the identity fields are always present and the
/// manifest-derived fields are optional and omitted when the manifest is absent.
public struct RecordingSummary: Codable, Equatable, Sendable {
    /// The recording's state. `unknown` is a real value, not an error: it is the honest reading when the
    /// manifest is absent, so the field can always be present.
    public enum Status: String, Codable, Sendable {
        case recording
        case done
        case recovered
        case unknown
    }

    /// The opaque, stable id (`RecordingID`). Always present.
    public var id: String
    /// The recording directory's `lastPathComponent`. Always present.
    public var directoryName: String
    /// The recording directory's absolute path. Always present. This is a local-archive agent
    /// interface — but `openInFinder` still resolves by `id`, never by this path.
    public var path: String
    /// The recording's state; `unknown` when the manifest is absent. Always present.
    public var status: Status
    /// When the recording started (ISO-8601). Omitted when the manifest is absent.
    public var startedAt: Date?
    /// The segment length the recording ran with, s. Omitted when the manifest is absent.
    public var segmentSeconds: Int?
    /// The number of finalised segments as of the manifest's last update. Omitted when absent.
    public var segmentCount: Int?
    /// How many times recovery has assembled this folder. Omitted when the manifest is absent.
    public var assemblyAttempts: Int?

    public init(id: String,
                directoryName: String,
                path: String,
                status: Status,
                startedAt: Date? = nil,
                segmentSeconds: Int? = nil,
                segmentCount: Int? = nil,
                assemblyAttempts: Int? = nil) {
        self.id = id
        self.directoryName = directoryName
        self.path = path
        self.status = status
        self.startedAt = startedAt
        self.segmentSeconds = segmentSeconds
        self.segmentCount = segmentCount
        self.assemblyAttempts = assemblyAttempts
    }

    // Synthesised `Codable`: the optionals are omitted rather than encoded as null, which is what the
    // synthesised `encode` already does for an `Optional` property. The golden fixtures pin that shape.
    private enum CodingKeys: String, CodingKey {
        case id
        case directoryName = "directory_name"
        case path
        case status
        case startedAt = "started_at"
        case segmentSeconds = "segment_seconds"
        case segmentCount = "segment_count"
        case assemblyAttempts = "assembly_attempts"
    }
}

/// The wire form of `ControlState` — what a `status`/`start`/`stop`/completion result carries, and what
/// a `watch` event wraps. Every failure/notice is a `{code, message}` pair so a client can branch on a
/// stable machine code without parsing prose.
public struct WireControlState: Codable, Equatable, Sendable {
    /// What the recorder is doing. `elapsedSeconds` is present **only** when `kind == .recording`.
    public struct Operation: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case idle
            case starting
            case recording
            case saving
        }

        public var kind: Kind
        public var elapsedSeconds: Int?

        public init(kind: Kind, elapsedSeconds: Int? = nil) {
            self.kind = kind
            self.elapsedSeconds = elapsedSeconds
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case elapsedSeconds = "elapsed_seconds"
        }
    }

    /// A classified message: a stable machine `code` and a human `message`.
    public struct Message: Codable, Equatable, Sendable {
        public var code: String
        public var message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public var operation: Operation
    public var lifecycleFailure: Message?
    public var notice: Message?
    public var recoveryNotice: Message?
    public var title: String
    public var suggestedTitle: String
    public var settings: WireSettings
    public var recordings: [RecordingSummary]
    public var canStart: Bool
    public var canStop: Bool

    public init(operation: Operation,
                lifecycleFailure: Message? = nil,
                notice: Message? = nil,
                recoveryNotice: Message? = nil,
                title: String,
                suggestedTitle: String,
                settings: WireSettings,
                recordings: [RecordingSummary],
                canStart: Bool,
                canStop: Bool) {
        self.operation = operation
        self.lifecycleFailure = lifecycleFailure
        self.notice = notice
        self.recoveryNotice = recoveryNotice
        self.title = title
        self.suggestedTitle = suggestedTitle
        self.settings = settings
        self.recordings = recordings
        self.canStart = canStart
        self.canStop = canStop
    }

    private enum CodingKeys: String, CodingKey {
        case operation
        case lifecycleFailure = "lifecycle_failure"
        case notice
        case recoveryNotice = "recovery_notice"
        case title
        case suggestedTitle = "suggested_title"
        case settings
        case recordings
        case canStart = "can_start"
        case canStop = "can_stop"
    }
}

// swiftlint:enable nesting
