import ActaKit
import AppKit
import Foundation
import os

/// View-модель меню-бара: владеет жизненным циклом записи и состоянием для UI (Task 6).
///
/// Связывает уже готовые кирпичи — `RecordingSession` (отказоустойчивая запись + самодиагностика),
/// `MeetingStore` (папки/`info.md`/список) и `RecoveryManager` (восстановление на старте) — в одно
/// наблюдаемое состояние для SwiftUI. Вся тяжёлая логика уже покрыта тестами в `ActaKit`; здесь —
/// оркестрация и публикация состояния на главном потоке.
@available(macOS 15.0, *)
@MainActor
final class RecordingController: ObservableObject {
    /// Фаза записи для индикатора состояния.
    enum Phase: Equatable {
        case idle
        case recording
        case error
    }

    private let log = Logger(subsystem: AppInfo.bundleID, category: "RecordingController")
    private let settingsStore: SettingsStore

    /// Текущие настройки записи (редактируются в секции «Настройки», сохраняются при изменении).
    @Published var settings: RecordingSettings

    /// Текущая фаза (idle/recording/error).
    @Published private(set) var phase: Phase = .idle
    /// Понятный текст ошибки самодиагностики старта (пусто, если ошибки нет).
    @Published private(set) var errorMessage: String = ""
    /// Баннер восстановления после сбоя (пусто, если восстанавливать было нечего).
    @Published private(set) var recoveredBanner: String = ""
    /// Прошедшее время текущей записи, с.
    @Published private(set) var elapsedSeconds: Int = 0
    /// Заголовок встречи (редактируется в поле; пустой → берётся авто-подсказка).
    @Published var title: String = ""
    /// Список сохранённых записей (новые сверху).
    @Published private(set) var recordings: [MeetingStore.Recording] = []

    // Состояние активной сессии.
    private var session: RecordingSession?
    private var currentDirectory: URL?
    private var currentTitle: String = ""
    private var currentSource: String = ""
    private var startedAt: Date?
    private var timerTask: Task<Void, Never>?
    /// Идёт ли асинхронный старт прямо сейчас (до перехода в `.recording`). Защищает от двойного
    /// клика: `phase` становится `.recording` лишь в конце `performStart` (после ~2 с самопроверки),
    /// поэтому без этого флага второй клик поднял бы вторую сессию, а первая утекла бы.
    private var isStarting = false
    /// Идёт ли асинхронный стоп прямо сейчас. Симметрично `isStarting`: `phase` становится `.idle`
    /// лишь в конце `performStop` — после склейки, а она занимает секунды. Без флага второй клик
    /// (или watchdog, сработавший в этот момент) запустил бы вторую склейку той же папки: два
    /// `ffmpeg` писали бы одни и те же wav и list-файлы, вплоть до потери записи.
    private var isStopping = false
    /// Восстановление прерванных записей запускаем один раз за запуск приложения (из `onLaunch`).
    /// `RecoveryManager` считает любую папку со статусом `recording` прерванной — включая активную
    /// запись, склейку которой нельзя запускать на лету, поэтому старт ждёт эту задачу.
    private var recoveryTask: Task<Void, Never>?
    private var didRunRecovery = false

