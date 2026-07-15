import Testing
import Foundation
import ActaKit

// The archive layout and info.md serialization - pure logic, covered separately from the file
// system.

// MARK: - Slug

@Test
func slugLowercasesAndHyphenatesSpacesAndPunctuation() {
    #expect(MeetingArchive.slug(from: "Weekly Sync") == "weekly-sync")
    #expect(MeetingArchive.slug(from: "Design: Q3 Roadmap!") == "design-q3-roadmap")
    #expect(MeetingArchive.slug(from: "  a  b  ") == "a-b")
}

@Test
func slugCollapsesSeparatorsAndTrimsEdges() {
    #expect(MeetingArchive.slug(from: "--Hello---World--") == "hello-world")
    #expect(MeetingArchive.slug(from: "a___b...c") == "a-b-c")
}

@Test
func slugKeepsUnicodeLetters() {
    // Cyrillic is valid in macOS file names - we do not strip it. This asserts that a Cyrillic
    // title slugs correctly; both strings are written as Unicode escapes to keep the sources
    // ASCII-only. Title "Sozvon s komandoy" -> slug "sozvon-s-komandoy" in Cyrillic letters.
    let title = "\u{0421}\u{043E}\u{0437}\u{0432}\u{043E}\u{043D} "
        + "\u{0441} "
        + "\u{043A}\u{043E}\u{043C}\u{0430}\u{043D}\u{0434}\u{043E}\u{0439}"
    let expected = "\u{0441}\u{043E}\u{0437}\u{0432}\u{043E}\u{043D}-"
        + "\u{0441}-"
        + "\u{043A}\u{043E}\u{043C}\u{0430}\u{043D}\u{0434}\u{043E}\u{0439}"
    #expect(MeetingArchive.slug(from: title) == expected)
}

@Test
func slugFallsBackWhenEmpty() {
    #expect(MeetingArchive.slug(from: "") == MeetingArchive.fallbackSlug)
    #expect(MeetingArchive.slug(from: "!!! ??? ...") == MeetingArchive.fallbackSlug)
}

@Test
func slugTruncatesToMaxLengthWithoutTrailingHyphen() {
    let slug = MeetingArchive.slug(from: String(repeating: "a", count: 100), maxLength: 10)
    #expect(slug.count == 10)
    #expect(slug.hasSuffix("-") == false)

    // Truncation must not leave a dangling separator.
    let trimmed = MeetingArchive.slug(from: "aaaaaaaaaa bbbbb", maxLength: 11)
    #expect(trimmed == "aaaaaaaaaa")
}

// MARK: - Folder name

@Test
func folderNameFormatsDateAndSlug() {
    // 1_700_000_000 = 2023-11-14T22:13:20Z.
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let name = MeetingArchive.folderName(date: date, slug: "weekly-sync",
                                         timeZone: TimeZone(identifier: "UTC")!)
    #expect(name == "2023-11-14_2213__weekly-sync")
}

// MARK: - info.md / YAML front-matter

@Test
func formatDurationIsHHMMSS() {
    #expect(MeetingInfo.formatDuration(seconds: 0) == "00:00:00")
    #expect(MeetingInfo.formatDuration(seconds: 5) == "00:00:05")
    #expect(MeetingInfo.formatDuration(seconds: 3661) == "01:01:01")
    #expect(MeetingInfo.formatDuration(seconds: -10) == "00:00:00")
}

@Test
func renderedInfoHasFrontMatterFields() {
    let info = MeetingInfo(title: "Weekly Sync",
                           date: Date(timeIntervalSince1970: 1_700_000_000),
                           source: "Slack", durationSeconds: 3661, status: .done)
    let text = info.rendered()
    #expect(text.hasPrefix("---\n"))
    #expect(text.contains("title: \"Weekly Sync\""))
    #expect(text.contains("date: 2023-11-14T22:13:20Z"))
    #expect(text.contains("source: \"Slack\""))
    #expect(text.contains("duration: \"01:01:01\""))
    #expect(text.contains("status: done"))
    // The front-matter is closed by a second line of three hyphens.
    let dashRuns = text.components(separatedBy: "\n---").count - 1
    #expect(dashRuns >= 1)
    #expect(text.contains("\n# Weekly Sync"))
}

