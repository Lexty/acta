import ActaKit
import Foundation
import Testing

/// Reading `info.md` back, and the two display formats the menu draws from it.
///
/// ⚠️ **The parser is the reader for front matter Acta itself emits — not a YAML parser.** Every test
/// here is either a round trip through `rendered()` or a malformed file that must answer "unknown"
/// rather than something plausible. That distinction is the whole contract: a wrong title in the menu
/// is a recording the user cannot find.
@Suite("Reading info.md")
struct MeetingInfoReadingTests {
    private static func info(title: String, duration: Int = 2_472,
                             status: SessionManifest.Status = .done) -> MeetingInfo {
        MeetingInfo(title: title, date: Date(timeIntervalSince1970: 1_757_620_020),
                    source: "Telegram", durationSeconds: duration, status: status)
    }

    // MARK: - Round trips

    @Test("what rendered() writes, parse() reads back")
    func roundTrip() throws {
        let original = Self.info(title: "Планёрка по acta — приёмка dev-сборки")
        let parsed = try #require(MeetingInfo.parse(original.rendered()))
        #expect(parsed.title == original.title)
        #expect(parsed.source == original.source)
        #expect(parsed.durationSeconds == original.durationSeconds)
        #expect(parsed.status == original.status)
        // ⚠️ Compared to the second: `rendered()` writes ISO-8601 without sub-second precision, so the
        // date that comes back is the truncated one. Asserting equality on `Date` would be asserting
        // a precision the file format does not carry.
        let parsedDate = try #require(parsed.date)
        #expect(abs(parsedDate.timeIntervalSince(original.date)) < 1)
    }

