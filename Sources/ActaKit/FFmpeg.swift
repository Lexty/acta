import Foundation

/// Чистые построители аргументов `ffmpeg` для склейки сегментов и микса дорожек.
///
/// Runtime-запуск процесса живёт в executable-таргете `Acta`; здесь только **чистая логика**
/// (её покрываем юнит-тестами — см. `FFmpegTests`). Так требование крэш-безопасной сборки
/// финальных файлов из сегментов остаётся проверяемым без запуска аудио-стека.
public enum FFmpeg {
    /// Содержимое `list.txt` для concat-демультиплексора ffmpeg.
    ///
    /// Каждая строка — `file '<path>'`. Одинарные кавычки внутри пути экранируются как `'\''`
    /// (стандартный приём для concat-демуксера), иначе путь с апострофом ломает разбор списка.
    public static func concatListContents(segmentPaths: [String]) -> String {
        segmentPaths
            .map { "file '\(escapeForConcatList($0))'" }
            .joined(separator: "\n")
            + (segmentPaths.isEmpty ? "" : "\n")
    }

    /// Аргументы конкатенации сегментов одной дорожки в единый файл (без перекодирования).
    ///
    /// `-f concat -safe 0 -i list.txt -c copy output` — быстрая склейка одинаковых по формату
    /// сегментов. `-y` перезаписывает существующий выход (актуально при восстановлении).
    public static func concatArgs(listPath: String, outputPath: String) -> [String] {
        ["-y", "-f", "concat", "-safe", "0", "-i", listPath, "-c", "copy", outputPath]
    }

    /// Аргументы микса двух дорожек (система + микрофон) в объединённый файл.
    ///
    /// `amix=inputs=2:duration=longest` — длительность по самой длинной дорожке. `normalize=0`
    /// отключает деление амплитуды на число входов (иначе микс звучит вдвое тише).
    public static func mixArgs(systemPath: String, micPath: String, outputPath: String) -> [String] {
        [
            "-y",
            "-i", systemPath,
            "-i", micPath,
            "-filter_complex", "amix=inputs=2:duration=longest:normalize=0",
            outputPath
        ]
    }

    /// Экранирование одинарной кавычки для строки `file '...'` concat-списка.
    static func escapeForConcatList(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }
}
