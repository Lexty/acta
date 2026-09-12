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

    /// Append a note to the body of an `info.md`, below the front-matter.
    ///
    /// Recovery needs it for the outcome the front-matter cannot express: a folder whose audio never
    /// reached a track has the `status` and `duration` of an empty recording, and only prose can say
    /// that the segments next to it are the meeting. Idempotent — a note already present is not
    /// repeated, so a re-run cannot stack copies.
    public static func appendingNote(_ contents: String, note: String) -> String {
        guard !contents.contains(note) else { return contents }
        let body = contents.hasSuffix("\n") ? contents : contents + "\n"
        return body + "\n" + note + "\n"
    }

    /// The duration to record in `info.md`, s: the assembled audio's own length, falling back to the
    /// clock only when there is nothing to measure (the assembly failed).
    ///
    /// The clock systematically overstates: `SCStream` does not come up instantly, and for the first
    /// seconds after "Start" is pressed no audio is flowing yet — in a live run 29 s by the clock
    /// against 23.66 s of audio. `info.md` is archival metadata (SPEC §6), and the number in it must
    /// match the file.
    ///
    /// - Parameter measuredSeconds: length of the assembled audio, or `nil` if it could not be built.
    public static func savedDuration(measuredSeconds: Double?, startedAt: Date,
                                     now: Date = Date()) -> Int {
        if let measuredSeconds { return max(0, Int(measuredSeconds.rounded())) }
        return max(0, Int(now.timeIntervalSince(startedAt)))
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

    /// Collapse newlines into spaces — for a single-line markdown heading, and for a menu row.
    ///
    /// ⚠️ **Presentation only.** The stored title keeps its line breaks; this is what a one-line row
    /// shows. Flattening on the way *into* the archive would lose the user's text for good.
    public static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// ISO-8601 representation of a date (symmetric to `SessionManifest`). The formatter is created
    /// locally: `ISO8601DateFormatter` is not `Sendable`, and a shared static would trip a
    /// strict-concurrency error.
    static func iso8601(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - Reading `info.md` back

/// What `info.md` turned out to hold — **every field optional, and nil means "the file did not say"**.
///
/// ⚠️ **Why not `MeetingInfo`.** `MeetingInfo` is what we *write*, and every field of it is required
/// because at write time every field is known. Reading is the opposite situation: the file may predate
/// a field, may have been hand-edited, may be half-written after a crash. A parser that returned
/// `MeetingInfo` would have to invent a date or a duration to satisfy the type — and an invented
/// duration displayed next to a real one is exactly the class of defect this project keeps finding.
/// Absent stays absent all the way to the view, which then shows nothing rather than a guess.
public struct ArchivedMeetingInfo: Equatable, Sendable {
    public var title: String?
    public var date: Date?
    public var source: String?
    public var durationSeconds: Int?
    public var status: SessionManifest.Status?

    public init(title: String? = nil, date: Date? = nil, source: String? = nil,
                durationSeconds: Int? = nil, status: SessionManifest.Status? = nil) {
        self.title = title
        self.date = date
        self.source = source
        self.durationSeconds = durationSeconds
        self.status = status
    }

    /// Whether the file said nothing we could use. A front-matter block that parsed but held no
    /// recognised key is as useless to a caller as no front matter at all.
    public var isEmpty: Bool {
        title == nil && date == nil && source == nil && durationSeconds == nil && status == nil
    }
}

extension MeetingInfo {
    /// Parse the front matter out of a **bounded prefix of the file's bytes**.
    ///
    /// ⚠️ **Why this exists rather than decoding the prefix and calling `parse(_:)`.** A prefix cut at
    /// a fixed byte count can land in the middle of a multi-byte character *in the body* — one `é`
    /// straddling the boundary makes `String(data:encoding:.utf8)` return nil for the whole prefix, and
    /// a perfectly valid header a few hundred bytes earlier is lost with it. Found by Codex and
    /// reproduced here before the fix. So the closing fence is located **in bytes**, and only the slice
    /// up to it is decoded — a slice that ends on a line boundary and therefore never splits a
    /// character.
    ///
    /// ⚠️ **Strictly decoded, never repaired.** If the front matter itself is not valid UTF-8 the
    /// answer is nil. Replacing malformed bytes with `U+FFFD` would turn a corrupted title into a
    /// plausible-looking one, which is the outcome this whole reader exists to avoid.
    public static func parse(prefix data: Data) -> ArchivedMeetingInfo? {
        let newline = UInt8(ascii: "\n")
        let fence: [UInt8] = [UInt8(ascii: "-"), UInt8(ascii: "-"), UInt8(ascii: "-")]
        let bytes = Array(data)

        // Line boundaries, as byte ranges, so nothing here has to decode to find a fence.
        var lines: [Range<Int>] = []
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == newline {
            lines.append(start..<index)
            start = index + 1
        }
        // A final line with no terminator cannot be a *closing* fence in a file we are reading a
        // prefix of: we could not tell a complete `---` from the first three dashes of something else.
        func isFence(_ range: Range<Int>) -> Bool { Array(bytes[range]) == fence }

        guard let opening = lines.firstIndex(where: { !$0.isEmpty }),
              isFence(lines[opening]),
              let closing = lines[(opening + 1)...].firstIndex(where: isFence) else {
            return nil
        }
        let slice = Data(bytes[lines[opening].lowerBound..<lines[closing].upperBound])
        guard let text = String(data: slice, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Parse the front matter `rendered()` writes. Returns nil when there is no front-matter block —
    /// which is a different answer from "a block with nothing in it we understood".
    ///
    /// ⚠️ **Deliberately not a YAML parser.** It reads the block between the first pair of `---`
    /// exactly as `patchedFrontMatter` does, and every value it cannot make sense of becomes nil
    /// rather than a default. The one asymmetry with `rendered()` worth naming: `duration` is written
    /// as a *formatted* `HH:MM:SS` string, so reading it back is parsing a display format — the seconds
    /// it yields are therefore whole, and a file whose duration is not three numeric fields yields nil.
    public static func parse(_ contents: String) -> ArchivedMeetingInfo? {
        let lines = contents.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.isEmpty }), lines[first] == "---",
              let closing = lines[(first + 1)...].firstIndex(of: "---") else {
            return nil
        }
        var info = ArchivedMeetingInfo()
        // ⚠️ **A key seen twice makes that field unknown, rather than last-one-wins.** Two `title:`
        // lines are a file we do not understand; picking one of them is picking at random and
        // presenting the result as fact. Only the repeated field is lost — the rest of the block is
        // still perfectly legible.
        var seen = Set<String>()
        for line in lines[(first + 1)..<closing] {
            // Split at the **first** colon only: every value we write may contain one, and a title
            // reading "Acta: the meeting" is ordinary.
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator])
            let rest = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard ["title", "source", "date", "duration", "status"].contains(key) else { continue }
            guard seen.insert(key).inserted else {
                switch key {
                case "title": info.title = nil
                case "source": info.source = nil
                case "date": info.date = nil
                case "duration": info.durationSeconds = nil
                default: info.status = nil
                }
                continue
            }
            switch key {
            case "title": info.title = unquote(rest).flatMap { $0.isEmpty ? nil : $0 }
            case "source": info.source = unquote(rest).flatMap { $0.isEmpty ? nil : $0 }
            case "date": info.date = ISO8601DateFormatter().date(from: rest)
            case "duration": info.durationSeconds = unquote(rest).flatMap(parseDuration)
            default: info.status = SessionManifest.Status(rawValue: rest)
            }
        }
        return info
    }

    /// Undo `quote(_:)` — **and accept nothing else**.
    ///
    /// ⚠️ **The supported form is the one this file writes, exactly.** `quote(_:)` always emits a
    /// double-quoted scalar and escapes precisely five characters, so a value that is not quoted, that
    /// carries an escape we never produce, or that has anything but whitespace after its closing quote
    /// is a line we have misread — not a title. Returning a plausible string from it is the failure
    /// mode that matters here: the menu would state a fact, confidently, about a file it did not
    /// understand.
    ///
    /// Each of these was a real answer before this was tightened: `"A\qB"` came back as `AqB` with the
    /// backslash quietly dropped, `"Real" garbage` came back as `Real`, and a YAML block indicator
    /// (`title: |`) came back as the title `|`.
    ///
    /// ⚠️ Not applied to `date` and `status`: those are written unquoted and are validated by
    /// `ISO8601DateFormatter` and `Status(rawValue:)`, each of which refuses what it does not know.
    static func unquote(_ value: String) -> String? {
        var characters = Substring(value)
        guard characters.first == "\"" else { return nil }
        characters = characters.dropFirst()
        var result = ""
        while let character = characters.first {
            characters = characters.dropFirst()
            switch character {
            case "\"":
                // Only whitespace may follow the closing quote — `rendered()` writes none at all.
                return characters.allSatisfy(\.isWhitespace) ? result : nil
            case "\\":
                guard let escaped = characters.first else { return nil }
                characters = characters.dropFirst()
                switch escaped {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\", "\"": result.append(escaped)
                // An escape `quote(_:)` does not emit. We do not know what the writer meant.
                default: return nil
                }
            default:
                result.append(character)
            }
        }
        // Ran out of characters without a closing quote: a truncated value, not a valid one.
        return nil
    }

    /// `HH:MM:SS` back to seconds. Anything else — an empty string, two fields, a negative, a word,
    /// seventy-five minutes — is nil, because a duration shown wrong is worse than a duration not
    /// shown.
    ///
    /// ⚠️ **Hours are unbounded, minutes and seconds are not.** `formatDuration` writes hours
    /// unpadded beyond two digits, so a twenty-six-hour recording is `26:00:00` and must read back;
    /// but `00:75:00` is not a duration this project ever wrote, and accepting it as an hour and a
    /// quarter would invent a number out of a malformed file. The arithmetic is overflow-checked for
    /// the same reason: a huge hour field must fail, not wrap into something plausible.
    static func parseDuration(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        guard numbers[1] < 60, numbers[2] < 60 else { return nil }
        let (minutes, overflow) = numbers[0].multipliedReportingOverflow(by: 3600)
        guard !overflow else { return nil }
        let (sum, overflow2) = minutes.addingReportingOverflow(numbers[1] * 60 + numbers[2])
        guard !overflow2 else { return nil }
        return sum
    }
}

