import Foundation

/// Причина «немой» записи: приложение думает, что пишет, а данные на диск не идут.
///
/// Ключевое требование Acta — **никогда** не показывать «recording», если данные не пишутся
/// (см. скилл `crash-safe-recording`, SPEC §7). Тип и его текст держим в `ActaKit` как чистую
/// логику: причину определяет `SelfDiagnosis.diagnose`, а runtime (`SelfCheck`) лишь собирает
/// снимок состояния и показывает `userMessage` в меню-баре.
public enum StartupFailure: Error, Equatable, Sendable {
    /// Нет TCC-права на запись экрана (нужно даже для audio-only захвата через `SCStream`).
    case noScreenRecordingPermission
    /// Нет TCC-права на микрофон.
    case noMicrophonePermission
    /// `SCStream` не поднялся / делегат сообщил об ошибке.
    case streamNotStarted
    /// Буферы от системы идут, но на диск не попадают (writer не создался / нет места / нет прав).
    case diskWriteFailed
    /// Стрим поднялся, но буферы не приходят (нет аудио-девайса / тишина на входе устройства).
    case noData

    /// Понятный пользователю текст с путём к исправлению — для показа в меню-баре (Task 6).
    public var userMessage: String {
        switch self {
        case .noScreenRecordingPermission:
            return "Нет доступа к записи экрана. Выдайте право в Системные настройки → "
                + "Конфиденциальность и безопасность → Запись экрана и перезапустите Acta."
        case .noMicrophonePermission:
            return "Нет доступа к микрофону. Выдайте право в Системные настройки → "
                + "Конфиденциальность и безопасность → Микрофон."
        case .streamNotStarted:
            return "Не удалось запустить захват звука. Попробуйте перезапустить запись."
        case .diskWriteFailed:
            return "Звук идёт, но не записывается на диск. Проверьте свободное место и доступ "
                + "к папке архива в настройках."
        case .noData:
            return "Запись не идёт: звук не поступает. Проверьте аудиоустройство и источник звука."
        }
    }
}

/// Дорожка записи. Считаем и диагностируем дорожки раздельно: живой системный звук не должен
/// маскировать мёртвый микрофон (и наоборот) — это половина встречи.
public enum Track: String, Equatable, Sendable, CaseIterable {
    /// Системный звук — голоса собеседников.
    case system
    /// Микрофон — голос пользователя.
    case mic

    /// Название для логов и сообщений.
    public var title: String {
        switch self {
        case .system: return "системный звук"
        case .mic: return "микрофон"
        }
    }
}

/// Поток одной дорожки за окно наблюдения: сколько буферов пришло от системы и сколько из них
/// writer реально принял в сегмент.
public struct TrackFlow: Equatable, Sendable {
    /// Буферов пришло от системы.
    public var received: Int
    /// Буферов writer принял в сегмент.
    public var written: Int

    public init(received: Int = 0, written: Int = 0) {
        self.received = received
        self.written = written
    }

    /// Запись дорожки сломана: буферы идут, а writer не принял **ни одного**.
    ///
    /// Молчащий источник (`received == 0`) сюда намеренно не попадает: отличить паузу в разговоре
    /// или отсутствующее устройство от поломки нечем, а глушить запись из-за тишины нельзя. Зато
    /// «буферы есть, записи нет» однозначен — сломан writer дорожки (нет места, нет доступа к папке).
    public var isWriteBroken: Bool { received > 0 && written == 0 }
}

/// Поток обеих дорожек на один момент — снимок, по которому watchdog судит о здоровье записи.
public struct TrackFlows: Equatable, Sendable {
    public var system: TrackFlow
    public var mic: TrackFlow

    public init(system: TrackFlow = TrackFlow(), mic: TrackFlow = TrackFlow()) {
        self.system = system
        self.mic = mic
    }

    /// Записано буферов обеими дорожками суммарно.
    public var written: Int { system.written + mic.written }
}

/// Действие самолечения, выбранное по причине провала. Runtime исполняет его (перезапрос права,
/// рестарт стрима, показ ошибки); выбор действия — чистая логика (`SelfDiagnosis.action`).
public enum HealingAction: Equatable, Sendable {
    /// Запросить/подсказать право на запись экрана.
    case requestScreenRecording
    /// Запросить/подсказать право на микрофон.
    case requestMicrophone
    /// Перезапустить стрим (попытки ещё остались).
    case restartStream
    /// Попытки исчерпаны / лечение невозможно — показать понятную ошибку.
    case reportError(StartupFailure)
}

