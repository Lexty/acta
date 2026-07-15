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
final class AudioRecorder: NSObject, SCStreamDelegate, SCStreamOutput {
    /// Ошибки старта записи для самодиагностики (Task 4).
    enum RecorderError: Error {
        case noDisplay
        case notAuthorized
    }

    private let log = Logger(subsystem: AppInfo.bundleID, category: "AudioRecorder")

    private let systemWriter: SegmentWriter
    private let micWriter: SegmentWriter

    // Раздельные сериализованные очереди на дорожку: делегат SegmentWriter'а не требует
    // внешней синхронизации, если его дёргает одна очередь.
    private let systemQueue = DispatchQueue(label: "dev.personal.acta.audio.system")
    private let micQueue = DispatchQueue(label: "dev.personal.acta.audio.mic")
    private let screenQueue = DispatchQueue(label: "dev.personal.acta.audio.screen")

    private var stream: SCStream?

    /// - Parameter directory: папка записи; сегменты пишутся в её подкаталоги `system/` и `mic/`.
    init(directory: URL, segmentSeconds: Double = Double(SegmentLayout.defaultSegmentSeconds)) {
        self.systemWriter = SegmentWriter(
            directory: directory.appendingPathComponent(SegmentLayout.systemDirName),
            segmentSeconds: segmentSeconds
        )
        self.micWriter = SegmentWriter(
            directory: directory.appendingPathComponent(SegmentLayout.micDirName),
            segmentSeconds: segmentSeconds
        )
        super.init()
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

    /// Запустить захват. Бросает, если нет доступного дисплея или прав.
    func start() async throws {
        guard Permissions.hasScreenRecording else { throw RecorderError.notAuthorized }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try await stream.startCapture()
        self.stream = stream
        log.info("Захват запущен")
    }

    /// Остановить захват и финализировать текущие сегменты обеих дорожек.
    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        systemQueue.sync { systemWriter.finish() }
        micQueue.sync { micWriter.finish() }
        log.info("Захват остановлен")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .audio:
            systemWriter.append(sampleBuffer)
        case .microphone:
            micWriter.append(sampleBuffer)
        default:
            break // .screen и прочее — игнор
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Стрим остановлен с ошибкой: \(error.localizedDescription, privacy: .public)")
    }
}
