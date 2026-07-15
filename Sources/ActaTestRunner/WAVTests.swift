import Testing
import Foundation
import ActaKit

// Чтение WAV-заголовка: длительность по фактическим данным (Task 8.3) и план починки
// недописанного заголовка (Task 8.1). Чистая логика — без файловой системы и ffmpeg.

/// Байт в секунду для формата `SegmentWriter`: 48 кГц, стерео, 16 бит.
private let byteRate = 48_000 * 4

/// Заголовок 16-битного стерео PCM 48 кГц с произвольными размерами. Данные начинаются с 44-го
/// байта, поле размера `data` — 40-е.
private func wavHeader(riffSize: Int, dataSize: Int) -> Data {
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(riffSize)
    bytes += Array("WAVE".utf8)
    bytes += Array("fmt ".utf8)
    bytes += le32(16)
    bytes += le16(1)            // WAVE_FORMAT_PCM
    bytes += le16(2)            // каналы
    bytes += le32(48_000)       // частота
    bytes += le32(byteRate)
    bytes += le16(4)            // blockAlign
    bytes += le16(16)           // бит на сэмпл
    bytes += Array("data".utf8)
    bytes += le32(dataSize)
    return Data(bytes)
}

/// Заголовок закрытого сегмента: размеры проставлены и сходятся с файлом.
private func closedHeader(fileSize: Int) -> Data {
    wavHeader(riffSize: fileSize - 8, dataSize: fileSize - 44)
}

/// Заголовок сегмента, убитого `kill -9`: размеры так и не проставлены.
private func killedHeader() -> Data {
    wavHeader(riffSize: 0, dataSize: 0)
}

private func le16(_ value: Int) -> [UInt8] {
    let v = UInt16(truncatingIfNeeded: value)
    return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
}

// MARK: - Длительность

@Test
func durationComesFromDataNotFromTheClock() {
    // Ровно секунда звука: длительность считается из байтов, а не из интервала между старт/стопом.
    let size = 44 + byteRate
    #expect(WAV.durationSeconds(header: closedHeader(fileSize: size), fileSize: size) == 1.0)
}

@Test
func durationOfUnfinalizedSegmentUsesActualFileSize() {
    // Заголовок объявляет ноль, но 2.92 с звука в файле лежат — их и меряем (случай живого прогона).
    let size = 44 + Int(2.92 * Double(byteRate))
    let duration = WAV.durationSeconds(header: killedHeader(), fileSize: size)
    #expect(duration.map { abs($0 - 2.92) < 0.001 } == true)
}

@Test
func durationIgnoresBytesBeyondDeclaredData() {
    // Заголовок объявляет меньше физического размера (хвост-мусор) — верим заголовку.
    let size = 44 + byteRate * 2
    #expect(WAV.durationSeconds(header: wavHeader(riffSize: size - 8, dataSize: byteRate),
                                fileSize: size) == 1.0)
}

@Test
func durationClampedToWhatTheFileHolds() {
    // Заголовок обещает больше, чем в файле есть: меряем по факту, а не по обещанию.
    #expect(WAV.durationSeconds(header: wavHeader(riffSize: 0, dataSize: byteRate * 10),
                                fileSize: 44 + byteRate) == 1.0)
}

@Test
func durationOfEmptyOrUnreadableHeaderIsNil() {
    #expect(WAV.durationSeconds(header: Data(), fileSize: 4096) == nil)
    #expect(WAV.durationSeconds(header: Data("not a wav at all, just bytes".utf8),
                                fileSize: 4096) == nil)
}

@Test
func durationOfHeaderOnlyFileIsZero() {
    #expect(WAV.durationSeconds(header: killedHeader(), fileSize: 44) == 0)
}

// MARK: - Починка заголовка

@Test
func repairFillsSizesFromActualFileSize() {
    let size = 44 + byteRate
    let repair = WAV.headerRepair(header: killedHeader(), fileSize: size)
    #expect(repair == WAV.HeaderRepair(riffSize: size - 8, dataSizeOffset: 40,
                                       dataSize: byteRate, truncatedFileSize: size))
    #expect(repair?.riffSizeOffset == 4)
}

@Test
func repairTruncatesToWholeFrames() {
    // `kill -9` приходится на середину кадра: обрезаем до целого, иначе ffmpeg ругается на
    // оборванный сэмпл вместо того, чтобы просто доиграть хвост.
    let repair = WAV.headerRepair(header: killedHeader(), fileSize: 44 + byteRate + 3)
    #expect(repair?.dataSize == byteRate)
    #expect(repair?.truncatedFileSize == 44 + byteRate)
}

@Test
func repairedHeaderReadsBackWithTheSameDuration() {
    // Сквозная проверка: после починки заголовок описывает ровно то аудио, что осталось в файле.
    let size = 44 + Int(2.92 * Double(byteRate))
    guard let repair = WAV.headerRepair(header: killedHeader(), fileSize: size) else {
        Issue.record("Сегмент со звуком должен чиниться")
        return
    }
    let patched = wavHeader(riffSize: repair.riffSize, dataSize: repair.dataSize)
    let duration = WAV.durationSeconds(header: patched, fileSize: repair.truncatedFileSize)
    #expect(duration.map { abs($0 - 2.92) < 0.001 } == true)
}

@Test
func nothingToRepairWhenThereIsNoAudio() {
    // Файл из одной преамбулы (writer создал сегмент, но ни одного буфера не принял) и файл,
    // в котором не набралось даже кадра, — чинить нечего, сегмент выбрасывается.
    #expect(WAV.headerRepair(header: killedHeader(), fileSize: 44) == nil)
    #expect(WAV.headerRepair(header: killedHeader(), fileSize: 46) == nil)
    #expect(WAV.headerRepair(header: Data(), fileSize: 8192) == nil)
    #expect(WAV.headerRepair(header: Data(repeating: 0, count: 128), fileSize: 8192) == nil)
}

// MARK: - Раскладка

@Test
func layoutRejectsUnparseableHeaders() {
    // Не RIFF/WAVE; RIFF без чанка `data` в прочитанном префиксе; `data` без предшествующего `fmt `.
    #expect(WAV.layout(Data("RIFX....WAVEfmt ".utf8)) == nil)
    #expect(WAV.layout(Data(Array("RIFF".utf8) + le32(4088) + Array("WAVE".utf8))) == nil)
    var noFormat: [UInt8] = Array("RIFF".utf8) + le32(4088) + Array("WAVE".utf8)
    noFormat += Array("data".utf8) + le32(1024)
    #expect(WAV.layout(Data(noFormat)) == nil)
}

@Test
func layoutFindsDataAfterPaddingChunk() {
    // Живой `AVAssetWriter` вставляет перед `data` выравнивающий чанк `FLLR` — раскладка обязана
    // его перешагнуть, иначе валидными не будут вообще никакие сегменты.
    var bytes: [UInt8] = Array("RIFF".utf8) + le32(4088) + Array("WAVE".utf8)
    bytes += Array("fmt ".utf8) + le32(16)
    bytes += le16(1) + le16(2) + le32(48_000) + le32(byteRate) + le16(4) + le16(16)
    bytes += Array("FLLR".utf8) + le32(64) + [UInt8](repeating: 0, count: 64)
    bytes += Array("data".utf8) + le32(1024)

    let layout = WAV.layout(Data(bytes))
    #expect(layout?.declaredDataSize == 1024)
    #expect(layout?.dataBodyOffset == bytes.count)
    #expect(layout?.format.byteRate == byteRate)
}
