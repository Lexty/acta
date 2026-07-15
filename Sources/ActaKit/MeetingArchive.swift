import Foundation

/// Чистая логика раскладки архива записей: slug из заголовка, имя папки встречи и сериализация
/// `info.md` (YAML front-matter). Держим отдельно от файловой системы (FS-часть — `MeetingStore`
/// в таргете `Acta`), чтобы генерация slug и front-matter покрывались юнит-тестами
/// (`MeetingArchiveTests`), а не проверялись вручную прогоном приложения.
///
/// Формат папки: `YYYY-MM-DD_HHMM__<slug>/` (см. `SPEC.md` §6). Внутри — аудио + `session.json`
/// + `info.md`.
public enum MeetingArchive {
    /// Имя файла с метаданными встречи в папке записи.
    public static let infoFileName = "info.md"

    /// Значение slug по умолчанию, если из заголовка не осталось ни одного значимого символа.
    public static let fallbackSlug = "meeting"

    /// Максимальная длина slug (символов) — чтобы имена папок не разрастались.
    public static let maxSlugLength = 60

    // MARK: - Slug

    /// Построить slug из заголовка встречи.
    ///
    /// Приводит к нижнему регистру, оставляет буквы/цифры (в т.ч. кириллицу — она валидна в именах
    /// файлов macOS), а любые пробелы/пунктуацию сворачивает в один `-`. Обрезает ведущие/замыкающие
    /// `-` и длину. Пустой результат → `fallbackSlug`, чтобы имя папки всегда было валидным.
    public static func slug(from title: String, maxLength: Int = maxSlugLength) -> String {
        var result = ""
        var lastWasSeparator = true // true в начале, чтобы не появлялся ведущий '-'
        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("-")
                lastWasSeparator = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }

        if result.count > maxLength {
            result = String(result.prefix(maxLength))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result.isEmpty ? fallbackSlug : result
    }

    // MARK: - Имя папки

    /// Имя папки встречи: `YYYY-MM-DD_HHMM__<slug>`.
    ///
    /// `timeZone` вынесен в параметр ради детерминизма теста (по умолчанию — локальная зона).
    public static func folderName(date: Date, slug: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return "\(formatter.string(from: date))__\(slug)"
    }

    /// Имя папки прямо из заголовка (slug строится внутри).
    public static func folderName(date: Date, title: String, timeZone: TimeZone = .current) -> String {
        folderName(date: date, slug: slug(from: title), timeZone: timeZone)
    }
}

/// Метаданные встречи для `info.md` — **чистая логика** сериализации в YAML front-matter.
///
/// Поля соответствуют `SPEC.md` §6: `title, date, source, duration, status`. Статус переиспользует
/// `SessionManifest.Status` (одни и те же состояния записи).
public struct MeetingInfo: Equatable, Sendable {
    /// Человекочитаемый заголовок встречи.
    public var title: String

    /// Момент начала записи.
    public var date: Date

    /// Источник звука/встречи (Slack, Teams, Meet, …); может быть пустым.
    public var source: String

    /// Длительность записи, с.
    public var durationSeconds: Int

    /// Состояние записи (recording/done/recovered).
    public var status: SessionManifest.Status

    public init(title: String, date: Date, source: String, durationSeconds: Int,
                status: SessionManifest.Status) {
        self.title = title
        self.date = date
        self.source = source
        self.durationSeconds = durationSeconds
        self.status = status
    }

    /// Полное содержимое `info.md`: YAML front-matter + заголовок-разметка для читаемости.
    public func rendered() -> String {
        var lines = ["---"]
        lines.append("title: \(Self.quote(title))")
        lines.append("date: \(Self.iso8601(from: date))")
        lines.append("source: \(Self.quote(source))")
        lines.append("duration: \(Self.quote(Self.formatDuration(seconds: durationSeconds)))")
        lines.append("status: \(status.rawValue)")
        lines.append("---")
        lines.append("")
        lines.append("# \(Self.singleLine(title))")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Обновить в готовом `info.md` только `status` и `duration`, сохранив остальное как есть.
    ///
    /// Нужно восстановлению: `info.md` пишется на старте (`recording`, `00:00:00`), а после краха
    /// заголовок/дата/источник известны только из него самого. Полный YAML-парсер ради двух полей
    /// избыточен, поэтому правим строки внутри front-matter (блок между первой парой `---`).
    /// Если front-matter не распознан, возвращаем исходный текст: лучше устаревшие метаданные,
    /// чем испорченный файл.
    public static func patchedFrontMatter(_ contents: String, status: SessionManifest.Status,
                                          durationSeconds: Int) -> String {
        var lines = contents.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.isEmpty }), lines[first] == "---",
              let closing = lines[(first + 1)...].firstIndex(of: "---") else {
            return contents
        }
        for index in (first + 1)..<closing {
            if lines[index].hasPrefix("status:") {
                lines[index] = "status: \(status.rawValue)"
            } else if lines[index].hasPrefix("duration:") {
                lines[index] = "duration: \(quote(formatDuration(seconds: durationSeconds)))"
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Хелперы сериализации

    /// Форматировать длительность как `HH:MM:SS` (отрицательные значения → ноль).
    public static func formatDuration(seconds: Int) -> String {
        let total = max(0, seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Заключить произвольную строку в YAML-совместимый double-quoted скаляр с экранированием.
    /// Пользовательский текст (title/source) может содержать `:`, `#`, кавычки, переводы строк —
    /// двойные кавычки делают значение однозначно парсимым.
    static func quote(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Схлопнуть переводы строк в пробелы — для однострочного markdown-заголовка.
    static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// ISO-8601 представление даты (симметрично `SessionManifest`). Форматтер создаём локально:
    /// `ISO8601DateFormatter` не `Sendable`, а разделяемый статик ловит strict-concurrency ошибку.
    static func iso8601(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
