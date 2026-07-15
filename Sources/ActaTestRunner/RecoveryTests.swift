import Testing
import Foundation
import ActaKit

// Логика восстановления и маркера сессии — чистая, покрыта отдельно от файловой системы/ffmpeg.

// MARK: - Фикстуры WAV-заголовков

/// Заголовок финализированного WAV: размеры проставлены и сходятся с размером файла.
private func finalizedHeader(fileSize: Int) -> Data {
    header(riffSize: fileSize - 8, dataSize: fileSize - 44)
}

/// Заголовок с произвольными размерами — для случаев недописанного файла.
private func header(riffSize: Int, dataSize: Int) -> Data {
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(riffSize)
    bytes += Array("WAVE".utf8)
    bytes += Array("fmt ".utf8)
    bytes += le32(16)
    bytes += pcmFormatBody()
    bytes += Array("data".utf8)
    bytes += le32(dataSize)
    return Data(bytes)
}

/// Тело чанка `fmt `: 16-битный стерео PCM 48 кГц — то, что пишет `SegmentWriter`.
/// Поля можно переопределить, чтобы собрать заведомо битый формат.
private func pcmFormatBody(format: Int = 1, channels: Int = 2, sampleRate: Int = 48_000,
                           bitsPerSample: Int = 16, blockAlign: Int? = nil) -> [UInt8] {
    let align = blockAlign ?? channels * bitsPerSample / 8
    var bytes: [UInt8] = []
    bytes += le16(format)
    bytes += le16(channels)
    bytes += le32(sampleRate)
    bytes += le32(sampleRate * align) // byteRate
    bytes += le16(align)
    bytes += le16(bitsPerSample)
    return bytes
}

func le32(_ value: Int) -> [UInt8] {
    let v = UInt32(truncatingIfNeeded: value)
    return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

private func le16(_ value: Int) -> [UInt8] {
    let v = UInt16(truncatingIfNeeded: value)
    return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
}

/// Заголовки для набора валидных сегментов одного размера.
private func headers(_ names: [String], fileSize: Int) -> [String: Data] {
    Dictionary(uniqueKeysWithValues: names.map { ($0, finalizedHeader(fileSize: fileSize)) })
}

/// Имена сегментов, попавших в план (порядок и состав — то, что уходит в `ffmpeg`).
private func planned(_ plan: [Recovery.PlannedSegment]) -> [String] {
    plan.map(\.fileName)
}

/// Действие плана для сегмента; `nil`, если сегмент в план не попал.
private func action(_ plan: [Recovery.PlannedSegment], for name: String) -> Recovery.Action? {
    plan.first { $0.fileName == name }?.action
}

// MARK: - План склейки

@Test
func recoveryPlanOrdersValidSegments() {
    let names = ["0002.wav", "0000.wav", "0001.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 4096, "0002.wav": 4096]
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: headers(names, fileSize: 4096))
    #expect(planned(plan) == ["0000.wav", "0001.wav", "0002.wav"])
    #expect(plan.allSatisfy { $0.action == .include })
}

@Test
func recoveryPlanDropsEmptyLastSegment() {
    // Сегмент, в который не успел лечь ни один буфер: спасать нечего, отбрасываем.
    let names = ["0000.wav", "0001.wav", "0002.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 4096, "0002.wav": 0]
    var byName = headers(names, fileSize: 4096)
    byName["0002.wav"] = Data()
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: byName)
    #expect(planned(plan) == ["0000.wav", "0001.wav"])
}

@Test
func recoveryPlanRepairsLastSegmentWithUnfinalizedHeader() {
    // Главный крэш-кейс (Task 8.1): убитый writer оставил килобайты аудио, но размеры в заголовке
    // не проставлены. Такой сегмент чинится по фактическому размеру, а не выбрасывается: раньше
    // это стоило живых секунд записи.
    let names = ["0000.wav", "0001.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 8192]
    var byName = headers(names, fileSize: 4096)
    byName["0001.wav"] = header(riffSize: 0, dataSize: 0)
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: byName)
    #expect(planned(plan) == ["0000.wav", "0001.wav"])
    #expect(action(plan, for: "0000.wav") == .include)
    // Данные идут с 44-го байта: 8192 - 44 = 8148, и это уже целое число кадров по 4 байта.
    #expect(action(plan, for: "0001.wav")
        == .repair(WAV.HeaderRepair(riffSize: 8184, dataSizeOffset: 40,
                                    dataSize: 8148, truncatedFileSize: 8192)))
}