/// Чистая логика самодиагностики старта: по снимку состояния определить, идёт ли запись, и если
/// нет — назвать причину и выбрать действие. Держим отдельно от ScreenCaptureKit/таймеров, чтобы
/// покрыть юнит-тестами (`DiagnosticsTests`) на фейковом источнике.
public enum SelfDiagnosis {
    /// Снимок состояния записи для диагностики. Собирается runtime'ом из `Permissions` и рекордера.
    public struct Snapshot: Equatable, Sendable {
        /// Есть ли право Screen Recording.
        public var hasScreenRecording: Bool
        /// Есть ли право Microphone.
        public var hasMicrophone: Bool
        /// Поднялся ли `SCStream` (start не бросил, стрим живой).
        public var streamStarted: Bool
        /// Сколько буферов пришло от системы за окно наблюдения.
        public var bufferCount: Int
        /// Сколько буферов за окно наблюдения writer реально принял в сегмент. Отличается от
        /// `bufferCount`, когда звук идёт, а запись на диск сломана.
        public var writtenBufferCount: Int
        /// Насколько выросли сегменты на диске за окно наблюдения, байт.
        public var segmentBytesDelta: Int
        /// Поток дорожки системного звука за окно наблюдения.
        public var system: TrackFlow
        /// Поток дорожки микрофона за окно наблюдения.
        public var mic: TrackFlow

        public init(hasScreenRecording: Bool, hasMicrophone: Bool, streamStarted: Bool,
                    bufferCount: Int, writtenBufferCount: Int, segmentBytesDelta: Int,
                    system: TrackFlow = TrackFlow(), mic: TrackFlow = TrackFlow()) {
            self.hasScreenRecording = hasScreenRecording
            self.hasMicrophone = hasMicrophone
            self.streamStarted = streamStarted
            self.bufferCount = bufferCount
            self.writtenBufferCount = writtenBufferCount
            self.segmentBytesDelta = segmentBytesDelta
            self.system = system
            self.mic = mic
        }
    }

    /// Реально ли **пишутся** данные: writer принял хотя бы один буфер **или** сегменты выросли
    /// на диске. Основной сигнал самодиагностики и watchdog'а.
    ///
    /// Считаем именно записанное, а не пришедшее от системы: «буферы идут» ещё не значит «данные
    /// на диске», а показывать «recording» без данных на диске нельзя (SPEC §7).
    public static func isDataFlowing(writtenBufferCount: Int, segmentBytesDelta: Int) -> Bool {
        writtenBufferCount > 0 || segmentBytesDelta > 0
    }

    /// Дорожка, чья запись сломана, либо `nil`, если обе в порядке. Проверяется, даже когда данные
    /// в целом идут: без этого живая дорожка маскирует мёртвую и приложение показывает «recording»,
    /// записывая половину встречи.
    public static func brokenTrack(_ snapshot: Snapshot) -> Track? {
        if snapshot.system.isWriteBroken { return .system }
        if snapshot.mic.isWriteBroken { return .mic }
        return nil
    }

    /// Определить причину «немой» записи по снимку, либо `nil`, если данные идут.
    ///
    /// Порядок важен: сперва самый частый и легко лечимый случай (нет права на запись экрана →
    /// без него стрим вообще не поднимется), затем не поднявшийся стрим, затем нет микрофона;
    /// далее «звук идёт, но не пишется» (сломан writer) и, наконец, «стрим есть, но тишина».
    public static func diagnose(_ snapshot: Snapshot) -> StartupFailure? {
        if isDataFlowing(writtenBufferCount: snapshot.writtenBufferCount,
                         segmentBytesDelta: snapshot.segmentBytesDelta) {
            // Суммарно данные идут — но если у одной из дорожек буферы есть, а записи нет, писать
            // будем только половину встречи. Это тот же сломанный writer, лечится тем же рестартом.
            return brokenTrack(snapshot) == nil ? nil : .diskWriteFailed
        }
        if !snapshot.hasScreenRecording { return .noScreenRecordingPermission }
        if !snapshot.streamStarted { return .streamNotStarted }
        if !snapshot.hasMicrophone { return .noMicrophonePermission }
        if snapshot.bufferCount > 0 { return .diskWriteFailed }
        return .noData
    }

    /// Вылечил ли рестарт стрима запись — решение watchdog'а о возврате бюджета попыток.
    ///
    /// Бюджет возвращается, только если записанного стало больше **и** ни одна дорожка не осталась
    /// сломанной. Обе части обязательны:
    ///
    /// - Один агрегат (`written` двух дорожек) — и живая дорожка тянет счётчик вверх за мёртвую:
    ///   бюджет возвращался бы после каждого рестарта, попытки никогда бы не кончились, ошибка о
    ///   вставшей записи не показалась бы ни разу. Приложение крутило бы «идёт запись»,
    ///   пересоздавая стрим каждые несколько секунд и теряя половину встречи, — ровно то, ради чего
    ///   заведены watchdog'и на дорожку.
    /// - Одни дорожки — и наоборот: у мёртвого стрима буферы не идут вообще, обе дорожки выглядят
    ///   «молчащими», а молчание поломкой не считается (см. `trackHealed`), и рестарт сочли бы
    ///   успешным. Рост агрегата это исключает.
    public static func restartHealed(_ now: TrackFlows, since base: TrackFlows) -> Bool {
        now.written > base.written
            && trackHealed(now.system, since: base.system)
            && trackHealed(now.mic, since: base.mic)
    }

