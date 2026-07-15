import AVFoundation
import ActaKit
import os
@preconcurrency import ScreenCaptureKit

/// Захват звука встречи одним `SCStream`: системный звук (голоса собеседников) + микрофон.
///
/// Буферы приходят в делегат с разными типами и форматами (`SCStreamOutputType.audio` /
/// `.microphone`), поэтому разводятся в **два раздельных** `SegmentWriter` (`system/`, `mic/`) —
/// писать их в один контейнер нельзя (см. скилл `screencapturekit-audio`). Кадры `.screen`
/// игнорируются: видео не нужно, но `SCContentFilter` обязателен даже для audio-only.
///
/// `captureMicrophone` доступен с macOS 15, поэтому весь рекордер помечен соответственно.
@available(macOS 15.0, *)
final class AudioRecorder: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let log = Logger(subsystem: AppInfo.bundleID, category: "AudioRecorder")

    /// Папка записи — в её подкаталогах лежат сегменты обеих дорожек.
    private let directory: URL

    private let systemWriter: SegmentWriter
    private let micWriter: SegmentWriter

    // Раздельные сериализованные очереди на дорожку: делегат SegmentWriter'а не требует
    // внешней синхронизации, если его дёргает одна очередь.
    private let systemQueue = DispatchQueue(label: "dev.personal.acta.audio.system")
    private let micQueue = DispatchQueue(label: "dev.personal.acta.audio.mic")
    private let screenQueue = DispatchQueue(label: "dev.personal.acta.audio.screen")

    // Текущий стрим под замком: его ставит `startStream()` и снимают `stop()`/`restart()` (пул
    // Swift concurrency), а делегат `didStopWithError` — со своей очереди ScreenCaptureKit; читает
    // же его самодиагностика с третьей. Без замка это гонка за ссылкой: параллельный релиз старого
    // стрима и запись нового рвут ретейн-счётчик, а несинхронизированное чтение в `===`-сверке
    // может увидеть устаревшее значение и обнулить уже перезапущенный стрим.
    private let streamLock = NSLock()
    private var currentStream: SCStream?

    private var activeStream: SCStream? {
        get { streamLock.lock(); defer { streamLock.unlock() }; return currentStream }
        set { streamLock.lock(); currentStream = newValue; streamLock.unlock() }
    }

    /// Снять стрим, только если он всё ещё тот же самый — сверка и обнуление под одним замком,
    /// иначе между ними мог бы влезть `restart()` со своим новым стримом.
    private func clearStream(ifIdentical stream: SCStream) {
        streamLock.lock()
        if currentStream === stream { currentStream = nil }
        streamLock.unlock()
    }

    // Счётчики пришедших буферов по дорожкам под замком: делегат дёргают разные очереди
    // (`systemQueue`/`micQueue`), а читает самодиагностика/watchdog с ещё одной. Считаем дорожки
    // раздельно, чтобы поток системного звука не маскировал мёртвую дорожку микрофона (Task 4).
    private let bufferCountLock = NSLock()
    private var receivedSystemBuffers = 0
    private var receivedMicBuffers = 0

    /// Сколько аудио-буферов пришло от системы с момента старта, по дорожкам.
    var receivedBufferCounts: (system: Int, mic: Int) {
        bufferCountLock.lock()
        defer { bufferCountLock.unlock() }
        return (receivedSystemBuffers, receivedMicBuffers)
    }

    /// Сколько буферов пришло от системы с момента старта (обе дорожки).
    var receivedBufferCount: Int {
        let counts = receivedBufferCounts
        return counts.system + counts.mic
    }

    /// Сколько буферов writer'ы реально приняли в сегменты, по дорожкам. В отличие от
    /// `receivedBufferCounts` подтверждает, что данные дошли до файла, а не только до делегата.
    var writtenBufferCounts: (system: Int, mic: Int) {
        (systemWriter.appendedCount, micWriter.appendedCount)
    }

    /// Сколько буферов реально записано обеими дорожками — основной сигнал «запись идёт».
    var writtenBufferCount: Int {
        let counts = writtenBufferCounts
        return counts.system + counts.mic
    }

    /// Суммарный размер сегментов обеих дорожек на диске, байт. Второй (независимый от writer'а)
    /// сигнал для самодиагностики: файлы растут → данные действительно ложатся на диск.
    var segmentBytesOnDisk: Int {
        [SegmentLayout.systemDirName, SegmentLayout.micDirName]
            .map { Self.directorySize(directory.appendingPathComponent($0)) }
            .reduce(0, +)
    }

    private static func directorySize(_ url: URL) -> Int {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
        return names.reduce(0) { total, name in
            let attrs = try? manager.attributesOfItem(atPath: url.appendingPathComponent(name).path)
            return total + ((attrs?[.size] as? Int) ?? 0)
        }
    }

    /// Поднят ли сейчас `SCStream` (для снимка самодиагностики).
    var isStreaming: Bool { activeStream != nil }

    // Закрытые сегменты по дорожкам под замком: writer'ы дёргают колбэк со своих очередей
    // (`systemQueue`/`micQueue`), а читает счётчик `RecordingSession` с третьей. Арифметика — в
    // чистом `SegmentProgress` (ActaKit), здесь только сериализация.
    private let progressLock = NSLock()
    private var progress = SegmentProgress()
    private var onSegmentCountChange: (@Sendable (Int) -> Void)?

    /// Подписаться на изменение числа закрытых сегментов — `session.json` обновляется по этому
    /// сигналу (Task 8.2). Подписчик вызывается с очереди дорожки: блокировать её нельзя.
    /// Ставить подписку нужно до `start()`.
    func setSegmentCountObserver(_ observer: @escaping @Sendable (Int) -> Void) {
        progressLock.lock()
        onSegmentCountChange = observer
        progressLock.unlock()
    }

    /// Учесть закрытый сегмент дорожки и, если общий счётчик сдвинулся, сообщить подписчику.
    private func countFinalizedSegment(track: SegmentProgress.Track) {
        progressLock.lock()
        let changed = progress.recordFinalizedSegment(track: track)
        let count = progress.segmentCount
        let observer = onSegmentCountChange
        progressLock.unlock()
        guard changed else { return }
        observer?(count)
    }

    /// - Parameter directory: папка записи; сегменты пишутся в её подкаталоги `system/` и `mic/`.
    init(directory: URL, segmentSeconds: Double = Double(SegmentLayout.defaultSegmentSeconds)) {
        self.directory = directory
        self.systemWriter = SegmentWriter(
            directory: directory.appendingPathComponent(SegmentLayout.systemDirName),
            segmentSeconds: segmentSeconds
        )
        self.micWriter = SegmentWriter(
            directory: directory.appendingPathComponent(SegmentLayout.micDirName),
            segmentSeconds: segmentSeconds
        )
        super.init()
        systemWriter.onSegmentFinalized = { [weak self] in self?.countFinalizedSegment(track: .system) }
        micWriter.onSegmentFinalized = { [weak self] in self?.countFinalizedSegment(track: .mic) }
    }

    /// Собрать конфигурацию стрима. Вынесено, чтобы держать «магию» захвата в одном месте.
    private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Минимальный видео-конфиг: кадры не используем, но фильтр дисплея обязателен.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return config
    }

    /// Запустить захват. Бросает `StartupFailure` с готовым текстом для меню-бара: причина старта
    /// без записи — это то, что пользователь должен увидеть, а не «error 1» из `localizedDescription`.
    func start() async throws {
        try await requestPermissionsIfNeeded()
        do {
            try await startStream()
        } catch let failure as StartupFailure {
            throw failure
        } catch {
            // Сырые ошибки ScreenCaptureKit наружу не выпускаем: без `.streamNotStarted` вызывающий
            // не отличит «стрим не поднялся» (лечится рестартом) от прочих сбоев, и самолечение
            // (`SelfCheck`) не отработает свои попытки (Task 4).
            log.error("Стрим не поднялся: \(error.localizedDescription, privacy: .public)")
            throw StartupFailure.streamNotStarted
        }
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw StartupFailure.streamNotStarted }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try await stream.startCapture()
        activeStream = stream
        log.info("Захват запущен")
    }

    /// Показать системные диалоги TCC, если права ещё не выданы, и убедиться, что после этого они
    /// есть. Без явного запроса первый запуск молча упирался бы в отказ: `SCStream` без права на
    /// запись экрана не поднимется, а без микрофона запишется только половина встречи.
    ///
    /// `CGRequestScreenCaptureAccess` при первом вызове показывает диалог, но право применяется
    /// только к следующему запуску процесса — поэтому здесь всё равно завершаемся ошибкой с
    /// подсказкой «выдайте право и перезапустите Acta».
    private func requestPermissionsIfNeeded() async throws {
        if !Permissions.hasScreenRecording {
            Permissions.requestScreenRecording()
            guard Permissions.hasScreenRecording else {
                log.error("Нет права Screen Recording — старт отклонён")
                throw StartupFailure.noScreenRecordingPermission
            }
        }
        if Permissions.microphoneStatus == .notDetermined {
            _ = await Permissions.requestMicrophone()
        }
        guard Permissions.hasMicrophone else {
            log.error("Нет права Microphone — старт отклонён")
            throw StartupFailure.noMicrophonePermission
        }
    }

    /// Перезапустить стрим, **сохранив уже записанные сегменты** — для самолечения (`SelfCheck`)
    /// и watchdog'а. Текущие сегменты финализируются и остаются валидными, счётчики дорожек
    /// сдвигаются вперёд, поднимается новый `SCStream`.
    func restart() async throws {
        if let stream = activeStream {
            try? await stream.stopCapture()
        }
        activeStream = nil
        systemQueue.sync { systemWriter.finishAndAdvance() }
        micQueue.sync { micWriter.finishAndAdvance() }
        log.info("Перезапуск стрима")
        try await start()
    }

    /// Остановить захват и финализировать текущие сегменты обеих дорожек.
    func stop() async {
        if let stream = activeStream {
            try? await stream.stopCapture()
        }
        activeStream = nil
        systemQueue.sync { systemWriter.finish() }
        micQueue.sync { micWriter.finish() }
        log.info("Захват остановлен")
    }

    /// Число финализированных сегментов каждой дорожки (для `session.json`).
    func finalizedSegmentCounts() -> (system: Int, mic: Int) {
        progressLock.lock()
        defer { progressLock.unlock() }
        return (progress.system, progress.mic)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .audio:
            countBuffer(system: true)
            systemWriter.append(sampleBuffer)
        case .microphone:
            countBuffer(system: false)
            micWriter.append(sampleBuffer)
        default:
            break // .screen и прочее — игнор
        }
    }

    private func countBuffer(system: Bool) {
        bufferCountLock.lock()
        if system {
            receivedSystemBuffers += 1
        } else {
            receivedMicBuffers += 1
        }
        bufferCountLock.unlock()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Стрим остановлен с ошибкой: \(error.localizedDescription, privacy: .public)")
        // Стрим мёртв — снять его с себя, иначе `isStreaming` продолжит показывать самодиагностике
        // поднятый стрим, и упавший захват она объяснит пользователю неисправным аудиоустройством
        // вместо реальной причины. Сверяем тождество: за время доставки ошибки `restart()` мог уже
        // поставить новый стрим, и обнулить его тут значило бы соврать в обратную сторону.
        clearStream(ifIdentical: stream)
    }
}
