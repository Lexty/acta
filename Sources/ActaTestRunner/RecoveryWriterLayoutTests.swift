import ActaKit
import Foundation
import Testing

// Проверки заголовка на раскладке, которую реально пишет `AVAssetWriter(fileType: .wav)` —
// снята с живого writer'а. Держим отдельно от синтетических заголовков `RecoveryTests`: тут
// важно не «логика разбора верна», а «окно `headerProbeBytes` покрывает реальный файл».

/// Заголовок в точности той раскладки, которую пишет живой `AVAssetWriter(fileType: .wav)`:
/// `JUNK`(28) → `fmt `(40, extensible) → `FLLR`(padding) → `data`. При `padding: 3984` заголовок
/// `data` заканчивается ровно на 4096-м байте — как в реально снятом с writer'а файле.
/// Выравнивающий `FLLR` и делает окно `headerProbeBytes` узким местом.
private func realWriterLayout(dataSize: Int, fileSize: Int, padding: Int = 3984) -> Data {
    var bytes: [UInt8] = []
    bytes += Array("RIFF".utf8)
    bytes += le32(fileSize - 8)
    bytes += Array("WAVE".utf8)
    bytes += Array("JUNK".utf8)
    bytes += le32(28)
    bytes += [UInt8](repeating: 0, count: 28)
    bytes += Array("fmt ".utf8)
    bytes += le32(40)
    bytes += extensibleFormatBody()
    bytes += Array("FLLR".utf8)
    bytes += le32(padding)
    bytes += [UInt8](repeating: 0, count: padding)
    bytes += Array("data".utf8)
    bytes += le32(dataSize)
    return Data(bytes)
}

@Test
func realWriterLayoutFitsInProbeWindow() {
    // Регрессия: у живого writer'а заголовок `data` заканчивается ровно на 4096-м байте — в прежнем
    // окне 4096 он умещался байт в байт. Любой лишний чанк вытолкнул бы его наружу, и тогда
    // невалидными разом стали бы ВСЕ сегменты: и склейка, и восстановление вернули бы пустоту.
    let header = realWriterLayout(dataSize: 192_000, fileSize: 196_096)
    #expect(header.count == 4096)
    #expect(Recovery.headerProbeBytes > header.count)
    #expect(Recovery.isValidSegment(bytes: 196_096, header: header))
}

@Test
func realWriterLayoutWithLargerPaddingStillValid() {
    // Запас окна не должен держаться на текущем размере выравнивания: `data`, уехавший за 4 КиБ
    // (другой formatHint, лишний чанк, смена выравнивания в новой macOS), обязан находиться —
    // иначе сегменты разом становятся невалидными, а это молчаливая потеря всей записи.
    // Заголовок 16112 байт (выравнивание 16000) + 192000 байт аудио.
    let header = realWriterLayout(dataSize: 192_000, fileSize: 208_112, padding: 16_000)
    #expect(header.count > 4096)
    #expect(header.count <= Recovery.headerProbeBytes)
    #expect(Recovery.isValidSegment(bytes: 208_112, header: header))
}

@Test
func realWriterLayoutFromCrashRejected() {
    // Убитый `kill -9` writer оставляет размер `data` нулевым, а в поле RIFF — размер преамбулы
    // (4088), который МЕНЬШЕ файла, то есть RIFF-проверку проходит. Отбраковать сегмент обязан
    // именно нулевой `data`.
    var bytes = [UInt8](realWriterLayout(dataSize: 0, fileSize: 382_464))
    bytes.replaceSubrange(4..<8, with: le32(4088))
    #expect(Recovery.isValidSegment(bytes: 382_464, header: Data(bytes)) == false)
}
