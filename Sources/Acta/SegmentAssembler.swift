import ActaKit
import Foundation
import os

/// Сборка итоговых файлов записи из сегментов через `ffmpeg`. Используется и при чистом стопе,
/// и при восстановлении (`RecoveryManager`) — правило выбора сегментов одинаковое.
///
/// Порядок: для каждой дорожки собрать план сегментов (`Recovery.recoveryPlan`) → починить
/// недописанные заголовки → `ffmpeg -f concat -c copy` → `system.wav`/`mic.wav`; если получились
/// обе — микс в `combined.wav`. Сегмент без пригодного аудио план отбрасывает, поэтому склейка не
/// падает, а недописанный (но со звуком) — чинится по фактическому размеру, а не теряется.
///
/// Аргументы `ffmpeg` — чистые функции `FFmpeg.*` (покрыты юнит-тестами); тут только запуск процесса.
struct SegmentAssembler {
    /// Результат сборки — какие итоговые файлы получились.
    struct Result: Sendable {
        var systemWAV: URL?
        var micWAV: URL?
        var combinedWAV: URL?
        /// Сколько валидных сегментов вошло в склейку (максимум по дорожкам).
        var segmentCount: Int = 0
        /// Длительность собранного аудио, с — измеренная по итоговому файлу, а не по часам.
        /// `nil`, если измерить не удалось (файла нет / заголовок не читается).
        ///
        /// Часы врут: `SCStream` поднимается не мгновенно, и в живом прогоне запись «на 29 с»
        /// содержала 23.66 с звука. В `info.md` идёт именно эта величина (Task 8.3).
        var durationSeconds: Double?
    }

    enum AssembleError: Error {
        case ffmpegNotFound
        case noSegments
        /// `ffmpeg` не смог склеить дорожку. Отдельно от `noSegments`: пустая дорожка — не ошибка,
        /// а провал склейки означает, что сегменты — единственная копия аудио и трогать их нельзя.
        case concatFailed(track: String)
        /// Обе дорожки склеены, но `ffmpeg` не смог свести их в `combined.wav`. Ошибка, а не «микс
        /// не вышел»: при настройке «только combined» пользователь просил ровно этот файл, и молчать
        /// про его отсутствие — то же, что показывать «немой» recording.
        case mixFailed
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

        // Обе дорожки склеились, а микс не вышел = сбой ffmpeg: доверия к склейке нет, поэтому
        // бросаем, как и `concatFailed`. Маркер сессии остаётся `recording`, сегменты и промежуточные
        // wav целы, а восстановление на следующем запуске повторит попытку. Вернуть тут «успех» без
        // `combined.wav` значило бы сказать «сохранена» про файл, которого нет.
        if tracks.combined, let systemWAV, let micWAV {
            let combined = directory.appendingPathComponent("combined.wav")
            let args = FFmpeg.mixArgs(systemPath: systemWAV.path, micPath: micWAV.path,
                                      outputPath: combined.path)
            guard runFFmpeg(ffmpeg, args: args) else { throw AssembleError.mixFailed }
            result.combinedWAV = combined
        }

        // Микс запрошен, но одной из дорожек просто не было (мик отключён — `concatTrack` вернул nil,
        // сбой бы бросил `concatFailed`): свести нечего. Уцелевшая дорожка — единственный результат
        // записи, и удалять её по настройке «только combined» нельзя: стоп потерял бы встречу целиком.
        let combinedMissing = tracks.combined && result.combinedWAV == nil

        // Убрать промежуточные дорожки, которые пользователь не просил сохранять.
        if !tracks.system, let systemWAV, !combinedMissing {
            try? fileManager.removeItem(at: systemWAV)
            result.systemWAV = nil
        }
        if !tracks.mic, let micWAV, !combinedMissing {
            try? fileManager.removeItem(at: micWAV)
            result.micWAV = nil
        }

        // Сюда доходим, когда каждая дорожка, которую вообще было из чего собрать, уже лежит рядом
        // отдельным wav: любой провал склейки бросает исключение выше, а `combinedMissing` означает,
        // что одной из исходных дорожек не существовало, и уцелевшая (`system.wav`/`mic.wav`) выше
        // намеренно оставлена. То есть сегменты — уже избыточное сырьё, и Mac без микрофона (микс
        // невозможен в принципе) тоже не копит их вечно.
        if deleteSegments {
            for name in [SegmentLayout.systemDirName, SegmentLayout.micDirName] {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }

        // Меряем по тому файлу, который пользователь и получит; дорожки одной записи равны по
        // длине, поэтому выбор между ними на цифру не влияет.
        result.durationSeconds = [result.combinedWAV, result.systemWAV, result.micWAV]
            .compactMap { $0 }
            .lazy
            .compactMap { Self.measuredDuration(of: $0) }
            .first

        return result
    }

