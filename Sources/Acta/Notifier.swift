import ActaKit
import Foundation
import UserNotifications
import os

/// Локальные уведомления о сохранении/восстановлении записи (Task 6).
///
/// Тонкая обёртка над `UNUserNotificationCenter`. Работает только в собранном `.app` (есть
/// bundle identifier); при запуске «голого» executable молча ничего не делает, чтобы не падать.
enum Notifier {
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "Notifier")

    /// Доступен ли центр уведомлений (есть bundle identifier — т.е. запущены как `.app`).
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Запросить разрешение на уведомления (один раз, на старте). Тихо игнорирует отказ.
    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.error("Запрос прав на уведомления не удался: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("Права на уведомления: \(granted ? "выданы" : "отклонены", privacy: .public)")
            }
        }
    }

    /// Показать локальное уведомление (немедленно).
    static func notify(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("Показ уведомления не удался: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
