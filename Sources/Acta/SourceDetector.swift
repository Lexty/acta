import ActaKit
import AppKit

/// Тонкая обёртка над `NSWorkspace`: собрать имена запущенных приложений и отдать их чистой логике
/// `MeetingSource.detect`. Здесь только доступ к системному списку процессов; само сопоставление
/// имён с известными источниками — в `ActaKit` (покрыто тестами).
enum SourceDetector {
    /// Имена запущенных обычных приложений (`.regular`) — те, что видны в Dock/переключателе.
    static func runningAppNames() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
    }

    /// Распознанный источник встречи среди запущенных приложений, либо `nil`.
    static func detectedSource() -> String? {
        MeetingSource.detect(fromRunningApps: runningAppNames())
    }
}
