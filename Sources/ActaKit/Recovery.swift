import Foundation

/// Чистая логика выбора сегментов для склейки при восстановлении и чистом стопе.
///
/// Держим отдельно от файловой системы и `ffmpeg`, чтобы главное правило крэш-безопасности —
/// «недописанный последний сегмент отбрасывается, а не роняет восстановление» — покрывалось
/// юнит-тестом (`RecoveryTests`). Runtime (`RecoveryManager`, `SegmentAssembler`) лишь подставляет
/// сюда имена файлов и их размеры из FS.
public enum Recovery {
    /// Минимальный размер валидного WAV-сегмента, байт. Заголовок RIFF/WAVE ~44 байта; файл меньше
    /// порога — это пустой/недописанный (битый) сегмент, типичный результат `kill -9` посередине.
    public static let minValidSegmentBytes = 64

    /// План склейки одной дорожки: отсортированные по номеру валидные сегменты.
    ///
    /// - Parameters:
    ///   - names: имена файлов из каталога дорожки (могут содержать мусор — отфильтруется).
    ///   - sizeByFileName: размер каждого файла в байтах (из FS).
    /// - Returns: имена сегментов в порядке возрастания номера, у которых размер ≥ порога.
    ///
    /// Битый сегмент отбрасывается независимо от позиции: пропуск одного чанка аудио допустим,
    /// падение восстановления — нет. На практике битым бывает только последний (незакрытый) сегмент.
    public static func recoveryPlan(fromFileNames names: [String],
                                    sizeByFileName: [String: Int]) -> [String] {
        SegmentLayout.orderedSegments(fromFileNames: names)
            .map(\.fileName)
            .filter { isValidSegment(bytes: sizeByFileName[$0] ?? 0) }
    }

    /// Достаточно ли размера, чтобы считать сегмент валидным (не пустой/не битый заголовок).
    public static func isValidSegment(bytes: Int) -> Bool {
        bytes >= minValidSegmentBytes
    }

    /// Есть ли что восстанавливать: маркер сессии указывает на прерванную запись.
    ///
    /// `recording` = процесс не дошёл до чистого стопа (краш/рестарт). `done`/`recovered` уже
    /// финализированы — их трогать не нужно.
    public static func needsRecovery(_ manifest: SessionManifest) -> Bool {
        manifest.status == .recording
    }
}
