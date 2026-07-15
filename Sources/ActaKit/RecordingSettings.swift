import Foundation

/// Пользовательские настройки записи — **чистая, тестируемая** модель (Task 7).
///
/// Значение (`Codable`/`Equatable`): путь архива, какие итоговые дорожки сохранять
/// (`system`/`mic`/`combined`), длина сегмента и удалять ли сегменты после склейки. Персистентность
/// (UserDefaults) и применение к пайплайну — в `SettingsStore`/`RecordingController` (таргет `Acta`);
/// тут только значения, нормализация и раскладка — покрыто юнит-тестами (`RecordingSettingsTests`).
///
/// Нормализация (`normalized()`) — единственный «умный» кусок: длина сегмента зажимается в разумный
/// диапазон, а полностью снятый выбор дорожек не даёт «запись в никуда» (форсим `combined`).
public struct RecordingSettings: Codable, Equatable, Sendable {
    /// Путь папки архива. Пусто → путь по умолчанию (`~/Acta`). Поддерживает `~` в начале.
    public var archivePath: String
    /// Сохранять итоговый `system.wav` (звук собеседников).
    public var saveSystemTrack: Bool
    /// Сохранять итоговый `mic.wav` (микрофон).
    public var saveMicTrack: Bool
    /// Сохранять итоговый `combined.wav` (микс двух дорожек).
    public var saveCombinedTrack: Bool
    /// Длина сегмента, с (зажимается в `[minSegmentSeconds, maxSegmentSeconds]`).
    public var segmentSeconds: Int
    /// Удалять каталоги сегментов после успешной склейки.
    public var deleteSegmentsAfterAssembly: Bool

    public init(archivePath: String = "",
                saveSystemTrack: Bool = true,
                saveMicTrack: Bool = true,
                saveCombinedTrack: Bool = true,
                segmentSeconds: Int = SegmentLayout.defaultSegmentSeconds,
                deleteSegmentsAfterAssembly: Bool = true) {
        self.archivePath = archivePath
        self.saveSystemTrack = saveSystemTrack
        self.saveMicTrack = saveMicTrack
        self.saveCombinedTrack = saveCombinedTrack
        self.segmentSeconds = segmentSeconds
        self.deleteSegmentsAfterAssembly = deleteSegmentsAfterAssembly
    }

    /// Настройки по умолчанию.
    public static let `default` = RecordingSettings()

    /// Нижняя граница длины сегмента, с. Короче — множит файлы/финализации без пользы.
    public static let minSegmentSeconds = 5
    /// Верхняя граница длины сегмента, с. Длиннее — крэш теряет слишком много.
    public static let maxSegmentSeconds = 120

    /// Отсутствующие в JSON поля берут значения по умолчанию (совместимость со старым конфигом).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = RecordingSettings.default
        archivePath = try c.decodeIfPresent(String.self, forKey: .archivePath) ?? def.archivePath
        saveSystemTrack = try c.decodeIfPresent(Bool.self, forKey: .saveSystemTrack) ?? def.saveSystemTrack
        saveMicTrack = try c.decodeIfPresent(Bool.self, forKey: .saveMicTrack) ?? def.saveMicTrack
        saveCombinedTrack = try c.decodeIfPresent(Bool.self, forKey: .saveCombinedTrack) ?? def.saveCombinedTrack
        segmentSeconds = try c.decodeIfPresent(Int.self, forKey: .segmentSeconds) ?? def.segmentSeconds
        deleteSegmentsAfterAssembly = try c.decodeIfPresent(Bool.self, forKey: .deleteSegmentsAfterAssembly)
            ?? def.deleteSegmentsAfterAssembly
    }

    /// Выбор дорожек для сборки итоговых файлов (см. `SegmentAssembler`).
    public struct TrackSelection: Equatable, Sendable {
        public var system: Bool
        public var mic: Bool
        public var combined: Bool

        public init(system: Bool, mic: Bool, combined: Bool) {
            self.system = system
            self.mic = mic
            self.combined = combined
        }
    }

    /// Выбор дорожек, выведенный из нормализованных настроек.
    public var trackSelection: TrackSelection {
        let n = normalized()
        return TrackSelection(system: n.saveSystemTrack, mic: n.saveMicTrack, combined: n.saveCombinedTrack)
    }

    /// Зажать длину сегмента в допустимый диапазон.
    public static func clampSegmentSeconds(_ value: Int) -> Int {
        min(maxSegmentSeconds, max(minSegmentSeconds, value))
    }

    /// Нормализованная копия: длина сегмента в диапазоне; хотя бы одна дорожка сохраняется
    /// (иначе запись ушла бы «в никуда» — форсим `combined`).
    public func normalized() -> RecordingSettings {
        var s = self
        s.segmentSeconds = RecordingSettings.clampSegmentSeconds(segmentSeconds)
        if !saveSystemTrack && !saveMicTrack && !saveCombinedTrack {
            s.saveCombinedTrack = true
        }
        return s
    }

    /// Разрешённый URL корня архива относительно домашней папки.
    ///
    /// Пустой путь → `<home>/Acta`; ведущая `~` разворачивается в `homeDirectory`; иначе путь
    /// используется как есть. `homeDirectory` инжектируется для тестируемости.
    public func resolvedArchiveURL(homeDirectory: URL) -> URL {
        let trimmed = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return homeDirectory.appendingPathComponent("Acta", isDirectory: true)
        }
        if trimmed == "~" {
            return homeDirectory
        }
        if trimmed.hasPrefix("~/") {
            let rel = String(trimmed.dropFirst(2))
            return homeDirectory.appendingPathComponent(rel, isDirectory: true)
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }
}
