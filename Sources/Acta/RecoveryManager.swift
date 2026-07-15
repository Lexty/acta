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
    struct Recovered {
        var directory: URL
        var combinedWAV: URL?
    }

    private let log = Logger(subsystem: AppInfo.bundleID, category: "RecoveryManager")
    private let fileManager = FileManager.default
    private let store = SessionManifestStore()
    private let assembler = SegmentAssembler()

    /// Корень архива записей.
    let archiveRoot: URL

    init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
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
        let result = try assembler.assemble(in: directory, deleteSegments: false)

        var updated = manifest
        updated.status = .recovered
        try store.write(updated, to: directory)

        return Recovered(directory: directory, combinedWAV: result.combinedWAV)
    }
}
