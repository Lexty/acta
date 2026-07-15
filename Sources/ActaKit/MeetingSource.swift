import Foundation

/// Чистая логика авто-подсказки источника встречи по списку запущенных приложений.
///
/// Runtime (`SourceDetector` в таргете `Acta`) собирает имена запущенных приложений через
/// `NSWorkspace` и передаёт их сюда; сопоставление имени с известным мессенджером/конференцией —
/// **чистая логика**, поэтому живёт в `ActaKit` и покрыта юнит-тестами (`MeetingSourceTests`),
/// а не проверяется вручную прогоном приложения.
public enum MeetingSource {
    /// Известные приложения-источники встреч: подстрока имени процесса → человекочитаемое имя.
    /// Порядок задаёт приоритет: если запущено несколько, выбирается первый совпавший в этом списке.
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

    /// Определить наиболее вероятный источник встречи по именам запущенных приложений.
    ///
    /// Сопоставление регистронезависимо и по подстроке (`"Slack"` матчит `"slack"`). Приоритет —
    /// по порядку `known`, а не по порядку `appNames`, чтобы результат был детерминирован. `nil`,
    /// если ничего знакомого не запущено.
    public static func detect(fromRunningApps appNames: [String]) -> String? {
        let lowered = appNames.map { $0.lowercased() }
        for entry in known where lowered.contains(where: { $0.contains(entry.needle) }) {
            return entry.name
        }
        return nil
    }

    /// Заголовок-подсказка по умолчанию: `"<Источник> — YYYY-MM-DD HH:MM"` или, если источник не
    /// распознан, `"Встреча YYYY-MM-DD HH:MM"`. Форматирование даты локальное; `timeZone` вынесен
    /// параметром ради детерминизма теста.
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
        return "Встреча \(stamp)"
    }
}
