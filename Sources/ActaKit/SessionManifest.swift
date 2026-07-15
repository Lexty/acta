import Foundation

/// Маркер сессии записи — содержимое `session.json` в папке записи.
///
/// Пишется при старте (`status=recording`), обновляется по ходу и на финализации. Наличие
/// `status=recording` на следующем запуске приложения = запись была прервана нештатно
/// (краш/рестарт) → её подхватывает `RecoveryManager` (см. скилл `crash-safe-recording`).
///
/// Сериализация — **чистая логика** (JSON round-trip), поэтому тип и его кодек живут в `ActaKit`
/// и покрыты юнит-тестом (`SessionManifestTests`), отдельно от файловой системы.
public struct SessionManifest: Codable, Equatable, Sendable {
    /// Состояние записи.
    public enum Status: String, Codable, Sendable {
        /// Идёт запись (или процесс прерван, пока файл не обновлён на `done`/`recovered`).
        case recording
        /// Чистый стоп: сегменты склеены в итоговые файлы.
        case done
        /// Запись была прервана нештатно и восстановлена на старте из уцелевших сегментов.
        case recovered
    }

    /// Имя файла маркера в папке записи.
    public static let fileName = "session.json"

    /// Текущее состояние.
    public var status: Status

    /// Момент старта записи.
    public var startedAt: Date

    /// Длина сегмента (с), с которой шла запись — нужна восстановлению для оценки длительности.
    public var segmentSeconds: Int

    /// Число финализированных сегментов на момент последнего обновления маркера.
    public var segmentCount: Int

    public init(status: Status, startedAt: Date, segmentSeconds: Int, segmentCount: Int) {
        self.status = status
        self.startedAt = startedAt
        self.segmentSeconds = segmentSeconds
        self.segmentCount = segmentCount
    }

    /// Кодер с фиксированной раскладкой: snake_case ключи + ISO-8601 даты (человекочитаемо и
    /// стабильно между запусками). `prettyPrinted` — чтобы `session.json` было удобно смотреть глазом.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Декодер, симметричный `makeEncoder()`.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Сериализовать в JSON.
    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Разобрать из JSON.
    public static func decode(from data: Data) throws -> SessionManifest {
        try makeDecoder().decode(SessionManifest.self, from: data)
    }
}
