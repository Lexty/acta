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
    private let store: MeetingStore

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

    init(store: MeetingStore = MeetingStore()) {
        self.store = store
    }

    /// Идёт ли запись прямо сейчас.
    var isRecording: Bool { phase == .recording }

    /// Форматированное прошедшее время `HH:MM:SS` для таймера в UI.
    var elapsedString: String { MeetingInfo.formatDuration(seconds: elapsedSeconds) }

    // MARK: - Жизненный цикл приложения

    /// Вызывать один раз при появлении меню: восстановить прерванные записи, запросить право на
    /// уведомления, подсказать источник и обновить список.
    func onAppear() {
        Notifier.requestAuthorization()
        runRecovery()
        if title.isEmpty {
            title = SourceDetector.detectedSource().map {
                MeetingSource.suggestedTitle(source: $0, date: Date())
            } ?? ""
        }
        refresh()
    }

    /// Просканировать архив и восстановить прерванные краш/рестартом записи (см. `RecoveryManager`).
    private func runRecovery() {
        let recovered = RecoveryManager(archiveRoot: store.archiveRoot).recoverInterruptedSessions()
        guard !recovered.isEmpty else { return }
        recoveredBanner = recovered.count == 1
            ? "Восстановлена 1 прерванная запись."
            : "Восстановлено прерванных записей: \(recovered.count)."
        log.info("Восстановлено записей: \(recovered.count)")
        Notifier.notify(title: "Записи восстановлены",
                        body: "После сбоя автоматически восстановлено: \(recovered.count).")
    }

    /// Обновить список сохранённых записей.
    func refresh() {
        recordings = store.listRecordings()
    }

    // MARK: - Старт/стоп

    /// Начать запись. Заголовок берётся из поля, а если оно пусто — из авто-подсказки.
    func start() {
        guard phase != .recording else { return }
        recoveredBanner = ""
        errorMessage = ""
        let source = SourceDetector.detectedSource() ?? ""
        let finalTitle = title.isEmpty
            ? MeetingSource.suggestedTitle(source: source.isEmpty ? nil : source, date: Date())
            : title
        Task { await performStart(title: finalTitle, source: source) }
    }

    private func performStart(title: String, source: String) async {
        do {
            let directory = try store.createMeetingDirectory(title: title)
            let startedAt = Date()
            let session = RecordingSession(directory: directory)
            // Пишем предварительный info.md (recording): если процесс убьют, у папки уже есть
            // метаданные; на чистом стопе перезапишем со статусом done и длительностью.
            try? store.writeInfo(
                MeetingInfo(title: title, date: startedAt, source: source,
                            durationSeconds: 0, status: .recording),
                to: directory)

            try await session.start()

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
            log.error("Старт отклонён самодиагностикой: \(failure.userMessage, privacy: .public)")
        } catch {
            phase = .error
            errorMessage = "Не удалось начать запись: \(error.localizedDescription)"
            session = nil
            log.error("Старт не удался: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Остановить запись: финализировать сегменты, обновить `info.md`, уведомить, обновить список.
    func stop() {
        guard phase == .recording, let session, let directory = currentDirectory,
              let startedAt else { return }
        Task { await performStop(session: session, directory: directory, startedAt: startedAt) }
    }

    private func performStop(session: RecordingSession, directory: URL, startedAt: Date) async {
        stopTimer()
        await session.stop()
        let duration = max(0, Int(Date().timeIntervalSince(startedAt)))
        try? store.writeInfo(
            MeetingInfo(title: currentTitle, date: startedAt, source: currentSource,
                        durationSeconds: duration, status: .done),
            to: directory)
        Notifier.notify(title: "Запись сохранена", body: currentTitle)
        log.info("Запись остановлена и сохранена")

        self.session = nil
        currentDirectory = nil
        self.startedAt = nil
        phase = .idle
        elapsedSeconds = 0
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
