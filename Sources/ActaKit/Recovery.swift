import Foundation

/// Чистая логика выбора сегментов для склейки при восстановлении и чистом стопе.
///
/// Держим отдельно от файловой системы и `ffmpeg`, чтобы главное правило крэш-безопасности —
/// «недописанный последний сегмент отбрасывается, а не роняет восстановление» — покрывалось
/// юнит-тестом (`RecoveryTests`). Runtime (`RecoveryManager`, `SegmentAssembler`) лишь подставляет
/// сюда имена файлов, их размеры и начало файла из FS.
public enum Recovery {
    /// Минимальный размер валидного WAV-сегмента, байт. Заголовок RIFF/WAVE ~44 байта; файл меньше
    /// порога — это пустой/недописанный (битый) сегмент, типичный результат `kill -9` посередине.
    public static let minValidSegmentBytes = 64

    /// Сколько байт начала файла нужно прочитать, чтобы проверить заголовок. Наш writer кладёт
    /// `fmt `/`data` в первую сотню байт; запас — на чанки (`LIST`, `fact`) перед `data`.
    public static let headerProbeBytes = 4096

    /// План склейки одной дорожки: отсортированные по номеру валидные сегменты.
    ///
    /// - Parameters:
    ///   - names: имена файлов из каталога дорожки (могут содержать мусор — отфильтруется).
    ///   - sizeByFileName: размер каждого файла в байтах (из FS).
    ///   - headerByFileName: первые `headerProbeBytes` байт каждого файла (из FS). Файл без
    ///     прочитанного заголовка считается невалидным: подтвердить его целостность нечем.
    /// - Returns: имена сегментов в порядке возрастания номера, прошедшие проверку.
    ///
    /// Битый сегмент отбрасывается независимо от позиции: пропуск одного чанка аудио допустим,
    /// падение восстановления — нет. На практике битым бывает только последний (незакрытый) сегмент.
    public static func recoveryPlan(fromFileNames names: [String],
                                    sizeByFileName: [String: Int],
                                    headerByFileName: [String: Data]) -> [String] {
        SegmentLayout.orderedSegments(fromFileNames: names)
            .map(\.fileName)
            .filter { isValidSegment(bytes: sizeByFileName[$0] ?? 0,
                                     header: headerByFileName[$0] ?? Data()) }
    }

    /// Валиден ли сегмент: достаточно велик **и** содержит финализированный WAV-заголовок.
    ///
    /// Одного размера мало: убитый `kill -9` посреди сегмента `AVAssetWriter` оставляет файл с
    /// килобайтами аудио, но с непроставленными размерами в заголовке — `ffmpeg` на таком файле
    /// падает и утаскивает за собой склейку всей дорожки.
    public static func isValidSegment(bytes: Int, header: Data) -> Bool {
        bytes >= minValidSegmentBytes && isFinalizedWAVHeader(header, fileSize: bytes)
    }

    /// Дописан ли WAV-заголовок до конца: RIFF/WAVE-магия на месте, чанки `fmt `/`data` реально
    /// найдены, а размеры проставлены и умещаются в реальный размер файла.
    ///
    /// Незакрытый writer оставляет в поле размера плейсхолдер (ноль или заведомо больше файла) —
    /// именно это и ловим. Но одной RIFF-магии с правдоподобным размером мало: файл из `RIFF`/`WAVE`
    /// и нулей/мусора без осмысленных чанков `ffmpeg` отвергает и утаскивает за собой склейку всей
    /// дорожки. Поэтому требуем найти `fmt ` и `data` в прочитанном префиксе; не нашли —
    /// подтвердить целостность нечем, сегмент отбрасывается.
    ///
    /// Проверка `data` намеренно «умещается», а не «совпадает байт в байт»: заголовок, объявляющий
    /// **меньше** физического размера, читается `ffmpeg` без ошибок (просто без хвоста), а
    /// требование точного равенства выбросило бы такой сегмент целиком — потеря данных там, где
    /// их можно спасти. Правило крэш-безопасности здесь — «битый сегмент не роняет склейку»,
    /// а не «файл идеален».
    public static func isFinalizedWAVHeader(_ header: Data, fileSize: Int) -> Bool {
        let bytes = [UInt8](header)
        guard bytes.count >= 12,
              hasChunkID(bytes, at: 0, "RIFF"),
              hasChunkID(bytes, at: 8, "WAVE") else { return false }

        // 36 — минимальный осмысленный RIFF (fmt + пустой data); больше файла — размер не проставлен.
        let riffSize = Int(uint32(bytes, at: 4))
        guard riffSize >= 36, riffSize + 8 <= fileSize else { return false }

        var offset = 12
        var hasFormat = false
        while offset + 8 <= bytes.count {
            let size = Int(uint32(bytes, at: offset + 4))
            if hasChunkID(bytes, at: offset, "fmt ") {
                guard size >= 16,
                      isValidPCMFormatChunk(bytes, bodyAt: offset + 8, bodySize: size) else { return false }
                hasFormat = true
            } else if hasChunkID(bytes, at: offset, "data") {
                return hasFormat && size > 0 && offset + 8 + size <= fileSize
            }
            offset += 8 + size + (size % 2) // чанки выравниваются по чётной границе
        }
        return false
    }

