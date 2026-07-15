import Testing
import Foundation
import ActaKit

// Auto-suggesting the meeting source from the running applications - pure logic, covered
// separately from NSWorkspace (the FS/system part is provided by SourceDetector in the Acta
// target).

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
    // Priority follows the order of `known` (Zoom before Slack), not the order of the app list.
    #expect(MeetingSource.detect(fromRunningApps: ["Slack", "zoom.us"]) == "Zoom")
    #expect(MeetingSource.detect(fromRunningApps: ["zoom.us", "Slack"]) == "Zoom")
}

@Test
func detectMatchesSubstring() {
    // The process name may differ from the brand name - we match on a substring.
    #expect(MeetingSource.detect(fromRunningApps: ["Discord Canary"]) == "Discord")
}

// MARK: - suggestedTitle

@Test
func suggestedTitleUsesSourceWhenKnown() {
    let date = Date(timeIntervalSince1970: 1_700_000_000) // a fixed point in time
    let utc = TimeZone(identifier: "UTC")!
    let title = MeetingSource.suggestedTitle(source: "Zoom", date: date, timeZone: utc)
    #expect(title == "Zoom — 2023-11-14 22:13")
}

@Test
func suggestedTitleFallsBackWhenSourceUnknown() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let utc = TimeZone(identifier: "UTC")!
    #expect(MeetingSource.suggestedTitle(source: nil, date: date, timeZone: utc)
            == "Meeting 2023-11-14 22:13")
    #expect(MeetingSource.suggestedTitle(source: "", date: date, timeZone: utc)
            == "Meeting 2023-11-14 22:13")
}
