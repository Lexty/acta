import Foundation

/// Pure logic that auto-suggests the meeting source from the list of running applications.
///
/// The runtime (`SourceDetector` in the `Acta` target) collects running application names via
/// `NSWorkspace` and passes them here; matching a name against a known messenger/conferencing app
/// is **pure logic**, so it lives in `ActaKit` and is covered by unit tests (`MeetingSourceTests`)
/// rather than checked by hand by running the app.
public enum MeetingSource {
    /// Known meeting-source apps: a substring of the process name → a human-readable name.
    /// The order defines priority: if several are running, the first match in this list wins.
    public static let known: [(needle: String, name: String)] = [
        ("zoom", "Zoom"),
        ("microsoft teams", "Microsoft Teams"),
        ("teams", "Microsoft Teams"),
        ("webex", "Webex"),
        ("slack", "Slack"),
        ("discord", "Discord"),
        ("skype", "Skype"),
        ("facetime", "FaceTime"),
        ("telegram", "Telegram"),
        ("whatsapp", "WhatsApp"),
        ("google meet", "Google Meet")
    ]

    /// Determine the most likely meeting source from the names of running applications.
    ///
    /// Matching is case-insensitive and by substring (`"Slack"` matches `"slack"`). Priority comes
    /// from the order of `known`, not the order of `appNames`, so the result is deterministic.
    /// Returns `nil` if nothing familiar is running.
    public static func detect(fromRunningApps appNames: [String]) -> String? {
        let lowered = appNames.map { $0.lowercased() }
        for entry in known where lowered.contains(where: { $0.contains(entry.needle) }) {
            return entry.name
        }
        return nil
    }

    /// Default suggested title: `"<Source> — YYYY-MM-DD HH:MM"`, or `"Meeting YYYY-MM-DD HH:MM"`
    /// if the source was not recognised. Date formatting is local; `timeZone` is a parameter for
    /// test determinism.
    public static func suggestedTitle(source: String?, date: Date,
                                      timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = formatter.string(from: date)
        if let source, !source.isEmpty {
            return "\(source) — \(stamp)"
        }
        return "Meeting \(stamp)"
    }
}
