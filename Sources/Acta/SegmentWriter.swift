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

    /// Вызывается при закрытии каждого сегмента — с очереди дорожки, синхронно. Тем самым
    /// `session.json` узнаёт о новом сегменте ровно тогда, когда тот появился на диске (Task 8.2);
    /// подписчик обязан не блокировать очередь (запись маркера уходит на свою, см.
    /// `RecordingSession`), иначе он подвиснет на горячем пути аудио.
    var onSegmentFinalized: (@Sendable () -> Void)?

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var segmentIndex = 0
    private var segmentStart: CMTime = .invalid

    /// Финализации, запущенные ротацией/рестартом и ещё не отработавшие. Файл сегмента валиден
    /// только после completion-хэндлера, поэтому `finish()` (перед склейкой) дожидается всей
    /// группы, а не только текущего writer'а: стоп сразу после ротации иначе отдал бы `ffmpeg`
    /// ещё дописывающийся сегмент.
    private let pendingWrites = DispatchGroup()

    // Счётчик принятых writer'ом буферов: пишется с очереди дорожки, читается самодиагностикой с
    // другой — отсюда замок. Сигнал «данные реально легли в сегмент», а не просто «пришли» (Task 4).
    private let appendedLock = NSLock()
    private var appended = 0

    /// Сколько буферов writer реально принял в сегмент с начала записи.
    var appendedCount: Int {
        appendedLock.lock()
        defer { appendedLock.unlock() }
        return appended
    }

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
        guard input.append(sampleBuffer) else {
            log.error("Writer отверг буфер: \(String(describing: self.writer?.error), privacy: .public)")
            return
        }
        appendedLock.lock()
        appended += 1
        appendedLock.unlock()
    }

    /// Финализировать текущий сегмент (чистый стоп). После вызова writer сброшен.
    ///
    /// Ждём завершения **всех** запущенных финализаций (текущей и оставшихся от ротаций): сразу
    /// после этого вызова запускается склейка сегментов (`SegmentAssembler`), а файл валиден только
    /// когда отработал его completion-хэндлер. Иначе `ffmpeg` прочитал бы ещё дописывающийся
    /// сегмент — терялся бы хвост записи.
    func finish() {
        finalizeCurrent()
        // Ждём с потолком: `finish()` вызывается синхронно с очереди дорожки внутри `stop()`, и
        // зависший в AVFoundation `finishWriting` без таймаута заклинил бы стоп навсегда — UI
        // остался бы в «идёт запись» с кнопкой, которая больше ничего не делает (`isStopping`
        // не снимется). По таймауту идём дальше: недописанный сегмент отбракует проверка заголовка
        // (`Recovery.isValidSegment`), потеряв хвост, но не всю запись.
        if pendingWrites.wait(timeout: .now() + Self.finishTimeoutSeconds) == .timedOut {
            log.error("Финализация сегментов не уложилась в таймаут — продолжаем без неё")
        }
    }

    /// Потолок ожидания финализации сегментов на стопе, с. С запасом больше нормального флаша
    /// (доли секунды): срабатывать он должен только на реально зависшем writer'е.
    private static let finishTimeoutSeconds = 30.0

    /// Финализировать текущий сегмент и перейти к следующему индексу — для рестарта стрима
    /// watchdog'ом (Task 4). В отличие от `finish()`, двигает счётчик вперёд, чтобы после
    /// перезапуска новый стрим писал в новый файл, а уже закрытый сегмент **не перезаписывался**.
    /// Ждать флаша не нужно: запись продолжается, а склейка будет только на стопе/восстановлении.
    func finishAndAdvance() {
        guard writer != nil else { return }
        finalizeCurrent()
        segmentIndex += 1
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
        // Ротация на горячем пути записи: не блокируем очередь дорожки ожиданием флаша — сегмент
        // допишется в фоне, а следующий уже принимает буферы. Ожидание берёт на себя `finish()`.
        finalizeCurrent()
        segmentIndex += 1
        startSegment(at: pts, formatHint: formatHint)
    }

    /// Закрыть текущий сегмент и запустить его финализацию в фоне, зарегистрировав её в
    /// `pendingWrites` — чтобы `finish()` перед склейкой мог дождаться всех.
    private func finalizeCurrent() {
        guard let writer, let input else { return }
        self.writer = nil
        self.input = nil
        self.segmentStart = .invalid
        input.markAsFinished()
        // completion-хэндлер приходит на внутренней очереди AVFoundation, а не на нашей очереди
        // дорожки, поэтому ожидание группы в `finish()` не деэдлочит.
        pendingWrites.enter()
        writer.finishWriting { [pendingWrites] in pendingWrites.leave() }
        onSegmentFinalized?()
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
