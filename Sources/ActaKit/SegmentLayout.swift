import Foundation

/// Раскладка сегментной записи на диске — **чистая логика** имён/каталогов.
///
/// Запись каждой дорожки идёт короткими сегментами (см. скилл `crash-safe-recording`):
/// `system/0000.wav`, `system/0001.wav`, …, аналогично `mic/`. Имена нужны и рекордеру
/// (`SegmentWriter`), и восстановлению (`RecoveryManager`, Task 3) — поэтому вынесены в
/// тестируемую чистую логику (см. `SegmentLayoutTests`).
public enum SegmentLayout {
    /// Подкаталог сегментов дорожки системного звука.
    public static let systemDirName = "system"

    /// Подкаталог сегментов дорожки микрофона.
    public static let micDirName = "mic"

    /// Расширение файла сегмента.
    public static let segmentExtension = "wav"

    /// Длина имени порядкового номера (нулевое дополнение) — `%04d`.
    public static let indexDigits = 4

    /// Рекомендуемая длина сегмента, с. Компромисс: крэш теряет ≤ этой длины, но слишком
    /// короткие сегменты множат файлы и накладные расходы финализации.
    public static let defaultSegmentSeconds = 15

    /// Имя файла сегмента по порядковому номеру: `0000.wav`, `0001.wav`, …
    public static func segmentFileName(index: Int) -> String {
        let padded = String(format: "%0\(indexDigits)d", index)
        return "\(padded).\(segmentExtension)"
    }

    /// Порядковый номер из имени файла сегмента, либо `nil` если имя не соответствует схеме.
    ///
    /// Отсекает посторонние файлы (например `.DS_Store`, частично записанный мусор), чтобы
    /// восстановление собирало только настоящие сегменты. Имена дополнены нулями минимум до
    /// `indexDigits` (`%04d`), но при индексе ≥ 10000 длиннее — поэтому принимаем **не короче**
    /// `indexDigits`, а не ровно столько (иначе длинные записи теряли бы сегменты со склейки).
    public static func segmentIndex(fromFileName name: String) -> Int? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == segmentExtension else { return nil }
        let stem = parts[0]
        guard stem.count >= indexDigits, stem.allSatisfy(\.isNumber) else { return nil }
        return Int(stem)
    }

    /// Отсортированный по возрастанию номера список валидных сегментов из перечня имён файлов.
    ///
    /// Возвращает пары «номер + имя»; неподходящие имена отбрасываются. База выбора сегментов
    /// для склейки (Task 3) — держим тут, чтобы покрыть тестом отдельно от файловой системы.
    public static func orderedSegments(fromFileNames names: [String]) -> [(index: Int, fileName: String)] {
        names
            .compactMap { name -> (index: Int, fileName: String)? in
                guard let idx = segmentIndex(fromFileName: name) else { return nil }
                return (index: idx, fileName: name)
            }
            .sorted { $0.index < $1.index }
    }
}
