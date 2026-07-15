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
    private let settings: RecordingSettings
    private let segmentSeconds: Int
    private let recorder: AudioRecorder
    private let selfCheck: SelfCheck
    private let store = SessionManifestStore()
    private var watchdogTask: Task<Void, Never>?

    /// Обновления `segment_count` идут сюда с очередей обеих дорожек: своя серийная очередь
    /// сериализует read-modify-write маркера и уводит дисковую запись с горячего пути аудио.
    private let manifestQueue = DispatchQueue(label: "dev.personal.acta.manifest")
    /// Последний записанный счётчик (только с `manifestQueue`).
    private var lastWrittenSegmentCount = 0

    init(directory: URL, settings: RecordingSettings = .default) {
        self.directory = directory
        let settings = settings.normalized()
        self.settings = settings
        self.segmentSeconds = settings.segmentSeconds
        let recorder = AudioRecorder(directory: directory, segmentSeconds: Double(settings.segmentSeconds))
        self.recorder = recorder
        self.selfCheck = SelfCheck(recorder: recorder)
    }

    /// Старт: создать папку, записать `session.json` (`recording`), запустить захват и
    /// самодиагностику. Если данные реально не пошли — стоп и бросок понятной ошибки: «немого»
    /// recording-статуса не показываем (Task 4).
    /// - Parameter onStall: вызывается, если watchdog исчерпал попытки рестарта во время записи
    ///   (поток буферов пропал безвозвратно). Контроллер обязан показать ошибку и остановить
    ///   запись — «немой» recording-статус недопустим. Вызывается не на главном акторе.
    func start(startedAt: Date = Date(),
               onStall: @escaping @Sendable (StartupFailure) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = SessionManifest(status: .recording, startedAt: startedAt,
                                       segmentSeconds: segmentSeconds, segmentCount: 0)
        try store.write(manifest, to: directory)
        recorder.setSegmentCountObserver { [weak self] count in
            self?.manifestQueue.async { self?.persistSegmentCount(count) }
        }
        do {
            try await recorder.start()
        } catch StartupFailure.streamNotStarted {
            // Стрим не поднялся — старт не срываем: самодиагностика ниже увидит
            // `streamStarted == false` и отработает те же 2–3 попытки рестарта, что и для
            // вставшего стрима (Task 4). Прочие причины (нет прав) рестартом не лечатся и летят выше.
            log.error("Стрим не поднялся на старте — отдаём самодиагностике на рестарт")
        }

        if let failure = await selfCheck.verifyStartAndHeal() {
            log.error("Старт не подтверждён самодиагностикой: \(failure.userMessage, privacy: .public)")
            await recorder.stop()
            throw failure
        }

        watchdogTask = Task { [selfCheck] in
            await selfCheck.runWatchdog(onStall: onStall)
        }
        log.info("Сессия записи начата: \(self.directory.lastPathComponent, privacy: .public)")
    }

    /// Чистый стоп: остановить захват, склеить сегменты (по выбору дорожек из настроек), пометить
    /// маркер `done`. Удаление сегментов после склейки — тоже из настроек (`deleteSegmentsAfterAssembly`).
    @discardableResult
    func stop() async -> SegmentAssembler.Result? {
        // Дождаться завершения watchdog'а до остановки рекордера: иначе его `restart()` мог бы
        // отработать уже после `recorder.stop()` и поднять новый `SCStream`, который писал бы
        // сегменты после склейки (гонка за `stream`). Отмена + await сериализует переходы.
        watchdogTask?.cancel()
        await watchdogTask?.value
        watchdogTask = nil
        await recorder.stop()
        // Дождаться уже поставленных в очередь обновлений счётчика: иначе запоздавшее из них легло
        // бы поверх финального маркера, вернув `done` обратно в `recording`.
        manifestQueue.sync {}

        let counts = recorder.finalizedSegmentCounts()
        var manifest = store.read(from: directory)
            ?? SessionManifest(status: .recording, startedAt: Date(),
                               segmentSeconds: segmentSeconds, segmentCount: 0)
        manifest.segmentCount = max(counts.system, counts.mic)

        var result: SegmentAssembler.Result?
        do {
            // Склейка синхронно ждёт `ffmpeg` (`waitUntilExit`) — на часовой встрече это десятки
            // секунд. Из `async`-метода это заняло бы поток кооперативного пула (он размером с
            // число ядер) на всё это время, поэтому уводим блокирующую работу с него — так же, как
            // это уже делает восстановление в `RecordingController.runRecovery`.
            let directory = directory
            let settings = settings
            result = try await Task.detached(priority: .utility) {
                try SegmentAssembler().assemble(in: directory,
                                                deleteSegments: settings.deleteSegmentsAfterAssembly,
                                                tracks: settings.trackSelection)
            }.value
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

    /// Записать в `session.json` число закрытых сегментов. Вызывается только с `manifestQueue`.
    ///
    /// Счётчик информационный: восстановление читает файловую систему и на него не смотрит (Task
    /// 8.2). Но держать его вечным нулём, как было до сих пор, нельзя — при взгляде в маркер он
    /// утверждал бы, что записывать нечего, при дюжине сегментов рядом на диске.
    ///
    /// Счётчик только растёт, и статус маркера не трогаем: обновление могло разминуться со стопом,
    /// и вернуть `done` в `recording` значило бы отправить готовую запись на восстановление.
    private func persistSegmentCount(_ count: Int) {
        guard count > lastWrittenSegmentCount else { return }
        lastWrittenSegmentCount = count
        guard var manifest = store.read(from: directory), manifest.status == .recording else { return }
        manifest.segmentCount = count
        do {
            try store.write(manifest, to: directory)
        } catch {
            // Не фатально: сегменты на диске целы, а восстановление и так идёт от FS.
            log.error("Не удалось обновить segment_count: \(error.localizedDescription, privacy: .public)")
        }
    }
}
