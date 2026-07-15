import Testing
import Foundation
import ActaKit

// Авто-подсказка источника встречи по запущенным приложениям — чистая логика, покрыта отдельно
// от NSWorkspace (FS/системную часть даёт SourceDetector в таргете Acta).

// MARK: - detect

@Test
func detectMatchesKnownAppCaseInsensitively() {
    #expect(MeetingSource.detect(fromRunningApps: ["Finder", "zoom.us"]) == "Zoom")
    #expect(MeetingSource.detect(fromRunningApps: ["SLACK"]) == "Slack")
    #expect(MeetingSource.detect(fromRunningApps: ["Microsoft Teams"]) == "Microsoft Teams")
}

@Test
func detectReturnsNilWhenNothingKnownRunning() {
    #expect(MeetingSource.detect(fromRunningApps: ["Finder", "Notes", "Xcode"]) == nil)
    #expect(MeetingSource.detect(fromRunningApps: []) == nil)
}

@Test
func detectPriorityFollowsKnownOrderNotAppOrder() {
    // Приоритет — по порядку `known` (Zoom раньше Slack), а не по порядку в списке приложений.
    #expect(MeetingSource.detect(fromRunningApps: ["Slack", "zoom.us"]) == "Zoom")
    #expect(MeetingSource.detect(fromRunningApps: ["zoom.us", "Slack"]) == "Zoom")
}

@Test
func detectMatchesSubstring() {
    // Имя процесса может отличаться от бренда — матчим по подстроке.
    #expect(MeetingSource.detect(fromRunningApps: ["Discord Canary"]) == "Discord")
}

// MARK: - suggestedTitle

@Test
func suggestedTitleUsesSourceWhenKnown() {
    let date = Date(timeIntervalSince1970: 1_700_000_000) // фиксированная точка
    let utc = TimeZone(identifier: "UTC")!
    let title = MeetingSource.suggestedTitle(source: "Zoom", date: date, timeZone: utc)
    #expect(title == "Zoom — 2023-11-14 22:13")
}

@Test
func suggestedTitleFallsBackWhenSourceUnknown() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let utc = TimeZone(identifier: "UTC")!
    #expect(MeetingSource.suggestedTitle(source: nil, date: date, timeZone: utc)
            == "Встреча 2023-11-14 22:13")
    #expect(MeetingSource.suggestedTitle(source: "", date: date, timeZone: utc)
            == "Встреча 2023-11-14 22:13")
}
