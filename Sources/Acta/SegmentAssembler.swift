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
        /// Сколько валидных сегментов вошло в склейку (максимум по дорожкам). Восстановление
        /// оценивает по нему длительность прерванной записи: чистого стопа с таймером не было.
        var segmentCount: Int = 0
    }

    enum AssembleError: Error {
        case ffmpegNotFound
        case noSegments
        /// `ffmpeg` не смог склеить дорожку. Отдельно от `noSegments`: пустая дорожка — не ошибка,
        /// а провал склейки означает, что сегменты — единственная копия аудио и трогать их нельзя.
        case concatFailed(track: String)
    }

    private let log = Logger(subsystem: AppInfo.bundleID, category: "SegmentAssembler")
    private let fileManager = FileManager.default

    /// Собрать итоговые файлы в `directory`.
    ///
    /// - Parameters:
    ///   - directory: папка записи (содержит `system/`, `mic/`).
    ///   - deleteSegments: удалить каталоги сегментов после успешной склейки.
    ///   - tracks: какие итоговые дорожки сохранить (настройка Task 7). `combined` требует обеих
    ///     дорожек, поэтому промежуточные `system.wav`/`mic.wav` собираются и при снятом флаге
    ///     дорожки, если нужен микс, и затем удаляются.
    @discardableResult
    func assemble(in directory: URL, deleteSegments: Bool,
                  tracks: RecordingSettings.TrackSelection = .init(system: true, mic: true, combined: true)
    ) throws -> Result {
        guard let ffmpeg = Self.locateFFmpeg() else { throw AssembleError.ffmpegNotFound }

        // combined = микс двух дорожек, поэтому исходные wav нужны, даже если сама дорожка не сохраняется.
        let needSystem = tracks.system || tracks.combined
        let needMic = tracks.mic || tracks.combined

        let system = needSystem
            ? try concatTrack(dirName: SegmentLayout.systemDirName,
                              outputName: "system.wav", in: directory, ffmpeg: ffmpeg)
            : (url: nil, count: 0)
        let mic = needMic
            ? try concatTrack(dirName: SegmentLayout.micDirName,
                              outputName: "mic.wav", in: directory, ffmpeg: ffmpeg)
            : (url: nil, count: 0)

        let systemWAV = system.url
        let micWAV = mic.url
        guard systemWAV != nil || micWAV != nil else { throw AssembleError.noSegments }

        var result = Result(systemWAV: systemWAV, micWAV: micWAV, combinedWAV: nil,
                            segmentCount: max(system.count, mic.count))

        if tracks.combined, let systemWAV, let micWAV {
            let combined = directory.appendingPathComponent("combined.wav")
            let args = FFmpeg.mixArgs(systemPath: systemWAV.path, micPath: micWAV.path,
                                      outputPath: combined.path)
            if runFFmpeg(ffmpeg, args: args) {
                result.combinedWAV = combined
            }
        }

        // Если микс запрошен, но не получился (сбой ffmpeg / одна из дорожек пуста), исходные
        // system.wav/mic.wav и сегменты — единственные уцелевшие копии аудио. Не удаляем их, иначе
        // при конфигурации «только combined» чистый стоп потерял бы запись целиком.
        let combinedRequestedButMissing = tracks.combined && result.combinedWAV == nil

        // Убрать промежуточные дорожки, которые пользователь не просил сохранять.
        if !tracks.system, let systemWAV, !combinedRequestedButMissing {
            try? fileManager.removeItem(at: systemWAV)
            result.systemWAV = nil
        }
        if !tracks.mic, let micWAV, !combinedRequestedButMissing {
            try? fileManager.removeItem(at: micWAV)
            result.micWAV = nil
        }

        if deleteSegments, !combinedRequestedButMissing {
            for name in [SegmentLayout.systemDirName, SegmentLayout.micDirName] {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }

        return result
    }

    // MARK: - Приватное

    /// Склеить валидные сегменты одной дорожки в `outputName`. Возвращает URL итога либо `nil`,
    /// если валидных сегментов нет (пустая дорожка — не ошибка, просто нечего склеивать).
    /// Бросает `concatFailed`, если сегменты есть, но `ffmpeg` их не склеил: молча вернуть `nil`
    /// нельзя — вызывающий счёл бы дорожку пустой и удалил бы её сегменты.
    private func concatTrack(dirName: String, outputName: String, in directory: URL,
                             ffmpeg: String) throws -> (url: URL?, count: Int) {
        let trackDir = directory.appendingPathComponent(dirName)
        let names = (try? fileManager.contentsOfDirectory(atPath: trackDir.path)) ?? []

        var sizes: [String: Int] = [:]
        var headers: [String: Data] = [:]
        for name in names {
            let url = trackDir.appendingPathComponent(name)
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            sizes[name] = (attrs?[.size] as? Int) ?? 0
            headers[name] = headerPrefix(of: url)
        }

        let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                         headerByFileName: headers)
        guard !plan.isEmpty else {
            log.info("Дорожка \(dirName, privacy: .public): валидных сегментов нет")
            return (nil, 0)
        }

        let paths = plan.map { trackDir.appendingPathComponent($0).path }
        let listURL = directory.appendingPathComponent("\(dirName)_concat.txt")
        try FFmpeg.concatListContents(segmentPaths: paths).write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: listURL) }

        let output = directory.appendingPathComponent(outputName)
        let args = FFmpeg.concatArgs(listPath: listURL.path, outputPath: output.path)
        guard runFFmpeg(ffmpeg, args: args) else { throw AssembleError.concatFailed(track: dirName) }
        return (output, plan.count)
    }

    /// Прочитать начало файла для проверки WAV-заголовка (`Recovery.isValidSegment`). Пустой
    /// результат = файл не читается → сегмент не считается валидным.
    private func headerPrefix(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: Recovery.headerProbeBytes)) ?? Data()
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
