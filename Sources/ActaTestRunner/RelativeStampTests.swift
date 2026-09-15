import ActaKit
import Foundation
import Testing

/// When a recording happened, as the menu says it.
///
/// ⚠️ **Every input is injected, including "now".** The reason is the midnight boundary: a stamp
/// computed against the wall clock cannot be tested there, and that is exactly where "Today" turns
/// into a claim about a recording made four minutes ago on the previous day.
@Suite("Relative stamps")
struct RelativeStampTests {
    private static func calendar(_ timeZone: String = "Europe/London") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// ⚠️ **macOS puts U+202F, a narrow no-break space, before `PM`** — its own typography, not a
    /// defect, and not something this code should be normalising on the way to the screen. So the
    /// normalising happens here, in the assertion, rather than in the function under test: otherwise
    /// the literal in this file would have to contain an invisible character nobody could see when
    /// reading it, and the next person to edit the test would break it by retyping the line.
    private static func visible(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{202F}", with: " ")
             .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func date(_ iso: String, _ calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: iso)!
    }

    // MARK: - The day boundary

    @Test("today and yesterday are calendar days, not twenty-four-hour intervals")
    func daysAreCalendarDays() {
        let calendar = Self.calendar()
        let now = Self.date("2026-09-12 00:04", calendar)
        // Four minutes ago — and a different day. An elapsed-seconds rule would call this "Today".
        let justBeforeMidnight = Self.date("2026-09-11 23:58", calendar)
        #expect(MeetingInfo.relativeStamp(for: justBeforeMidnight, now: now, calendar: calendar,
                                          locale: Locale(identifier: "en_GB"))
                    .hasPrefix("Yesterday"))
        // Twenty-three hours ago, and the same calendar day.
        let earlyYesterday = Self.date("2026-09-12 01:00", calendar)
        let lateNow = Self.date("2026-09-12 23:30", calendar)
        #expect(MeetingInfo.relativeStamp(for: earlyYesterday, now: lateNow, calendar: calendar,
                                          locale: Locale(identifier: "en_GB"))
                    .hasPrefix("Today"))
    }

    /// ⚠️ The clocks go forward at 01:00 on 29 March 2026 in London, so that day is 23 hours long. A
    /// rule subtracting 86 400 seconds lands in the wrong day on exactly this date.
    @Test("the day a clock changes is still one day")
    func survivesDaylightSaving() {
        let calendar = Self.calendar()
        let now = Self.date("2026-03-29 12:00", calendar)
        let dayBefore = Self.date("2026-03-28 12:00", calendar)
        #expect(MeetingInfo.relativeStamp(for: dayBefore, now: now, calendar: calendar,
                                          locale: Locale(identifier: "en_GB"))
                    .hasPrefix("Yesterday"))
    }

    @Test("a different year is named, because an archive outlives a year")
    func theYearAppearsWhenItDiffers() {
        let calendar = Self.calendar()
        let now = Self.date("2026-09-12 10:00", calendar)
        let thisYear = MeetingInfo.relativeStamp(for: Self.date("2026-02-09 09:40", calendar),
                                                 now: now, calendar: calendar,
                                                 locale: Locale(identifier: "en_GB"))
        let lastYear = MeetingInfo.relativeStamp(for: Self.date("2025-02-09 09:40", calendar),
                                                 now: now, calendar: calendar,
                                                 locale: Locale(identifier: "en_GB"))
        #expect(!thisYear.contains("2026"))
        #expect(lastYear.contains("2025"), Comment(rawValue: "no year in \(lastYear)"))
    }

    // MARK: - The language policy

    /// ⚠️ **This is the policy, stated as a test because it is the kind of thing that drifts.** The
    /// repository's interface is English, so month names are English wherever the Mac is set. What
    /// *does* follow the Mac is the ordering and the hour cycle, because those are regional
    /// conventions rather than language.
    @Test("month names stay English while the hour cycle follows the locale")
    func languageIsEnglishAndConventionsAreLocal() {
        let calendar = Self.calendar()
        let now = Self.date("2026-09-12 10:00", calendar)
        let when = Self.date("2026-02-09 15:40", calendar)

        let russian = MeetingInfo.relativeStamp(for: when, now: now, calendar: calendar,
                                                locale: Locale(identifier: "ru_RU"))
        // English month, not "фев." — and a 24-hour clock, which is what ru_RU uses.
        #expect(russian == "9 Feb 15:40", Comment(rawValue: russian))

        let american = MeetingInfo.relativeStamp(for: when, now: now, calendar: calendar,
                                                 locale: Locale(identifier: "en_US"))
        // Month first, and a 12-hour clock: both are the US convention, and both are followed.
        #expect(Self.visible(american) == "Feb 9 3:40 PM", Comment(rawValue: american))

        let british = MeetingInfo.relativeStamp(for: when, now: now, calendar: calendar,
                                                locale: Locale(identifier: "en_GB"))
        #expect(british == "9 Feb 15:40", Comment(rawValue: british))
    }

    @Test("Today and Yesterday are English in every locale")
    func relativeWordsAreEnglish() {
        let calendar = Self.calendar()
        let now = Self.date("2026-09-12 10:00", calendar)
        let stamp = MeetingInfo.relativeStamp(for: Self.date("2026-09-12 09:00", calendar),
                                              now: now, calendar: calendar,
                                              locale: Locale(identifier: "ru_RU"))
        #expect(stamp == "Today 09:00", Comment(rawValue: stamp))
    }

    /// ⚠️ The calendar carries the time zone, and the stamp must follow it: the same instant is
    /// "Yesterday" in one zone and "Today" in another, and the panel shows the user's.
    @Test("the stamp is read in the calendar's time zone")
    func followsTheTimeZone() {
        let london = Self.calendar()
        let instant = Self.date("2026-09-12 00:30", london)
        let tokyo = Self.calendar("Asia/Tokyo")
        let now = Self.date("2026-09-12 12:00", london)
        #expect(MeetingInfo.relativeStamp(for: instant, now: now, calendar: london,
                                          locale: Locale(identifier: "en_GB")) == "Today 00:30")
        // 00:30 in London is 08:30 the same day in Tokyo — same day there too, different clock face.
        let inTokyo = MeetingInfo.relativeStamp(for: instant, now: now, calendar: tokyo,
                                                locale: Locale(identifier: "en_GB"))
        #expect(inTokyo == "Today 08:30", Comment(rawValue: inTokyo))
    }
}