    /// Жива ли дорожка: writer снова принимает буферы — либо источник молчит, и писать нечего.
    ///
    /// Тишину поломкой не считаем (та же логика, что в `TrackWatchdog`/`TrackFlow.isWriteBroken`):
    /// иначе Mac без микрофона исчерпывал бы бюджет рестартов на ровном месте.
    public static func trackHealed(_ now: TrackFlow, since base: TrackFlow) -> Bool {
        now.written > base.written || now.received == base.received
    }

    /// Выбрать действие по причине с учётом оставшихся попыток рестарта.
    ///
    /// Проблемы прав лечатся запросом/подсказкой; не поднявшийся стрим и «тишину» пробуем
    /// перезапустить (2–3 раза), а когда попытки кончились — показываем понятную ошибку.
    public static func action(for failure: StartupFailure, restartAttemptsLeft: Int) -> HealingAction {
        switch failure {
        case .noScreenRecordingPermission:
            return .requestScreenRecording
        case .noMicrophonePermission:
            return .requestMicrophone
        case .streamNotStarted, .diskWriteFailed, .noData:
            // Рестарт пересоздаёт и стрим, и сегмент — лечит и вставший стрим, и разовый сбой записи.
            return restartAttemptsLeft > 0 ? .restartStream : .reportError(failure)
        }
    }
}

/// Watchdog потока буферов во время записи — **чистая логика** обнаружения «поток встал».
///
/// Runtime (`SelfCheck`) периодически скармливает сюда монотонное время и накопленный счётчик
/// буферов; watchdog помнит момент последнего роста счётчика и сигналит, если прогресса не было
/// дольше порога. Время передаётся снаружи, поэтому детектор детерминирован и тестируем.
public struct FlowWatchdog: Sendable, Equatable {
    /// Порог простоя, с: нет роста счётчика дольше — поток считается вставшим.
    public let stallThreshold: Double

    private var lastBufferCount: Int
    private var lastProgressTime: Double

    public init(stallThreshold: Double, startTime: Double, initialBufferCount: Int = 0) {
        self.stallThreshold = stallThreshold
        self.lastBufferCount = initialBufferCount
        self.lastProgressTime = startTime
    }

    /// Записать наблюдение. Возвращает `true`, если поток встал: счётчик буферов не рос дольше
    /// `stallThreshold` с момента последнего прогресса.
    public mutating func observe(bufferCount: Int, at time: Double) -> Bool {
        if bufferCount > lastBufferCount {
            lastBufferCount = bufferCount
            lastProgressTime = time
            return false
        }
        return (time - lastProgressTime) >= stallThreshold
    }
}

/// Watchdog **одной дорожки** — ловит то, что агрегатный `FlowWatchdog` пропускает по построению:
/// дорожка получает буферы, но не пишет их, а вторая дорожка жива и держит общий счётчик растущим.
/// Без этого мёртвый микрофон при живом системном звуке (или наоборот) не обнаруживается вообще.
///
/// Тишина простоем не считается: если буферы дорожки не приходят, писать нечего — окно наблюдения
/// просто сдвигается. Иначе пауза в разговоре роняла бы запись (см. `TrackFlow.isWriteBroken`).
public struct TrackWatchdog: Sendable, Equatable {
    /// Порог простоя, с: буферы идут, а записи нет дольше этого — дорожка считается вставшей.
    public let stallThreshold: Double

    private var lastFlow: TrackFlow
    private var lastProgressTime: Double

    public init(stallThreshold: Double, startTime: Double, initialFlow: TrackFlow = TrackFlow()) {
        self.stallThreshold = stallThreshold
        self.lastFlow = initialFlow
        self.lastProgressTime = startTime
    }

    /// Записать наблюдение (накопленные с начала записи счётчики дорожки). Возвращает `true`, если
    /// дорожка получает буферы, но не записала ни одного дольше `stallThreshold`.
    public mutating func observe(_ flow: TrackFlow, at time: Double) -> Bool {
        let wrote = flow.written > lastFlow.written
        let sourceIdle = flow.received <= lastFlow.received
        defer { lastFlow = flow }
        if wrote || sourceIdle {
            lastProgressTime = time
            return false
        }
        return (time - lastProgressTime) >= stallThreshold
    }
}
