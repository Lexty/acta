import Foundation

/// Marker of a recording session — the contents of `session.json` in the recording folder.
///
/// Written at start (`status=recording`), updated as the recording proceeds and on finalisation.
/// Finding `status=recording` on the app's next launch means the recording was interrupted
/// abnormally (crash/restart) → `RecoveryManager` picks it up (see the `crash-safe-recording`
/// skill).
///
/// Serialisation is **pure logic** (a JSON round-trip), so the type and its codec live in `ActaKit`
/// and are covered by a unit test (`SessionManifestTests`), separately from the file system.
public struct SessionManifest: Codable, Equatable, Sendable {
    /// Recording state.
    public enum Status: String, Codable, Sendable {
        /// Recording is in progress (or the process was interrupted before the file was updated to
        /// `done`/`recovered`).
        case recording
        /// Clean stop: the segments were assembled into the final files.
        case done
        /// The recording was interrupted abnormally and recovered at startup from the surviving
        /// segments.
        case recovered
    }

    /// File name of the marker inside the recording folder.
    public static let fileName = "session.json"

    /// Current state.
    public var status: Status

    /// Moment the recording started.
    public var startedAt: Date

    /// Segment length (s) the recording ran with — recovery needs it to estimate the duration.
    public var segmentSeconds: Int

    /// Number of finalised segments as of the last update of the marker.
    public var segmentCount: Int

    public init(status: Status, startedAt: Date, segmentSeconds: Int, segmentCount: Int) {
        self.status = status
        self.startedAt = startedAt
        self.segmentSeconds = segmentSeconds
        self.segmentCount = segmentCount
    }

    /// Encoder with a fixed layout: snake_case keys + ISO-8601 dates (human-readable and stable
    /// across runs). `prettyPrinted` keeps `session.json` comfortable to read by eye.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Decoder symmetric to `makeEncoder()`.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Serialise to JSON.
    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Parse from JSON.
    public static func decode(from data: Data) throws -> SessionManifest {
        try makeDecoder().decode(SessionManifest.self, from: data)
    }
}