@Test
func recoveryPlanDropsCorruptMiddleSegment() {
    // Битый сегмент отбрасывается независимо от позиции: пропуск одного чанка допустим, но
    // трейлинг-валидные сегменты должны сохраниться (а не обрезаться на первом битом).
    let names = ["0000.wav", "0001.wav", "0002.wav"]
    let sizes = ["0000.wav": 4096, "0001.wav": 0, "0002.wav": 4096]
    var byName = headers(names, fileSize: 4096)
    byName["0001.wav"] = Data()
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: byName)
    #expect(planned(plan) == ["0000.wav", "0002.wav"])
}

@Test
func recoveryPlanFiltersJunkAndMissingSizes() {
    let names = ["0000.wav", ".DS_Store", "combined.wav", "0001.wav"]
    // 0001.wav отсутствует в размерах → трактуем как 0 → отбрасываем.
    let sizes = ["0000.wav": 4096]
    let plan = Recovery.recoveryPlan(fromFileNames: names, sizeByFileName: sizes,
                                     headerByFileName: headers(names, fileSize: 4096))
    #expect(planned(plan) == ["0000.wav"])
}

@Test
func recoveryPlanDropsSegmentWithUnreadableHeader() {
    // Заголовок не прочитался (файл исчез/недоступен) — ни принять, ни починить: неизвестно даже,
    // где в файле начинается аудио.
    let plan = Recovery.recoveryPlan(fromFileNames: ["0000.wav"], sizeByFileName: ["0000.wav": 4096],
                                     headerByFileName: [:])
    #expect(plan.isEmpty)
}

@Test
func recoveryPlanEmptyWhenNothingValid() {
    let plan = Recovery.recoveryPlan(fromFileNames: ["0000.wav"], sizeByFileName: ["0000.wav": 10],
                                     headerByFileName: ["0000.wav": finalizedHeader(fileSize: 10)])
    #expect(plan.isEmpty)
}

@Test
func recoveryPlanKeepsEveryLiveRunSegment() {
    // Приёмка Task 8.1 на фактах живого прогона (2026-07-15): на момент `kill -9` дорожка system
    // держала 12 сегментов — 11 закрытых по 15 с и последний недописанный с 2.92 с звука.
    // Прежнее правило оставляло 11 (165.0 с); все 12 дают ≈167.9 с.
    let rate = 48_000 * 4 // 16-бит стерео: байт в секунду
    let closedSize = 44 + 15 * rate
    let killedSize = 44 + Int(2.92 * Double(rate))
    let names = (0..<12).map { SegmentLayout.segmentFileName(index: $0) }
    var sizes: [String: Int] = [:]
    var byName: [String: Data] = [:]
    for (index, name) in names.enumerated() {
        let killed = index == 11
        sizes[name] = killed ? killedSize : closedSize
        byName[name] = killed ? header(riffSize: 0, dataSize: 0) : finalizedHeader(fileSize: closedSize)
    }

    let plan = Recovery.recoveryPlan(fromFileNames: names.shuffled(), sizeByFileName: sizes,
                                     headerByFileName: byName)
    #expect(planned(plan) == names)
    #expect(plan.filter { $0.action == .include }.count == 11)

    let duration = plan.reduce(0.0) { total, segment in
        let size = sizes[segment.fileName] ?? 0
        return total + (WAV.durationSeconds(header: byName[segment.fileName] ?? Data(),
                                            fileSize: size) ?? 0)
    }
    #expect(abs(duration - 167.92) < 0.01)
}

// MARK: - Проверка сегмента

@Test
func isValidSegmentThreshold() {
    let size = Recovery.minValidSegmentBytes
    #expect(Recovery.isValidSegment(bytes: size, header: finalizedHeader(fileSize: size)))
    #expect(Recovery.isValidSegment(bytes: size - 1,
                                    header: finalizedHeader(fileSize: size - 1)) == false)
    #expect(Recovery.isValidSegment(bytes: 0, header: Data()) == false)
}

@Test
func finalizedHeaderAccepted() {
    #expect(Recovery.isFinalizedWAVHeader(finalizedHeader(fileSize: 4096), fileSize: 4096))
}

@Test
func headerWithoutRIFFMagicRejected() {
    #expect(Recovery.isFinalizedWAVHeader(Data(repeating: 0, count: 128), fileSize: 4096) == false)
    #expect(Recovery.isFinalizedWAVHeader(Data("free-form garbage padded".utf8),
                                          fileSize: 4096) == false)
}

