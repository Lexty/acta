import Foundation

/// Pure logic of the recording archive layout: the slug built from a title, the meeting folder name
/// and the serialisation of `info.md` (YAML front-matter). Kept separate from the file system (the
/// FS part is `MeetingStore` in the `Acta` target) so that slug and front-matter generation are
/// covered by unit tests (`MeetingArchiveTests`) instead of being checked by hand by running the
/// app.
///
/// Folder format: `YYYY-MM-DD_HHMM__<slug>/` (see `SPEC.md` §6). Inside it — the audio +
/// `session.json` + `info.md`.
public enum MeetingArchive {
    /// File name of the meeting metadata inside a recording folder.
    public static let infoFileName = "info.md"

    /// Default slug value, used when the title leaves no meaningful character behind.
    public static let fallbackSlug = "meeting"

    /// Maximum slug length (in characters) — to keep folder names from growing without bound.
    public static let maxSlugLength = 60

    // MARK: - Slug

    /// Build a slug from a meeting title.
    ///
    /// Lowercases the title, keeps letters and digits (including non-Latin scripts such as
    /// Cyrillic — they are valid in macOS file names), and collapses any whitespace/punctuation into
    /// a single `-`. Trims leading/trailing `-` and the length. An empty result → `fallbackSlug`, so
    /// that the folder name is always valid.
    public static func slug(from title: String, maxLength: Int = maxSlugLength) -> String {
        var result = ""
        var lastWasSeparator = true // true at the start, so no leading '-' can appear
        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("-")
                lastWasSeparator = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }

        if result.count > maxLength {
            result = String(result.prefix(maxLength))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result.isEmpty ? fallbackSlug : result
    }

    // MARK: - Folder name

    /// Meeting folder name: `YYYY-MM-DD_HHMM__<slug>`.
    ///
    /// `timeZone` is a parameter for test determinism (it defaults to the local zone).
    public static func folderName(date: Date, slug: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return "\(formatter.string(from: date))__\(slug)"
    }

    /// Folder name straight from a title (the slug is built inside).
    public static func folderName(date: Date, title: String, timeZone: TimeZone = .current) -> String {
        folderName(date: date, slug: slug(from: title), timeZone: timeZone)
    }
}

/// Meeting metadata for `info.md` — **pure logic** of serialising to YAML front-matter.
///
/// The fields follow `SPEC.md` §6: `title, date, source, duration, status`. The status reuses
/// `SessionManifest.Status` (the very same recording states).
public struct MeetingInfo: Equatable, Sendable {
    /// Human-readable meeting title.
    public var title: String

    /// Moment the recording started.
    public var date: Date

    /// Audio/meeting source (Slack, Teams, Meet, …); may be empty.
    public var source: String

    /// Recording duration, s.
    public var durationSeconds: Int

    /// Recording state (recording/done/recovered).
    public var status: SessionManifest.Status

    public init(title: String, date: Date, source: String, durationSeconds: Int,
                status: SessionManifest.Status) {
        self.title = title
        self.date = date
        self.source = source
        self.durationSeconds = durationSeconds
        self.status = status
    }

    /// The full contents of `info.md`: YAML front-matter + a markdown heading for readability.
    public func rendered() -> String {
        var lines = ["---"]
        lines.append("title: \(Self.quote(title))")
        lines.append("date: \(Self.iso8601(from: date))")
        lines.append("source: \(Self.quote(source))")
        lines.append("duration: \(Self.quote(Self.formatDuration(seconds: durationSeconds)))")
        lines.append("status: \(status.rawValue)")
        lines.append("---")
        lines.append("")
        lines.append("# \(Self.singleLine(title))")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Update only `status` and `duration` in an existing `info.md`, leaving everything else as is.
    ///
    /// Recovery needs this: `info.md` is written at start (`recording`, `00:00:00`), and after a
    /// crash the title/date/source are known only from the file itself. A full YAML parser for the
    /// sake of two fields is overkill, so we patch the lines inside the front-matter (the block
    /// between the first pair of `---`). If the front-matter is not recognised, the original text is
    /// returned: stale metadata beats a corrupted file.
    public static func patchedFrontMatter(_ contents: String, status: SessionManifest.Status,
                                          durationSeconds: Int) -> String {
        var lines = contents.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.isEmpty }), lines[first] == "---",
              let closing = lines[(first + 1)...].firstIndex(of: "---") else {
            return contents
        }
        for index in (first + 1)..<closing {
            if lines[index].hasPrefix("status:") {
                lines[index] = "status: \(status.rawValue)"
            } else if lines[index].hasPrefix("duration:") {
                lines[index] = "duration: \(quote(formatDuration(seconds: durationSeconds)))"
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Serialisation helpers

    /// Format a duration as `HH:MM:SS` (negative values → zero).
    public static func formatDuration(seconds: Int) -> String {
        let total = max(0, seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Wrap an arbitrary string into a YAML-compatible double-quoted scalar, with escaping.
    /// User text (title/source) may contain `:`, `#`, quotes or newlines — double quotes make the
    /// value unambiguously parseable.
    static func quote(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Collapse newlines into spaces — for a single-line markdown heading.
    static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// ISO-8601 representation of a date (symmetric to `SessionManifest`). The formatter is created
    /// locally: `ISO8601DateFormatter` is not `Sendable`, and a shared static would trip a
    /// strict-concurrency error.
    static func iso8601(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
