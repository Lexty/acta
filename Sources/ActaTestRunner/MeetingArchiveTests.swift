import Testing
import Foundation
import ActaKit

// Раскладка архива и сериализация info.md — чистая логика, покрыта отдельно от файловой системы.

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
    // Кириллица валидна в именах файлов macOS — не режем её.
    #expect(MeetingArchive.slug(from: "Созвон с командой") == "созвон-с-командой")
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

    // Обрезка не должна оставлять висящий разделитель.
    let trimmed = MeetingArchive.slug(from: "aaaaaaaaaa bbbbb", maxLength: 11)
    #expect(trimmed == "aaaaaaaaaa")
}

// MARK: - Имя папки

@Test
func folderNameFormatsDateAndSlug() {
    // 1_700_000_000 = 2023-11-14T22:13:20Z.
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let name = MeetingArchive.folderName(date: date, slug: "weekly-sync",
                                         timeZone: TimeZone(identifier: "UTC")!)
    #expect(name == "2023-11-14_2213__weekly-sync")
}

@Test
func folderNameFromTitleBuildsSlug() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let name = MeetingArchive.folderName(date: date, title: "Weekly Sync",
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
    // Front-matter закрывается второй строкой из трёх дефисов.
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
    // Кавычки и обратный слэш экранированы, перевод строки свёрнут в \n внутри скаляра.
    #expect(text.contains("title: \"Q3: \\\"plan\\\" #1\\nline2\""))
    #expect(text.contains("source: \"\""))
    #expect(text.contains("status: recovered"))
    // markdown-заголовок — однострочный (перевод строки схлопнут в пробел).
    #expect(text.contains("# Q3: \"plan\" #1 line2"))
}