@Test
func headerWithUnsetSizesRejected() {
    // Незакрытый AVAssetWriter: магия на месте, размеры — плейсхолдеры.
    #expect(Recovery.isFinalizedWAVHeader(header(riffSize: 0, dataSize: 0), fileSize: 8192) == false)
    #expect(Recovery.isFinalizedWAVHeader(header(riffSize: 4, dataSize: 0), fileSize: 8192) == false)
}

@Test
func headerPromisingMoreThanFileHasRejected() {
    // Размер заявлен, но файл обрезан на середине — данных меньше, чем обещано.
    #expect(Recovery.isFinalizedWAVHeader(finalizedHeader(fileSize: 65_536),
                                          fileSize: 8192) == false)
    // RIFF сходится, а data-чанк вылезает за конец файла.
    #expect(Recovery.isFinalizedWAVHeader(header(riffSize: 4088, dataSize: 65_536),
                                          fileSize: 4096) == false)
}

@Test
func headerWithoutChunksRejected() {
    // RIFF/WAVE + правдоподобный размер, но осмысленных чанков нет: ffmpeg такой файл отвергает,
    // поэтому доверять одному размеру RIFF нельзя — подтвердить целостность нечем.
    var bare: [UInt8] = []
    bare += Array("RIFF".utf8)
    bare += le32(4088)
    bare += Array("WAVE".utf8)
    #expect(Recovery.isFinalizedWAVHeader(Data(bare), fileSize: 4096) == false)

    // Тот же случай, но хвост забит нулями/мусором вместо чанков.
    #expect(Recovery.isFinalizedWAVHeader(Data(bare + [UInt8](repeating: 0, count: 512)),
                                          fileSize: 4096) == false)
    #expect(Recovery.isFinalizedWAVHeader(Data(bare + Array("junk padding not a chunk".utf8)),
                                          fileSize: 4096) == false)
}

@Test
func headerWithDataButWithoutFormatRejected() {
    // data без fmt — не описанный поток: ffmpeg не знает, как его читать.
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(4088)
    bytes += Array("WAVE".utf8)
    bytes += Array("data".utf8)
    bytes += le32(4052)
    #expect(Recovery.isFinalizedWAVHeader(Data(bytes), fileSize: 4096) == false)
}

@Test
func headerWithChunkBeforeFormatAccepted() {
    // Посторонний чанк (LIST) перед fmt /data пропускается по размеру, сегмент остаётся валидным.
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(4088)
    bytes += Array("WAVE".utf8)
    bytes += Array("LIST".utf8)
    bytes += le32(8)
    bytes += [UInt8](repeating: 0, count: 8)
    bytes += Array("fmt ".utf8)
    bytes += le32(16)
    bytes += pcmFormatBody()
    bytes += Array("data".utf8)
    bytes += le32(4032)
    #expect(Recovery.isFinalizedWAVHeader(Data(bytes), fileSize: 4096))
}

// MARK: - Проверка чанка fmt

/// Заголовок с телом `fmt `, собранным из произвольных полей формата.
private func headerWithFormat(_ body: [UInt8], fileSize: Int = 4096) -> Data {
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(fileSize - 8)
    bytes += Array("WAVE".utf8)
    bytes += Array("fmt ".utf8)
    bytes += le32(body.count)
    bytes += body
    bytes += Array("data".utf8)
    // Хвост data занимает всё, что осталось от файла после заголовка (тело fmt переменной длины).
    bytes += le32(fileSize - (bytes.count + 4))
    return Data(bytes)
}

@Test
func headerWithZeroedFormatBodyRejected() {
    // fmt на месте и размером 16, но тело — нули: ffmpeg падает с `Invalid sample rate: 0`
    // и утаскивает склейку всей дорожки. Одного размера чанка мало.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat([UInt8](repeating: 0, count: 16)),
                                          fileSize: 4096) == false)
}

@Test
func headerWithNonsenseFormatFieldsRejected() {
    // Каждое поле по отдельности делает поток нечитаемым.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(sampleRate: 0)),
                                          fileSize: 4096) == false)
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(channels: 0)),
                                          fileSize: 4096) == false)
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(bitsPerSample: 0)),
                                          fileSize: 4096) == false)
    // Битность не кратна байту.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(bitsPerSample: 12)),
                                          fileSize: 4096) == false)
    // blockAlign не сходится с channels * bits / 8 — заголовок противоречив.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(blockAlign: 3)),
                                          fileSize: 4096) == false)
    // Не PCM-тег (например, 0 — незаполненное поле).
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(format: 0)),
                                          fileSize: 4096) == false)
}

