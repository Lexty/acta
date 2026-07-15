import ActaKit
import Foundation
import os

/// Персистентность пользовательских настроек записи (`RecordingSettings`).
///
/// Хранит один JSON-блоб в `UserDefaults` под ключом `settings`. Работает и вне `.app`-бандла
/// (UserDefaults доступен всегда), поэтому безопасен в юнит-раннере/скриптах. Разрешение пути архива
/// в конкретный URL и вся нормализация — чистая логика `RecordingSettings` (покрыта тестами); тут
/// только чтение/запись и подстановка домашней папки.
struct SettingsStore {
    private static let key = "settings"

    private let log = Logger(subsystem: AppInfo.bundleID, category: "SettingsStore")
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Прочитать настройки (нормализованные). Отсутствие/битый JSON → значения по умолчанию.
    func load() -> RecordingSettings {
        guard let data = defaults.data(forKey: Self.key) else { return .default }
        do {
            return try JSONDecoder().decode(RecordingSettings.self, from: data).normalized()
        } catch {
            log.error("Не удалось разобрать настройки, беру дефолт: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    /// Сохранить настройки (перед записью нормализуются).
    func save(_ settings: RecordingSettings) {
        let normalized = settings.normalized()
        do {
            let data = try JSONEncoder().encode(normalized)
            defaults.set(data, forKey: Self.key)
        } catch {
            log.error("Не удалось сохранить настройки: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Разрешённый корень архива из текущих настроек.
    func archiveRoot(for settings: RecordingSettings) -> URL {
        settings.resolvedArchiveURL(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }
}