    /// ⚠️ Every character `quote(_:)` escapes, in one title, plus the two that make a naive
    /// split-on-colon parser wrong.
    @Test("titles survive quotes, backslashes, colons, hashes, newlines and tabs")
    func roundTripsHostileTitles() throws {
        let hostile = [
            #"Acta: the meeting"#,
            #"a "quoted" thing"#,
            #"back\slash"#,
            "line\nbreak",
            "tab\there",
            "# not a heading",
            "日本語のタイトル — с кириллицей",
            #"everything: "at\once"# + "\n#\t" + #"\"#,
        ]
        for title in hostile {
            let parsed = try #require(MeetingInfo.parse(Self.info(title: title).rendered()),
                                      Comment(rawValue: "no front matter for \(title.debugDescription)"))
            #expect(parsed.title == title, Comment(rawValue: "round trip lost \(title.debugDescription)"))
        }
    }

    // MARK: - What is refused

    @Test("no front-matter block is nil, not an empty record")
    func requiresTheBlock() {
        #expect(MeetingInfo.parse("") == nil)
        #expect(MeetingInfo.parse("# Just a heading\n\ntitle: \"not in a block\"") == nil)
        // An opening fence with no closing one: a truncated file, not a record.
        #expect(MeetingInfo.parse("---\ntitle: \"half\"\n") == nil)
    }

    /// ⚠️ **The body is not the front matter.** A transcript pasted under the heading — which is what
    /// the archive doc invites the user's Claude Code to do — must not be able to overwrite a field.
    @Test("fields are read only from inside the block")
    func ignoresTheBody() throws {
        let text = """
            ---
            title: "The real one"
            status: done
            ---

            # The real one

            title: "pasted into the transcript"
            status: recording
            """
        let parsed = try #require(MeetingInfo.parse(text))
        #expect(parsed.title == "The real one")
        #expect(parsed.status == .done)
    }

    @Test("a key that appears twice makes that field unknown, not the last value")
    func duplicateKeyPoisonsItsField() throws {
        let text = """
            ---
            title: "first"
            source: "kept"
            title: "second"
            ---
            """
        let parsed = try #require(MeetingInfo.parse(text))
        #expect(parsed.title == nil)
        // Only the repeated field is lost.
        #expect(parsed.source == "kept")
    }

    @Test("a value that is not understood is nil rather than a plausible default")
    func refusesRatherThanGuesses() throws {
        let text = """
            ---
            title: "ok"
            date: yesterday afternoon
            duration: "a while"
            status: paused
            ---
            """
        let parsed = try #require(MeetingInfo.parse(text))
        #expect(parsed.title == "ok")
        #expect(parsed.date == nil)
        #expect(parsed.durationSeconds == nil)
        #expect(parsed.status == nil)
    }

    /// ⚠️ **The supported subset is exactly what `quote(_:)` emits, and nothing else.** Found by
    /// Codex against this commit's source: an unknown escape came back with the backslash silently
    /// dropped, trailing junk after the closing quote was ignored, and a YAML block indicator was
    /// returned as if it were a title. Each of those turns a file we do not understand into a
    /// confident, wrong sentence in the menu.
    @Test("scalars we did not write are refused rather than interpreted")
    func refusesScalarFormsWeNeverWrite() throws {
        func title(_ line: String) throws -> String? {
            try #require(MeetingInfo.parse("---\n\(line)\n---")).title
        }
        // An escape the writer never emits: not silently swallowed into "AqB".
        #expect(try title(#"title: "A\qB""#) == nil)
        // Anything but whitespace after the closing quote means we misread the line.
        #expect(try title(#"title: "Real" garbage"#) == nil)
        // A YAML block scalar is not a title that happens to be "|".
        #expect(try title("title: |") == nil)
        #expect(try title("title: >-") == nil)
        // A plain unquoted scalar is not a form this writer produces for a title.
        #expect(try title("title: plain") == nil)
        // What we *do* write still reads, including trailing whitespace after the quote.
        #expect(try title(#"title: "Kept"  "#) == "Kept")
        #expect(try title(#"title: "a \"quoted\" thing""#) == #"a "quoted" thing"#)
        #expect(try title(#"title: "back\\slash""#) == #"back\slash"#)
        #expect(try title(#"title: "line\nbreak""#) == "line\nbreak")
    }

    @Test("an unterminated quoted scalar is not a string we understood")
    func refusesUnterminatedQuote() throws {
        let parsed = try #require(MeetingInfo.parse("---\ntitle: \"never closed\nsource: \"ok\"\n---"))
        #expect(parsed.title == nil)
    }

    @Test("a block with nothing we recognise is empty, and says so")
    func emptyRecord() throws {
        let parsed = try #require(MeetingInfo.parse("---\nunrelated: 4\n---"))
        #expect(parsed.isEmpty)
    }

    // MARK: - Durations

    /// Durations, read through the public surface the app actually uses — `parse(_:)` on a real
    /// front-matter block — rather than through the internal helper. The helper is not part of the
    /// contract; what a caller can observe is.
    ///
    /// ⚠️ Hours are unbounded because `formatDuration` writes them unbounded; minutes and seconds are
    /// not, because `00:75:00` is not something this project ever wrote, and reading it as an hour and
    /// a quarter would invent a number out of a malformed file.
    @Test("durations are three checked fields, hours unbounded")
    func durationBounds() throws {
        func seconds(_ written: String) throws -> Int? {
            try #require(MeetingInfo.parse("---\nduration: \"\(written)\"\n---")).durationSeconds
        }
        #expect(try seconds("00:41:12") == 2_472)
        #expect(try seconds("01:07:55") == 4_075)
        #expect(try seconds("26:00:00") == 93_600)
        #expect(try seconds("00:00:00") == 0)
        #expect(try seconds("00:75:00") == nil)
        #expect(try seconds("00:00:60") == nil)
        #expect(try seconds("41:12") == nil)
        #expect(try seconds("-1:00:00") == nil)
        #expect(try seconds("") == nil)
        #expect(try seconds("::") == nil)
        // Overflow must fail rather than wrap into a plausible number of seconds.
        #expect(try seconds("9999999999999999999:00:00") == nil)
    }

    // MARK: - Display

    @Test("the compact duration drops a zero hour and never pads a real one")
    func compactDuration() {
        #expect(MeetingInfo.formatCompactDuration(seconds: 2_472) == "41:12")
        #expect(MeetingInfo.formatCompactDuration(seconds: 4_075) == "1:07:55")
        #expect(MeetingInfo.formatCompactDuration(seconds: 0) == "0:00")
        #expect(MeetingInfo.formatCompactDuration(seconds: -5) == "0:00")
        // The file format is a separate function and keeps its fixed width.
        #expect(MeetingInfo.formatDuration(seconds: 2_472) == "00:41:12")
    }
}
