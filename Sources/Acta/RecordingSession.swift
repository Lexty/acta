import ActaKit
import Foundation
import os

/// Жизненный цикл одной записи: создать папку + `session.json` (`recording`), гонять захват через
/// `AudioRecorder`, на чистом стопе финализировать (`done`) и склеить сегменты в итоговые файлы.
///
/// Разделяет ответственность с `AudioRecorder` (тот знает только про `SCStream` и сегменты):
/// здесь — маркер сессии и сборка, то есть отказоустойчивая часть. UI-обвязка (старт/стоп из
/// меню-бара) появится в Task 6 и будет дёргать эти методы.
@available(macOS 15.0, *)
final class RecordingSession {
    /// Папка записи.
    let directory: URL

    private let log = Logger(subsystem: AppInfo.bundleID, category: "RecordingSession")
    private let segmentSeconds: Int
    private let recorder: AudioRecorder
    private let store = SessionManifestStore()
    private let assembler = SegmentAssembler()

    init(directory: URL, segmentSeconds: Int = SegmentLayout.defaultSegmentSeconds) {
        self.directory = directory
        self.segmentSeconds = segmentSeconds
        self.recorder = AudioRecorder(directory: directory, segmentSeconds: Double(segmentSeconds))
    }

    /// Старт: создать папку, записать `session.json` (`recording`), запустить захват.
    func start(startedAt: Date = Date()) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = SessionManifest(status: .recording, startedAt: startedAt,
                                       segmentSeconds: segmentSeconds, segmentCount: 0)
        try store.write(manifest, to: directory)
        try await recorder.start()
        log.info("Сессия записи начата: \(self.directory.lastPathComponent, privacy: .public)")
    }

    /// Чистый стоп: остановить захват, склеить сегменты, пометить маркер `done`.
    ///
    /// - Parameter deleteSegments: удалять ли каталоги сегментов после успешной склейки.
    @discardableResult
    func stop(deleteSegments: Bool = true) async -> SegmentAssembler.Result? {
        await recorder.stop()

        let counts = recorder.finalizedSegmentCounts()
        var manifest = store.read(from: directory)
            ?? SessionManifest(status: .recording, startedAt: Date(),
                               segmentSeconds: segmentSeconds, segmentCount: 0)
        manifest.segmentCount = max(counts.system, counts.mic)

        var result: SegmentAssembler.Result?
        do {
            result = try assembler.assemble(in: directory, deleteSegments: deleteSegments)
            manifest.status = .done
        } catch {
            // Склейка не удалась (нет ffmpeg / нет сегментов). Оставляем маркер как есть, чтобы
            // восстановление на следующем старте попробовало снова — данные не теряем.
            log.error("Склейка при стопе не удалась: \(error.localizedDescription, privacy: .public)")
        }
        try? store.write(manifest, to: directory)
        log.info("Сессия записи остановлена: \(self.directory.lastPathComponent, privacy: .public)")
        return result
    }
}
