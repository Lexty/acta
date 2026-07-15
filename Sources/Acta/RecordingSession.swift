import ActaKit
import Foundation
import os

/// Жизненный цикл одной записи: создать папку + `session.json` (`recording`), гонять захват через
/// `AudioRecorder`, на чистом стопе финализировать (`done`) и склеить сегменты в итоговые файлы.
///
/// Разделяет ответственность с `AudioRecorder` (тот знает только про `SCStream` и сегменты):
/// здесь — маркер сессии и сборка, то есть отказоустойчивая часть. UI-обвязка (старт/стоп из
/// меню-бара) появится в Task 6 и будет дёргать эти методы.
///
/// `@unchecked Sendable`: все методы дёргает `RecordingController` с главного актора (сериализовано),
/// а `AudioRecorder`/`SelfCheck` внутри сами управляют своей потокобезопасностью. Это позволяет
/// вызывать `async`-методы сессии из main-actor без предупреждений о гонках.
@available(macOS 15.0, *)
final class RecordingSession: @unchecked Sendable {
    /// Папка записи.
    let directory: URL

    private let log = Logger(subsystem: AppInfo.bundleID, category: "RecordingSession")
    private let segmentSeconds: Int
    private let recorder: AudioRecorder
    private let selfCheck: SelfCheck
    private let store = SessionManifestStore()
    private let assembler = SegmentAssembler()
    private var watchdogTask: Task<Void, Never>?

    init(directory: URL, segmentSeconds: Int = SegmentLayout.defaultSegmentSeconds) {
        self.directory = directory
        self.segmentSeconds = segmentSeconds
        let recorder = AudioRecorder(directory: directory, segmentSeconds: Double(segmentSeconds))
        self.recorder = recorder
        self.selfCheck = SelfCheck(recorder: recorder)
    }

    /// Старт: создать папку, записать `session.json` (`recording`), запустить захват и
    /// самодиагностику. Если данные реально не пошли — стоп и бросок понятной ошибки: «немого»
    /// recording-статуса не показываем (Task 4).
    func start(startedAt: Date = Date()) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = SessionManifest(status: .recording, startedAt: startedAt,
                                       segmentSeconds: segmentSeconds, segmentCount: 0)
        try store.write(manifest, to: directory)
        try await recorder.start()

        if let failure = await selfCheck.verifyStartAndHeal() {
            log.error("Старт не подтверждён самодиагностикой: \(failure.userMessage, privacy: .public)")
            await recorder.stop()
            throw failure
        }

        watchdogTask = Task { [selfCheck] in
            await selfCheck.runWatchdog()
        }
        log.info("Сессия записи начата: \(self.directory.lastPathComponent, privacy: .public)")
    }

    /// Чистый стоп: остановить захват, склеить сегменты, пометить маркер `done`.
    ///
    /// - Parameter deleteSegments: удалять ли каталоги сегментов после успешной склейки.
    @discardableResult
    func stop(deleteSegments: Bool = true) async -> SegmentAssembler.Result? {
        watchdogTask?.cancel()
        watchdogTask = nil
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