    /// Описывает ли тело чанка `fmt ` читаемый PCM-поток.
    ///
    /// Размера чанка мало: `fmt ` длиной 16 с нулевым телом формально «на месте», но `ffmpeg` на
    /// таком сегменте падает (`Invalid sample rate: 0`) и утаскивает за собой склейку всей дорожки.
    /// Проверяем поля на осмысленность, а не на точное совпадание с настройками writer'а: сегмент
    /// с другим (но валидным) форматом `ffmpeg` прочитает, а мы бы его зря выбросили.
    private static func isValidPCMFormatChunk(_ bytes: [UInt8], bodyAt offset: Int,
                                              bodySize: Int) -> Bool {
        // Тело не попало в прочитанный префикс — подтвердить формат нечем.
        guard offset + 16 <= bytes.count else { return false }
        let format = uint16(bytes, at: offset)
        let channels = Int(uint16(bytes, at: offset + 2))
        let sampleRate = Int(uint32(bytes, at: offset + 4))
        let blockAlign = Int(uint16(bytes, at: offset + 12))
        let bitsPerSample = Int(uint16(bytes, at: offset + 14))

        switch format {
        case wavFormatPCM: break
        case wavFormatExtensible:
            guard isValidExtensibleTail(bytes, bodyAt: offset, bodySize: bodySize) else { return false }
        default: return false
        }
        guard channels > 0, sampleRate > 0 else { return false }
        guard bitsPerSample > 0, bitsPerSample % 8 == 0 else { return false }
        return blockAlign == channels * bitsPerSample / 8
    }

    /// Досказан ли `WAVE_FORMAT_EXTENSIBLE` до конца и описывает ли он именно PCM.
    ///
    /// Одного тега `0xFFFE` мало: с 16-байтовым телом PCM-раскладки формат недоописан — реального
    /// кодека в нём нет, и `ffmpeg` такой сегмент отвергает (`Codec none not supported in WAVE
    /// format`), утаскивая за собой склейку всей дорожки. Настоящий extensible несёт `cbSize` ≥ 22 и
    /// GUID подформата; принимаем только PCM-GUID — прочие (например IEEE float) наш `-c copy`
    /// склеить с 16-битными сегментами всё равно не сможет.
    private static func isValidExtensibleTail(_ bytes: [UInt8], bodyAt offset: Int,
                                              bodySize: Int) -> Bool {
        guard bodySize >= 40, offset + 40 <= bytes.count else { return false }
        guard Int(uint16(bytes, at: offset + 16)) >= 22 else { return false }
        return Array(bytes[(offset + 24)..<(offset + 40)]) == pcmSubformatGUID
    }

    /// `WAVE_FORMAT_PCM` — единственный формат, в котором пишет наш writer.
    private static let wavFormatPCM: UInt16 = 1

    /// `WAVE_FORMAT_EXTENSIBLE` — форма записи того же PCM для многоканального звука; `ffmpeg` её
    /// читает (при досказанном теле, см. `isValidExtensibleTail`), поэтому такой сегмент
    /// отбрасывать не за что.
    private static let wavFormatExtensible: UInt16 = 0xFFFE

    /// `KSDATAFORMAT_SUBTYPE_PCM` — GUID `00000001-0000-0010-8000-00AA00389B71` в раскладке WAV
    /// (первые три поля little-endian, последние восемь байт — как есть).
    private static let pcmSubformatGUID: [UInt8] = [
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
    ]

    /// Есть ли что восстанавливать: маркер сессии указывает на прерванную запись.
    ///
    /// `recording` = процесс не дошёл до чистого стопа (краш/рестарт). `done`/`recovered` уже
    /// финализированы — их трогать не нужно.
    public static func needsRecovery(_ manifest: SessionManifest) -> Bool {
        manifest.status == .recording
    }

    // MARK: - Приватное

    /// Совпадает ли четырёхбайтовый ASCII-идентификатор чанка по смещению с ожидаемым.
    private static func hasChunkID(_ bytes: [UInt8], at offset: Int, _ expected: String) -> Bool {
        guard offset + 4 <= bytes.count else { return false }
        return Array(bytes[offset..<(offset + 4)]) == Array(expected.utf8)
    }

    /// Little-endian `UInt16` по смещению (формат полей в чанке `fmt `).
    private static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    /// Little-endian `UInt32` по смещению (формат полей размера в RIFF).
    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
