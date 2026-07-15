import Foundation

/// Чистая логика выбора сегментов для склейки при восстановлении и чистом стопе.
///
/// Держим отдельно от файловой системы и `ffmpeg`, чтобы главное правило крэш-безопасности —
/// «недописанный последний сегмент не роняет восстановление, а спасается» — покрывалось
/// юнит-тестом (`RecoveryTests`). Runtime (`RecoveryManager`, `SegmentAssembler`) лишь подставляет
/// сюда имена файлов, их размеры и начало файла из FS и исполняет решение.
public enum Recovery {
    /// Минимальный размер валидного WAV-сегмента, байт. Заголовок RIFF/WAVE ~44 байта; файл меньше
    /// порога — это пустой/недописанный (битый) сегмент, типичный результат `kill -9` посередине.
    public static let minValidSegmentBytes = 64

    /// Сколько байт начала файла нужно прочитать, чтобы проверить заголовок.
    ///
    /// Не найденный в префиксе `data` делает сегмент невалидным, поэтому запас берём с большим
    /// избытком: реальный `AVAssetWriter(fileType: .wav)` вставляет перед `data` выравнивающий чанк
    /// `FLLR` и кладёт заголовок `data` ровно на 4088..4096 — в 4 КиБ он умещался впритык, байт в
    /// байт. Чуть другой `sourceFormatHint`, лишний чанк или смена выравнивания в новой macOS
    /// вытолкнули бы `data` за окно, и тогда **все** сегменты разом стали бы невалидными: склейка
    /// молча вернула бы пустоту, а восстановление — то, ради чего всё и писалось, — не нашло бы
    /// ничего. Чтение 64 КиБ разово на сегмент дешевле такого обрыва.
    public static let headerProbeBytes = 65536

    /// Что делать с сегментом, чтобы он попал в склейку.
    public enum Action: Equatable, Sendable {
        /// Заголовок дописан — файл идёт в `ffmpeg` как есть.
        case include
        /// Заголовок недописан, но аудио в файле есть: чинится по фактическому размеру.
        case repair(WAV.HeaderRepair)
    }

    /// Сегмент, попавший в план, и что с ним делать перед склейкой.
    public struct PlannedSegment: Equatable, Sendable {
        public let fileName: String
        public let action: Action

        public init(fileName: String, action: Action) {
            self.fileName = fileName
            self.action = action
        }
    }

    /// План склейки одной дорожки: отсортированные по номеру пригодные сегменты.
    ///
    /// - Parameters:
    ///   - names: имена файлов из каталога дорожки (могут содержать мусор — отфильтруется).
    ///   - sizeByFileName: размер каждого файла в байтах (из FS).
    ///   - headerByFileName: первые `headerProbeBytes` байт каждого файла (из FS). Файл без
    ///     прочитанного заголовка отбрасывается: подтвердить его целостность нечем.
    /// - Returns: сегменты в порядке возрастания номера с действием для каждого.
    ///
    /// Единственный источник правды о том, что реально записано, — файловая система: `segment_count`
    /// в `session.json` сюда не приходит и приходить не должен (маркер обновляется постфактум и на
    /// крэше отстаёт — доверять ему значило бы потерять запись целиком, см. Task 8.2).
    public static func recoveryPlan(fromFileNames names: [String],
                                    sizeByFileName: [String: Int],
                                    headerByFileName: [String: Data]) -> [PlannedSegment] {
        SegmentLayout.orderedSegments(fromFileNames: names)
            .map(\.fileName)
            .compactMap { name in
                let action = self.action(bytes: sizeByFileName[name] ?? 0,
                                         header: headerByFileName[name] ?? Data())
                return action.map { PlannedSegment(fileName: name, action: $0) }
            }
    }

    /// Что делать с сегментом: включить как есть, починить заголовок или выбросить (`nil`).
    ///
    /// Порядок именно такой: сначала пробуем принять файл, потом спасти, и только если спасать
    /// нечего — выбрасываем. Прежнее правило «заголовок не дописан → в помойку» стоило живого
    /// звука: `kill -9` оставляет последний сегмент с непроставленными размерами, но с реальными
    /// секундами аудио внутри (в живом прогоне — 2.92 с), и обещание «теряем максимум один сегмент»
    /// нарушалось на ровном месте.
    public static func action(bytes: Int, header: Data) -> Action? {
        guard bytes >= minValidSegmentBytes else { return nil }
        if isFinalizedWAVHeader(header, fileSize: bytes) { return .include }
        return WAV.headerRepair(header: header, fileSize: bytes).map(Action.repair)
    }

    /// Пригоден ли сегмент для склейки — сам по себе или после починки заголовка.
    public static func isUsableSegment(bytes: Int, header: Data) -> Bool {
        action(bytes: bytes, header: header) != nil
    }

    /// Валиден ли сегмент **как есть**: достаточно велик и содержит финализированный WAV-заголовок.
    ///
    /// Одного размера мало: убитый `kill -9` посреди сегмента `AVAssetWriter` оставляет файл с
    /// килобайтами аудио, но с непроставленными размерами в заголовке — `ffmpeg` на таком файле
    /// падает и утаскивает за собой склейку всей дорожки. Такой сегмент не выбрасывается, а
    /// чинится (`WAV.headerRepair`); отсюда — эта проверка отвечает только на «нужна ли починка».
    public static func isValidSegment(bytes: Int, header: Data) -> Bool {
        bytes >= minValidSegmentBytes && isFinalizedWAVHeader(header, fileSize: bytes)
    }

    /// Дописан ли WAV-заголовок до конца: RIFF/WAVE-магия на месте, чанки `fmt `/`data` реально
    /// найдены, а размеры проставлены и умещаются в реальный размер файла.
    ///
    /// Незакрытый сегмент ловится по **размеру чанка `data`**: `AVAssetWriter` проставляет его
    /// только в `finishWriting`, поэтому после `kill -9` там ноль при мегабайтах реального аудио
    /// следом (проверено на живом writer'е). Проверка RIFF-размера тут страховка, а не основной
    /// признак: у убитого файла в этом поле остаётся размер преамбулы (4088) — **меньше** файла,
    /// так что она проходит.
    ///
    /// Проверка `data` намеренно «умещается», а не «совпадает байт в байт»: заголовок, объявляющий
    /// **меньше** физического размера, читается `ffmpeg` без ошибок (просто без хвоста), а
    /// требование точного равенства отправило бы такой сегмент на лишнюю починку с обрезкой файла.
    public static func isFinalizedWAVHeader(_ header: Data, fileSize: Int) -> Bool {
        // 36 — минимальный осмысленный RIFF (fmt + пустой data); больше файла — размер не проставлен.
        guard let riffSize = WAV.riffSize(header), riffSize >= 36, riffSize + 8 <= fileSize,
              let layout = WAV.layout(header) else { return false }
        return layout.declaredDataSize > 0
            && layout.dataBodyOffset + layout.declaredDataSize <= fileSize
    }

    /// Есть ли что восстанавливать: маркер сессии указывает на прерванную запись.
    ///
    /// `recording` = процесс не дошёл до чистого стопа (краш/рестарт). `done`/`recovered` уже
    /// финализированы — их трогать не нужно.
    public static func needsRecovery(_ manifest: SessionManifest) -> Bool {
        manifest.status == .recording
    }
}