// MARK: - Display formatting

extension MeetingInfo {
    /// A duration for reading rather than for `info.md`: `41:12`, `1:07:55`. The hour is dropped when
    /// it is zero, which is the common case, and never zero-padded when it is not.
    ///
    /// ⚠️ Separate from `formatDuration(seconds:)` on purpose. That one is a **file format** — fixed
    /// width, parsed back by `parse(_:)` — and changing it to look nicer would change what is written
    /// to disk. Two jobs, two functions.
    public static func formatCompactDuration(seconds: Int) -> String {
        let total = max(0, seconds)
        let (hours, minutes, remainder) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
                         : String(format: "%d:%02d", minutes, remainder)
    }

    /// When a recording happened, as a person would say it: `Today 20:07`, `Yesterday 18:05`,
    /// `9 Sep 09:40`.
    ///
    /// ⚠️ **Every input is a parameter, including "now".** A relative stamp computed against the wall
    /// clock cannot be tested for the boundary that actually matters — midnight — and that boundary is
    /// where "Today" silently becomes a lie about a recording made four minutes ago.
    ///
    /// ⚠️ **The time format follows the locale, not a hardcoded 24-hour pattern.** A Mac set to
    /// 12-hour time shows 12-hour time everywhere else; `dateFormat(fromTemplate:)` is what makes the
    /// panel agree with the rest of the system instead of imposing the developer's clock.
    public static func relativeStamp(for date: Date, now: Date = Date(),
                                     calendar: Calendar = .current,
                                     locale: Locale = .current) -> String {
        let time = formatted(date, template: "jmm", calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        // Within the same calendar year the year is noise; outside it, it is the point.
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = formatted(date, template: sameYear ? "dMMM" : "dMMMyyyy",
                            calendar: calendar, locale: locale)
        return "\(day) \(time)"
    }

    /// A rendering that takes its **conventions** from the user's locale and its **language** from
    /// English.
    ///
    /// ⚠️ **Two locales, deliberately, and the split is the whole point.** The pattern comes from the
    /// user's locale, so field order and the twelve-versus-twenty-four-hour cycle are the ones their
    /// Mac uses everywhere else; the rendering is done under `en_US_POSIX`, so the month name is
    /// English like the rest of this interface. Passing the user's locale to the formatter as well —
    /// which is what this function did first — produced `9 февр. 15:40` on a Russian Mac: a stamp half
    /// in each language, next to a `Today` that could only ever be English.
    ///
    /// The formatter is built per call: `DateFormatter` is not `Sendable`, and a shared static would
    /// be both a data race and a cache of the wrong locale.
    private static func formatted(_ date: Date, template: String,
                                  calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0,
                                                        locale: locale) ?? template
        return formatter.string(from: date)
    }
}