    /// Длительность готового wav по его заголовку (`WAV.durationSeconds` поверх FS).
    static func measuredDuration(of url: URL) -> Double? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        guard let size else { return nil }
        return WAV.durationSeconds(header: headerPrefix(of: url), fileSize: size)
    }

    // MARK: - Приватное

    /// Склеить валидные сегменты одной дорожки в `outputName`. Возвращает URL итога либо `nil`,
    /// если валидных сегментов нет (пустая дорожка — не ошибка, просто нечего склеивать).
    /// Бросает `concatFailed`, если сегменты есть, но `ffmpeg` их не склеил: молча вернуть `nil`
    /// нельзя — вызывающий счёл бы дорожку пустой и удалил бы её сегменты.
    private func concatTrack(dirName: String, outputName: String, in directory: URL,
                             ffmpeg: String) throws -> (url: URL?, count: Int) {
        let trackDir = directory.appendingPathComponent(dirName)
        let plan = preparedSegments(inTrackDir: trackDir)
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

    /// План склейки дорожки (`Recovery.recoveryPlan` поверх реальной FS) — только чтение.
    ///
    /// Статический и внутренний, потому что тем же правилом `RecordingController` решает, есть ли в
    /// папке спасаемый звук: `AVAssetWriter` создаёт файл сегмента **до** первого буфера, поэтому
    /// проверка «файл с именем NNNN.wav существует» приняла бы за звук пустую преамбулу.
    static func plannedSegments(inTrackDir trackDir: URL) -> [Recovery.PlannedSegment] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: trackDir.path)) ?? []

        var sizes: [String: Int] = [:]
        var headers: [String: Data] = [:]
        for name in names {
            let url = trackDir.appendingPathComponent(name)
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            sizes[name] = (attrs?[.size] as? Int) ?? 0
            headers[name] = headerPrefix(of: url)
        }
        return Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: headers)
    }

    /// Имена сегментов дорожки, готовых к склейке: план + починка недописанных заголовков на месте.
    ///
    /// Чинить приходится именно здесь, перед `ffmpeg`: `kill -9` оставляет последний сегмент с
    /// секундами реального звука и непроставленными размерами, и другого шанса вернуть этот звук
    /// нет. Сегмент, который починить не удалось (файл не открылся на запись), из плана выпадает —
    /// отдать `ffmpeg` заведомо битый файл значило бы уронить склейку всей дорожки ради его хвоста.
    private func preparedSegments(inTrackDir trackDir: URL) -> [String] {
        Self.plannedSegments(inTrackDir: trackDir).compactMap { segment in
            switch segment.action {
            case .include:
                return segment.fileName
            case .repair(let repair):
                let url = trackDir.appendingPathComponent(segment.fileName)
                guard Self.applyRepair(repair, to: url) else {
                    log.error("Не удалось починить заголовок \(segment.fileName, privacy: .public) — сегмент пропущен")
                    return nil
                }
                log.info("Починен недописанный заголовок \(segment.fileName, privacy: .public): \(repair.dataSize) байт аудио")
                return segment.fileName
            }
        }
    }

    /// Проставить размеры в заголовке и обрезать файл до целого числа кадров. `false` — файл не
    /// поддался (вызывающий исключает сегмент из склейки).
    private static func applyRepair(_ repair: WAV.HeaderRepair, to url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(repair.riffSizeOffset))
            try handle.write(contentsOf: WAV.le32(repair.riffSize))
            try handle.seek(toOffset: UInt64(repair.dataSizeOffset))
            try handle.write(contentsOf: WAV.le32(repair.dataSize))
            try handle.truncate(atOffset: UInt64(repair.truncatedFileSize))
            try handle.synchronize()
            return true
        } catch {
            return false
        }
    }

    /// Прочитать начало файла для проверки WAV-заголовка (`Recovery.isValidSegment`). Пустой
    /// результат = файл не читается → сегмент не считается валидным.
    private static func headerPrefix(of url: URL) -> Data {
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
