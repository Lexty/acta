import ActaKit
import Foundation
import os

/// Восстановление прерванных записей на старте приложения (см. скилл `crash-safe-recording`).
///
/// При `kill -9`/рестарте компьютера процесс не доходит до чистого стопа: в папке записи остаётся
/// `session.json` со `status=recording` и несклеенные сегменты. `RecoveryManager` при запуске
/// сканирует архив, находит такие папки, склеивает уцелевшие сегменты в `system/mic/combined.wav`
/// (недописанный последний сегмент отбрасывается) и переводит маркер в `status=recovered`.
struct RecoveryManager {
    /// Итог восстановления одной папки — для уведомления пользователя (Task 6).
    struct Recovered: Sendable {
        var directory: URL
        var combinedWAV: URL?
    }

    private let log = Logger(subsystem: AppInfo.bundleID, category: "RecoveryManager")
    private let fileManager = FileManager.default
    private let store = SessionManifestStore()
    private let assembler = SegmentAssembler()

    /// Корень архива записей.
    let archiveRoot: URL

    /// Какие итоговые дорожки собирать — та же настройка, что и на чистом стопе (Task 7). Иначе
    /// восстановленная после краха встреча пришла бы с набором файлов, которого пользователь не
    /// просил, и архив расходился бы сам с собой в зависимости от того, был ли краш.
    let tracks: RecordingSettings.TrackSelection

    init(archiveRoot: URL,
         tracks: RecordingSettings.TrackSelection = RecordingSettings.default.trackSelection) {
        self.archiveRoot = archiveRoot
        self.tracks = tracks
    }

    /// Просканировать архив и восстановить все прерванные записи. Ошибка одной папки не мешает
    /// остальным (изолируем в `do/catch`). Возвращает список восстановленного.
    @discardableResult
    func recoverInterruptedSessions() -> [Recovered] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: archiveRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var recovered: [Recovered] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir, let manifest = store.read(from: dir), Recovery.needsRecovery(manifest) else {
                continue
            }
            do {
                let result = try recover(directory: dir, manifest: manifest)
                recovered.append(result)
            } catch SegmentAssembler.AssembleError.noSegments {
                // Спасать нечего и уже никогда не будет: краш успел создать маркер, но ни одного
                // валидного сегмента не осталось. Оставить `recording` — обречь папку на тщетную
                // склейку при каждом запуске и вечное «не завершена» в списке без способа убрать.
                // В `recovered` не добавляем: восстанавливать было нечего, врать в уведомление незачем.
                closeEmpty(directory: dir, manifest: manifest)
            } catch {
                let name = dir.lastPathComponent
                log.error("Не удалось восстановить \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return recovered
    }

    /// Восстановить одну папку: склеить уцелевшие сегменты, пометить `recovered`.
    private func recover(directory: URL, manifest: SessionManifest) throws -> Recovered {
        log.info("Восстановление прерванной записи: \(directory.lastPathComponent, privacy: .public)")
        // При восстановлении сегменты не удаляем: сохраняем сырьё на случай проблем со склейкой.
        let result = try assembler.assemble(in: directory, deleteSegments: false, tracks: tracks)

        var updated = manifest
        updated.status = .recovered
        updated.segmentCount = result.segmentCount
        try store.write(updated, to: directory)
        updateInfo(in: directory, manifest: updated)

        return Recovered(directory: directory, combinedWAV: result.combinedWAV)
    }

    /// Закрыть маркер папки, из которой спасать нечего: `recovered` с нулём сегментов — терминальный
    /// статус, поэтому следующий запуск её уже не тронет. Саму папку не удаляем: `info.md` с
    /// названием и временем встречи — единственный след того, что запись пытались вести, и решение
    /// стереть его остаётся за пользователем.
    private func closeEmpty(directory: URL, manifest: SessionManifest) {
        log.error("Нечего восстанавливать (валидных сегментов нет): \(directory.lastPathComponent, privacy: .public)")
        var updated = manifest
        updated.status = .recovered
        updated.segmentCount = 0
        try? store.write(updated, to: directory)
        updateInfo(in: directory, manifest: updated)
    }

    /// Привести `info.md` в соответствие с маркером: на старте он записан как `recording` с нулевой
    /// длительностью, и без этого восстановленная встреча навсегда осталась бы «идёт запись» —
    /// `info.md` и есть архивные метаданные (SPEC §6), их читают уже без приложения.
    ///
    /// Длительность оцениваем по числу уцелевших сегментов: чистого стопа с таймером не было.
    private func updateInfo(in directory: URL, manifest: SessionManifest) {
        let url = directory.appendingPathComponent(MeetingArchive.infoFileName)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let duration = manifest.segmentCount * manifest.segmentSeconds
        let patched = MeetingInfo.patchedFrontMatter(contents, status: manifest.status,
                                                     durationSeconds: duration)
        try? patched.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