/// Тело `fmt ` для WAVE_FORMAT_EXTENSIBLE: PCM-раскладка + cbSize/validBits/channelMask/GUID.
func extensibleFormatBody(cbSize: Int = 22, subformat: [UInt8] = pcmSubformatGUID) -> [UInt8] {
    var bytes = pcmFormatBody(format: 0xFFFE)
    bytes += le16(cbSize)
    bytes += le16(16) // wValidBitsPerSample
    bytes += le32(3)  // dwChannelMask: FRONT_LEFT | FRONT_RIGHT
    bytes += subformat
    return bytes
}

/// KSDATAFORMAT_SUBTYPE_PCM.
let pcmSubformatGUID: [UInt8] = [
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
]

@Test
func headerWithExtensiblePCMAccepted() {
    // Досказанный WAVE_FORMAT_EXTENSIBLE — та же PCM-раскладка; ffmpeg её читает, отбрасывать
    // не за что.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(extensibleFormatBody()), fileSize: 4096))
}

@Test
func headerWithUnderspecifiedExtensibleRejected() {
    // Тег 0xFFFE с 16-байтовым телом PCM: формат недоописан — кодека в нём нет, ffmpeg отвергает
    // (`Codec none not supported in WAVE format`) и утаскивает склейку всей дорожки.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(pcmFormatBody(format: 0xFFFE)),
                                          fileSize: 4096) == false)
    // Тело нужной длины, но cbSize не проставлен — расширение не заявлено.
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(extensibleFormatBody(cbSize: 0)),
                                          fileSize: 4096) == false)
    // Подформат не PCM (здесь IEEE float) — `-c copy` с 16-битными сегментами не склеится.
    var float = pcmSubformatGUID
    float[0] = 0x03
    #expect(Recovery.isFinalizedWAVHeader(headerWithFormat(extensibleFormatBody(subformat: float)),
                                          fileSize: 4096) == false)
    // GUID обрезан: тело не дотягивает до 40 байт.
    #expect(Recovery.isFinalizedWAVHeader(
        headerWithFormat(Array(extensibleFormatBody().prefix(32))), fileSize: 4096) == false)
}

@Test
func headerWithFormatBodyOutsideProbeRejected() {
    // fmt объявлен, но тело не попало в прочитанный префикс — подтвердить формат нечем.
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(4088)
    bytes += Array("WAVE".utf8)
    bytes += Array("fmt ".utf8)
    bytes += le32(16)
    bytes += [UInt8](repeating: 0, count: 8) // тело обрезано на середине
    #expect(Recovery.isFinalizedWAVHeader(Data(bytes), fileSize: 4096) == false)
}

// MARK: - Маркер сессии

@Test
func needsRecoveryOnlyForRecordingStatus() {
    let base = SessionManifest(status: .recording, startedAt: Date(timeIntervalSince1970: 0),
                               segmentSeconds: 15, segmentCount: 3)
    #expect(Recovery.needsRecovery(base))

    var done = base; done.status = .done
    #expect(Recovery.needsRecovery(done) == false)

    var recovered = base; recovered.status = .recovered
    #expect(Recovery.needsRecovery(recovered) == false)
}

@Test
func sessionManifestRoundTrips() throws {
    let original = SessionManifest(status: .recording,
                                   startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   segmentSeconds: 15, segmentCount: 7)
    let data = try original.encoded()
    let decoded = try SessionManifest.decode(from: data)
    #expect(decoded == original)
}

@Test
func sessionManifestUsesSnakeCaseAndIsoDate() throws {
    let manifest = SessionManifest(status: .done,
                                   startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   segmentSeconds: 10, segmentCount: 2)
    let json = String(data: try manifest.encoded(), encoding: .utf8) ?? ""
    #expect(json.contains("\"started_at\""))
    #expect(json.contains("\"segment_seconds\""))
    #expect(json.contains("\"segment_count\""))
    #expect(json.contains("\"status\" : \"done\""))
    // ISO-8601 для 1_700_000_000 = 2023-11-14T22:13:20Z.
    #expect(json.contains("2023-11-14T22:13:20Z"))
}

@Test
func sessionManifestDecodesFromHandWrittenJSON() throws {
    let raw = """
    {
      "status": "recovered",
      "started_at": "2023-11-14T22:13:20Z",
      "segment_seconds": 15,
      "segment_count": 4
    }
    """
    let manifest = try SessionManifest.decode(from: Data(raw.utf8))
    #expect(manifest.status == .recovered)
    #expect(manifest.segmentSeconds == 15)
    #expect(manifest.segmentCount == 4)
    #expect(manifest.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
}
