import AVFoundation
import ActaKit
import os

/// Потоковая **сегментная** запись одной дорожки на диск.
///
/// Пишем не один длинный файл, а короткие сегменты по ~`SegmentLayout.defaultSegmentSeconds` с
/// (см. скилл `crash-safe-recording`): каждый сегмент — отдельный `AVAssetWriter`, который по
/// истечении интервала **финализируется** (`finishWriting`) и становится валидным WAV. Жёсткий
/// краш/рестарт теряет максимум последний незакрытый сегмент.
///
/// Все методы вызываются с сериализованной очереди делегата `SCStream` (по одной на дорожку),
/// поэтому внутреннее состояние не требует дополнительной синхронизации.
final class SegmentWriter {
    /// Каталог дорожки (например `.../system`), куда пишутся `NNNN.wav`.
    private let directory: URL

    /// Порог ротации в секундах.
    private let segmentSeconds: Double

    private let log: Logger

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var segmentIndex = 0
    private var segmentStart: CMTime = .invalid

    /// Число финализированных (закрытых) сегментов — для `session.json`/самодиагностики.
    private(set) var finalizedCount = 0

    init(directory: URL, segmentSeconds: Double = Double(SegmentLayout.defaultSegmentSeconds)) {
        self.directory = directory
        self.segmentSeconds = segmentSeconds
        self.log = Logger(subsystem: AppInfo.bundleID, category: "SegmentWriter")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// URL сегмента по текущему индексу.
    private func segmentURL(index: Int) -> URL {
        directory.appendingPathComponent(SegmentLayout.segmentFileName(index: index))
    }

    /// Записать очередной буфер. Открывает первый сегмент по первому буферу, ротирует по времени.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return }

        if writer == nil {
            startSegment(at: pts, formatHint: CMSampleBufferGetFormatDescription(sampleBuffer))
        } else if CMTimeGetSeconds(CMTimeSubtract(pts, segmentStart)) >= segmentSeconds {
            rotate(at: pts, formatHint: CMSampleBufferGetFormatDescription(sampleBuffer))
        }

        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Финализировать текущий сегмент (чистый стоп). После вызова writer сброшен.
    func finish() {
        finalizeCurrent()
    }

    // MARK: - Приватное

    private func startSegment(at pts: CMTime, formatHint: CMFormatDescription?) {
        let url = segmentURL(index: segmentIndex)
        try? FileManager.default.removeItem(at: url)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.pcmOutputSettings,
                                           sourceFormatHint: formatHint)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                log.error("Не удалось добавить вход в writer для \(url.lastPathComponent, privacy: .public)")
                return
            }
            writer.add(input)
            guard writer.startWriting() else {
                log.error("startWriting не удался: \(String(describing: writer.error), privacy: .public)")
                return
            }
            writer.startSession(atSourceTime: pts)
            self.writer = writer
            self.input = input
            self.segmentStart = pts
        } catch {
            let name = url.lastPathComponent
            log.error("Не удалось создать сегмент \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotate(at pts: CMTime, formatHint: CMFormatDescription?) {
        finalizeCurrent()
        segmentIndex += 1
        startSegment(at: pts, formatHint: formatHint)
    }

    private func finalizeCurrent() {
        guard let writer, let input else { return }
        self.writer = nil
        self.input = nil
        self.segmentStart = .invalid
        input.markAsFinished()
        // Сегмент закрыт: считаем его в счётчике сразу (мутация только с очереди дорожки, гонки
        // нет). Финализация файла асинхронна, но ранее записанные сегменты уже валидны — краш в
        // этот момент теряет максимум текущий. Валидность подтверждается ffprobe/восстановлением.
        finalizedCount += 1
        writer.finishWriting { }
    }

    /// Единые настройки WAV/PCM: 48 кГц, стерео, 16 бит. Приводим обе дорожки к одному формату,
    /// чтобы сегменты склеивались `-c copy` без перекодирования.
    private static var pcmOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}
