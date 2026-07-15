import ActaKit
import Foundation
import os

/// Файловое хранилище записей: корень архива `~/Acta/`, создание папки встречи
/// (`YYYY-MM-DD_HHMM__<slug>/`), запись `info.md` и перечисление сохранённых записей.
///
/// Тонкая обёртка над FS: раскладка имён и сериализация `info.md` — чистая логика в `ActaKit`
/// (`MeetingArchive`/`MeetingInfo`, покрыто юнит-тестами); тут только работа с диском.
struct MeetingStore {
    /// Одна запись в списке архива — папка + разобранный маркер сессии (если есть).
    struct Recording {
        var directory: URL
        var manifest: SessionManifest?
    }

    private let log = Logger(subsystem: AppInfo.bundleID, category: "MeetingStore")
    private let fileManager = FileManager.default
    private let manifestStore = SessionManifestStore()

    /// Корень архива записей (`~/Acta/` по умолчанию).
    let archiveRoot: URL

    init(archiveRoot: URL = MeetingStore.defaultArchiveRoot()) {
        self.archiveRoot = archiveRoot
    }

    /// Путь архива по умолчанию: `~/Acta/`.
    static func defaultArchiveRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Acta", isDirectory: true)
    }

    /// Создать папку новой встречи и вернуть её URL. Гарантирует существование корня архива.
    ///
    /// Если папка с таким именем уже существует (совпали минута и slug), добавляет суффикс `-2`,
    /// `-3`, … к slug, чтобы не смешать две записи в одной папке.
    func createMeetingDirectory(title: String, date: Date = Date()) throws -> URL {
        try ensureArchiveRoot()
        let slug = MeetingArchive.slug(from: title)
        var candidate = archiveRoot.appendingPathComponent(
            MeetingArchive.folderName(date: date, slug: slug), isDirectory: true)
        var attempt = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = MeetingArchive.folderName(date: date, slug: "\(slug)-\(attempt)")
            candidate = archiveRoot.appendingPathComponent(name, isDirectory: true)
            attempt += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        log.info("Создана папка встречи: \(candidate.lastPathComponent, privacy: .public)")
        return candidate
    }

    /// Записать `info.md` в папку встречи (атомарно, полной перезаписью).
    func writeInfo(_ info: MeetingInfo, to directory: URL) throws {
        let url = directory.appendingPathComponent(MeetingArchive.infoFileName)
        try info.rendered().data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// Перечислить записи архива: подпапки корня с разобранным `session.json`, новые сверху.
    ///
    /// Сортировка по имени папки по убыванию = по времени старта по убыванию (имя начинается с
    /// `YYYY-MM-DD_HHMM`).
    func listRecordings() -> [Recording] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: archiveRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
            .map { Recording(directory: $0, manifest: manifestStore.read(from: $0)) }
            .sorted { $0.directory.lastPathComponent > $1.directory.lastPathComponent }
    }

    // MARK: - Приватное

    /// Гарантировать существование корня архива и положить в него описание для Claude Code
    /// пользователя (`~/Acta/CLAUDE.md`, см. `SPEC.md` §6) — один раз, если файла ещё нет.
    private func ensureArchiveRoot() throws {
        try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let claudeMD = archiveRoot.appendingPathComponent("CLAUDE.md")
        guard !fileManager.fileExists(atPath: claudeMD.path) else { return }
        let contents = """
        # Acta — архив записей встреч

        Каждая подпапка — одна встреча (`YYYY-MM-DD_HHMM__<slug>/`):
        - `system.wav` — звук собеседников, `mic.wav` — микрофон, `combined.wav` — микс.
        - `info.md` — метаданные (YAML front-matter: title, date, source, duration, status).
        - `session.json` — служебный маркер состояния записи.

        Транскрипция/саммари делаются отдельно (локально, `mlx_whisper`).
        """
        try? contents.data(using: .utf8)?.write(to: claudeMD, options: .atomic)
    }
}
