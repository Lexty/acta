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

    /// How many times recovery has assembled this folder and been left with audio it could not
    /// repair out of the segments (`segmentsUnrepairable`).
    ///
    /// This is what bounds the retry. A failed repair may come from something that clears — but it
    /// may just as easily come from something that never will: the segment sits on a read-only
    /// volume, the permissions are wrong, the disk is failing. Unbounded, such a folder re-runs a
    /// full `ffmpeg` concat on every single launch (and every `start()` waits on recovery first),
    /// while reading "not finished" forever with no way for the user to clear it — the exact fate
    /// the `noSegments` branch already refuses to inflict.
    ///
    /// Absent from markers written before this field existed; it decodes to 0, which is the correct
    /// reading — those folders have not yet spent an attempt.
    public var assemblyAttempts: Int

    public init(status: Status, startedAt: Date, segmentSeconds: Int, segmentCount: Int,
                assemblyAttempts: Int = 0) {
        self.status = status
        self.startedAt = startedAt
        self.segmentSeconds = segmentSeconds
        self.segmentCount = segmentCount
        self.assemblyAttempts = assemblyAttempts
    }

    /// Decoding is spelled out because `assemblyAttempts` has to tolerate its own absence: the
    /// synthesized version throws on a missing key, which would make every marker written before the
    /// field existed unreadable — and an unreadable marker is an unrecoverable recording.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        segmentSeconds = try container.decode(Int.self, forKey: .segmentSeconds)
        segmentCount = try container.decode(Int.self, forKey: .segmentCount)
        assemblyAttempts = try container.decodeIfPresent(Int.self, forKey: .assemblyAttempts) ?? 0
    }

    /// Encoder with a fixed layout: snake_case keys + ISO-8601 dates (human-readable and stable
    /// across runs). `prettyPrinted` keeps `session.json` comfortable to read by eye.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Decoder symmetric to `makeEncoder()`.
    private static func makeDecoder() -> JSONDecoder {
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
