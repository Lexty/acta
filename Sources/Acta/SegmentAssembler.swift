import ActaKit
import Foundation
import os

/// Сборка итоговых файлов записи из сегментов через `ffmpeg`. Используется и при чистом стопе,
/// и при восстановлении (`RecoveryManager`) — правило выбора сегментов одинаковое.
///
/// Порядок: для каждой дорожки собрать план валидных сегментов (`Recovery.recoveryPlan`) →
/// `ffmpeg -f concat -c copy` → `system.wav`/`mic.wav`; если получились обе — микс в `combined.wav`.
/// Битый (недописанный) последний сегмент план отбрасывает, поэтому склейка не падает.
///
/// Аргументы `ffmpeg` — чистые функции `FFmpeg.*` (покрыты юнит-тестами); тут только запуск процесса.
struct SegmentAssembler {
    /// Результат сборки — какие итоговые файлы получились.
    struct Result {
        var systemWAV: URL?
        var micWAV: URL?
        var combinedWAV: URL?
    }

    enum AssembleError: Error {
        case ffmpegNotFound
        case noSegments
    }

    private let log = Logger(subsystem: AppInfo.bundleID, category: "SegmentAssembler")
    private let fileManager = FileManager.default

    /// Собрать итоговые файлы в `directory`.
    ///
    /// - Parameters:
    ///   - directory: папка записи (содержит `system/`, `mic/`).
    ///   - deleteSegments: удалить каталоги сегментов после успешной склейки.
    @discardableResult
    func assemble(in directory: URL, deleteSegments: Bool) throws -> Result {
        guard let ffmpeg = Self.locateFFmpeg() else { throw AssembleError.ffmpegNotFound }

        let systemWAV = try concatTrack(dirName: SegmentLayout.systemDirName,
                                        outputName: "system.wav", in: directory, ffmpeg: ffmpeg)
        let micWAV = try concatTrack(dirName: SegmentLayout.micDirName,
                                     outputName: "mic.wav", in: directory, ffmpeg: ffmpeg)

        guard systemWAV != nil || micWAV != nil else { throw AssembleError.noSegments }

        var result = Result(systemWAV: systemWAV, micWAV: micWAV, combinedWAV: nil)

        if let systemWAV, let micWAV {
            let combined = directory.appendingPathComponent("combined.wav")
            let args = FFmpeg.mixArgs(systemPath: systemWAV.path, micPath: micWAV.path,
                                      outputPath: combined.path)
            if runFFmpeg(ffmpeg, args: args) {
                result.combinedWAV = combined
            }
        }

        if deleteSegments {
            for name in [SegmentLayout.systemDirName, SegmentLayout.micDirName] {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }

        return result
    }

    // MARK: - Приватное

    /// Склеить валидные сегменты одной дорожки в `outputName`. Возвращает URL итога либо `nil`,
    /// если валидных сегментов нет (пустая дорожка — не ошибка, просто нечего склеивать).
    private func concatTrack(dirName: String, outputName: String, in directory: URL,
                             ffmpeg: String) throws -> URL? {
        let trackDir = directory.appendingPathComponent(dirName)
        let names = (try? fileManager.contentsOfDirectory(atPath: trackDir.path)) ?? []

        var sizes: [String: Int] = [:]
        for name in names {
            let attrs = try? fileManager.attributesOfItem(atPath: trackDir.appendingPathComponent(name).path)
            sizes[name] = (attrs?[.size] as? Int) ?? 0
        }

        let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes)
        guard !plan.isEmpty else {
            log.info("Дорожка \(dirName, privacy: .public): валидных сегментов нет")
            return nil
        }

        let paths = plan.map { trackDir.appendingPathComponent($0).path }
        let listURL = directory.appendingPathComponent("\(dirName)_concat.txt")
        try FFmpeg.concatListContents(segmentPaths: paths).write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: listURL) }

        let output = directory.appendingPathComponent(outputName)
        let args = FFmpeg.concatArgs(listPath: listURL.path, outputPath: output.path)
        guard runFFmpeg(ffmpeg, args: args) else { return nil }
        return output
    }

    /// Запустить `ffmpeg`; `true` при коде выхода 0.
    private func runFFmpeg(_ ffmpeg: String, args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                log.error("ffmpeg вышел с кодом \(proc.terminationStatus)")
                return false
            }
            return true
        } catch {
            log.error("Не удалось запустить ffmpeg: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Найти бинарь `ffmpeg`: типичные пути Homebrew (Apple Silicon/Intel) + `PATH`.
    static func locateFFmpeg() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/ffmpeg"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }
}