@Test
func renderedInfoQuotesSpecialCharacters() {
    let info = MeetingInfo(title: "Q3: \"plan\" #1\nline2",
                           date: Date(timeIntervalSince1970: 0),
                           source: "", durationSeconds: 0, status: .recovered)
    let text = info.rendered()
    // Quotes and backslashes are escaped, the newline is folded into \n inside the scalar.
    #expect(text.contains("title: \"Q3: \\\"plan\\\" #1\\nline2\""))
    #expect(text.contains("source: \"\""))
    #expect(text.contains("status: recovered"))
    // The markdown heading is single-line (the newline is collapsed into a space).
    #expect(text.contains("# Q3: \"plan\" #1 line2"))
}

// MARK: - Patching the front-matter during recovery

@Test
func patchedFrontMatterUpdatesStatusAndDurationOnly() {
    let original = MeetingInfo(title: "Weekly Sync", date: Date(timeIntervalSince1970: 0),
                              source: "Slack", durationSeconds: 0, status: .recording).rendered()
    let patched = MeetingInfo.patchedFrontMatter(original, status: .recovered, durationSeconds: 3661)

    #expect(patched.contains("status: recovered"))
    #expect(patched.contains("duration: \"01:01:01\""))
    // Recovery knows nothing about the other fields and does not touch them.
    #expect(patched.contains("title: \"Weekly Sync\""))
    #expect(patched.contains("source: \"Slack\""))
    #expect(patched.contains("# Weekly Sync"))
    #expect(patched.contains("status: recording") == false)
    #expect(patched.contains("duration: \"00:00:00\"") == false)
}

@Test
func patchedFrontMatterLeavesUnrecognizedContentsIntact() {
    // No front-matter -> stale metadata is better than a corrupted file.
    #expect(MeetingInfo.patchedFrontMatter("# Just a note\n", status: .recovered,
                                          durationSeconds: 10) == "# Just a note\n")
    // An unclosed front-matter is left alone as well.
    let unclosed = "---\nstatus: recording\n"
    #expect(MeetingInfo.patchedFrontMatter(unclosed, status: .done, durationSeconds: 5) == unclosed)
}

@Test
func patchedFrontMatterIgnoresBodyLinesLookingLikeFields() {
    // We only edit inside the front-matter: a body line with the same prefix stays as is.
    let contents = "---\nstatus: recording\n---\n\nstatus: recording\n"
    let patched = MeetingInfo.patchedFrontMatter(contents, status: .recovered, durationSeconds: 0)
    #expect(patched == "---\nstatus: recovered\n---\n\nstatus: recording\n")
}

// MARK: - savedDuration

@Test
func savedDurationPrefersTheMeasuredAudioOverTheClock() {
    // The clock overstates: SCStream takes seconds to come up and no audio flows until it does. The
    // assembled file's own length is what info.md must report.
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let now = startedAt.addingTimeInterval(29)
    #expect(MeetingInfo.savedDuration(measuredSeconds: 23.66, startedAt: startedAt, now: now) == 24)
}

@Test
func savedDurationFallsBackToTheClockWhenThereIsNothingToMeasure() {
    // The assembly failed, so there is no file to measure — the clock is all we have.
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let now = startedAt.addingTimeInterval(29.4)
    #expect(MeetingInfo.savedDuration(measuredSeconds: nil, startedAt: startedAt, now: now) == 29)
}

@Test
func savedDurationNeverGoesNegative() {
    // A clock stepped backwards mid-recording must not put a negative duration into info.md.
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let now = startedAt.addingTimeInterval(-5)
    #expect(MeetingInfo.savedDuration(measuredSeconds: nil, startedAt: startedAt, now: now) == 0)
    #expect(MeetingInfo.savedDuration(measuredSeconds: -2, startedAt: startedAt, now: now) == 0)
}