    /// Общий экземпляр: восстановление должно стартовать при запуске приложения (`AppDelegate`),
    /// а не при первом открытии меню, и то же состояние показывает `MenuContent`.
    static let shared = RecordingController()

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
    }

    /// Идёт ли запись прямо сейчас.
    var isRecording: Bool { phase == .recording }

    /// Хранилище записей для текущего пути архива из настроек. Читается на каждом обращении, чтобы
    /// смена пути в настройках подхватывалась без перезапуска (Task 7).
    private var store: MeetingStore {
        MeetingStore(archiveRoot: settingsStore.archiveRoot(for: settings))
    }

    /// Корень архива для текущих настроек (кнопка «Открыть архив» в UI).
    var archiveRoot: URL { settingsStore.archiveRoot(for: settings) }

    /// Сохранить настройки после редактирования в UI (нормализуются перед записью на диск).
    func saveSettings() {
        settings = settings.normalized()
        settingsStore.save(settings)
    }

    /// Форматированное прошедшее время `HH:MM:SS` для таймера в UI.
    var elapsedString: String { MeetingInfo.formatDuration(seconds: elapsedSeconds) }

    // MARK: - Жизненный цикл приложения

    /// Вызывать один раз при запуске приложения (`AppDelegate`), до и независимо от открытия меню:
    /// SPEC §7 требует восстанавливать прерванные записи именно на старте. Меню-бар с
    /// `menuBarExtraStyle(.window)` создаёт контент только по клику, поэтому вешать восстановление
    /// на `onAppear` нельзя — после краха запись висела бы несклеенной, пока не откроют меню.
    func onLaunch() {
        Notifier.requestAuthorization()
        guard !didRunRecovery else { return }
        didRunRecovery = true
        recoveryTask = Task { [weak self] in await self?.runRecovery() }
    }

    /// Вызывать при появлении меню: запросить право на уведомления, подсказать источник и
    /// обновить список.
    func onAppear() {
        Notifier.requestAuthorization()
        if title.isEmpty {
            title = SourceDetector.detectedSource().map {
                MeetingSource.suggestedTitle(source: $0, date: Date())
            } ?? ""
        }
        refresh()
    }

    /// Просканировать архив и восстановить прерванные краш/рестартом записи (см. `RecoveryManager`).
    ///
    /// Склейка синхронно гоняет `ffmpeg` по всем прерванным папкам — для часовой встречи это
    /// десятки секунд. На главном акторе это заморозило бы меню целиком, поэтому работа уходит с
    /// него, а на главный возвращаются только баннер и уведомление.
    private func runRecovery() async {
        let root = store.archiveRoot
        let recovered = await Task.detached(priority: .utility) {
            RecoveryManager(archiveRoot: root).recoverInterruptedSessions()
        }.value
        guard !recovered.isEmpty else { return }
        recoveredBanner = recovered.count == 1
            ? "Восстановлена 1 прерванная запись."
            : "Восстановлено прерванных записей: \(recovered.count)."
        log.info("Восстановлено записей: \(recovered.count)")
        Notifier.notify(title: "Записи восстановлены",
                        body: "После сбоя автоматически восстановлено: \(recovered.count).")
        refresh()
    }

    /// Обновить список сохранённых записей.
    func refresh() {
        recordings = store.listRecordings()
    }

    // MARK: - Старт/стоп

    /// Начать запись. Заголовок берётся из поля, а если оно пусто — из авто-подсказки.
    func start() {
        guard phase != .recording, !isStarting, !isStopping else { return }
        isStarting = true
        recoveredBanner = ""
        errorMessage = ""
        let source = SourceDetector.detectedSource() ?? ""
        let finalTitle = title.isEmpty
            ? MeetingSource.suggestedTitle(source: source.isEmpty ? nil : source, date: Date())
            : title
        Task { await performStart(title: finalTitle, source: source) }
    }

    private func performStart(title: String, source: String) async {
        defer { isStarting = false }
        // Дождаться восстановления: оно считает прерванной любую папку со `status=recording` — а
        // новая запись создаёт ровно такую. Старт сразу после запуска приложения иначе попал бы
        // под склейку собственной, ещё пишущейся папки.
        await recoveryTask?.value
        var createdDirectory: URL?
        do {
            // Снимок настроек на момент старта: смена пути архива/длины сегмента подхватывается
            // именно новой записью (Task 7), а текущая идёт со своими параметрами до конца.
            let currentSettings = settings.normalized()
            let directory = try MeetingStore(archiveRoot: settingsStore.archiveRoot(for: currentSettings))
                .createMeetingDirectory(title: title)
            createdDirectory = directory
            let startedAt = Date()
            let session = RecordingSession(directory: directory, settings: currentSettings)
            // Пишем предварительный info.md (recording): если процесс убьют, у папки уже есть
            // метаданные; на чистом стопе перезапишем со статусом done и длительностью.
            try? store.writeInfo(
                MeetingInfo(title: title, date: startedAt, source: source,
                            durationSeconds: 0, status: .recording),
                to: directory)

            try await session.start(onStall: { [weak self] failure in
                Task { @MainActor in self?.handleFatalStall(failure) }
            })

            self.session = session
            currentDirectory = directory
            currentTitle = title
            currentSource = source
            self.startedAt = startedAt
            elapsedSeconds = 0
            phase = .recording
            startTimer()
            log.info("Запись начата")
        } catch let failure as StartupFailure {
            // Самодиагностика не подтвердила поток данных — показываем понятную ошибку, а не
            // «немой» recording (ключевое требование Acta). Рекордер уже остановлен в start().
            phase = .error
            errorMessage = failure.userMessage
            session = nil
            cleanupFailedStart(createdDirectory)
            log.error("Старт отклонён самодиагностикой: \(failure.userMessage, privacy: .public)")
        } catch {
            phase = .error
            errorMessage = "Не удалось начать запись: \(error.localizedDescription)"
            session = nil
            cleanupFailedStart(createdDirectory)
            log.error("Старт не удался: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Убрать папку неудавшегося старта. Данные не потекли (иначе самопроверка бы прошла), значит
    /// сегментов нет — а брошенная папка со статусом `recording` иначе застряла бы навсегда:
    /// восстановление на каждом запуске пыталось бы её склеить (нет сегментов → ошибка) и она
    /// маячила бы «не завершена» в списке.
    private func cleanupFailedStart(_ directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Watchdog исчерпал попытки рестарта во время записи — поток буферов пропал безвозвратно.
    /// Нельзя оставлять «идёт запись»: останавливаем сессию, склеиваем то, что успели записать,
    /// и показываем ошибку.
    private func handleFatalStall(_ failure: StartupFailure) {
        guard phase == .recording, !isStopping, let session, let directory = currentDirectory,
              let startedAt else { return }
        isStopping = true
        stopTimer()
        phase = .error
        errorMessage = failure.userMessage
        log.error("Watchdog: поток данных пропал — запись остановлена, показана ошибка")

        let title = currentTitle
        let source = currentSource
        self.session = nil
        currentDirectory = nil
        self.startedAt = nil
        elapsedSeconds = 0

        Task { [weak self] in
            let result = await session.stop()
            let duration = max(0, Int(Date().timeIntervalSince(startedAt)))
            await MainActor.run {
                guard let self else { return }
                self.isStopping = false
                // Склейка могла не удаться — тогда маркер остался `recording` и её повторит
                // восстановление. Ставить в `info.md` `done` в этом случае нельзя: файл — это
                // архивные метаданные, и они разошлись бы с реальностью.
                try? self.store.writeInfo(
                    MeetingInfo(title: title, date: startedAt, source: source,
                                durationSeconds: duration,
                                status: result == nil ? .recording : .done),
                    to: directory)
                self.refresh()
            }
        }
    }

    /// Остановить запись: финализировать сегменты, обновить `info.md`, уведомить, обновить список.
    func stop() {
        guard phase == .recording, !isStopping, let session, let directory = currentDirectory,
              let startedAt else { return }
        isStopping = true
        Task { await performStop(session: session, directory: directory, startedAt: startedAt) }
    }

    private func performStop(session: RecordingSession, directory: URL, startedAt: Date) async {
        defer { isStopping = false }
        stopTimer()
        let result = await session.stop()
        let duration = max(0, Int(Date().timeIntervalSince(startedAt)))
        let stoppedTitle = currentTitle

        self.session = nil
        currentDirectory = nil
        self.startedAt = nil
        elapsedSeconds = 0

        // Склейка не удалась (нет ffmpeg / ffmpeg упал): итоговых wav нет, маркер остался
        // `recording`, сегменты целы и их подхватит восстановление на следующем запуске. Сказать
        // «сохранена» тут — то же, что показывать «немой» recording: состояние не соответствует
        // тому, что реально лежит на диске.
        guard result != nil else {
            try? store.writeInfo(
                MeetingInfo(title: stoppedTitle, date: startedAt, source: currentSource,
                            durationSeconds: duration, status: .recording),
                to: directory)
            phase = .error
            errorMessage = SegmentAssembler.locateFFmpeg() == nil
                ? "Запись остановлена, но собрать итоговый файл нечем: не найден ffmpeg "
                    + "(установите его: brew install ffmpeg). Сегменты сохранены — их склеит "
                    + "восстановление при следующем запуске."
                : "Запись остановлена, но склейка не удалась. Сегменты сохранены — их склеит "
                    + "восстановление при следующем запуске."
            log.error("Запись остановлена, но склейка не удалась — оставляем сегменты восстановлению")
            refresh()
            return
        }

        try? store.writeInfo(
            MeetingInfo(title: stoppedTitle, date: startedAt, source: currentSource,
                        durationSeconds: duration, status: .done),
            to: directory)
        Notifier.notify(title: "Запись сохранена", body: stoppedTitle)
        log.info("Запись остановлена и сохранена")

        phase = .idle
        title = ""
        refresh()
    }

    // MARK: - Действия над записями

    /// Открыть папку записи в Finder.
    func openInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Сбросить баннер восстановления (после того как пользователь его увидел).
    func dismissRecoveredBanner() {
        recoveredBanner = ""
    }

    // MARK: - Таймер

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let startedAt = self.startedAt else { break }
                self.elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
