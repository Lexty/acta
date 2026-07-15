import ActaKit
import Foundation
import UserNotifications
import os

/// Local notifications about a recording being saved/recovered (Task 6).
///
/// A thin wrapper over `UNUserNotificationCenter`. Works only inside a built `.app` (which has a
/// bundle identifier); when running the bare executable it silently does nothing so as not to crash.
enum Notifier {
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "Notifier")

    /// Whether the notification center is available (a bundle identifier exists — i.e. running as `.app`).
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Request notification permission (once, at startup). Silently ignores a denial.
    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                let reason = error.localizedDescription
                log.error("Notification permission request failed: \(reason, privacy: .public)")
            } else {
                log.info("Notification permission: \(granted ? "granted" : "denied", privacy: .public)")
            }
        }
    }

    /// Show a local notification (immediately).
    static func notify(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("Showing the notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
