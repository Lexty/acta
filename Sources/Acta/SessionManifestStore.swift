import ActaKit
import Foundation
import os

/// Чтение/запись `session.json` в папке записи. Тонкая обёртка над FS: сериализация — в `ActaKit`
/// (`SessionManifest`), тут — только атомарная запись на диск и разбор.
struct SessionManifestStore {
    private let log = Logger(subsystem: AppInfo.bundleID, category: "SessionManifestStore")

    /// URL маркера в папке записи.
    func url(in directory: URL) -> URL {
        directory.appendingPathComponent(SessionManifest.fileName)
    }

    /// Записать маркер атомарно (полная перезапись файла — маркер маленький, гонок нет).
    func write(_ manifest: SessionManifest, to directory: URL) throws {
        let data = try manifest.encoded()
        try data.write(to: url(in: directory), options: .atomic)
    }

    /// Прочитать маркер; `nil`, если файла нет или он не парсится (тогда папка пропускается).
    func read(from directory: URL) -> SessionManifest? {
        let fileURL = url(in: directory)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try SessionManifest.decode(from: data)
        } catch {
            let name = fileURL.lastPathComponent
            log.error("Не удалось разобрать \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
