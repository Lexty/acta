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
        case .noData:
            return "Запись не идёт: звук не поступает. Проверьте аудиоустройство и источник звука."
        }
    }
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
        /// Сколько буферов пришло за окно наблюдения.
        public var bufferCount: Int
        /// Насколько вырос размер текущего сегмента за окно наблюдения, байт.
        public var segmentBytesDelta: Int

        public init(hasScreenRecording: Bool, hasMicrophone: Bool, streamStarted: Bool,
                    bufferCount: Int, segmentBytesDelta: Int) {
            self.hasScreenRecording = hasScreenRecording
            self.hasMicrophone = hasMicrophone
            self.streamStarted = streamStarted
            self.bufferCount = bufferCount
            self.segmentBytesDelta = segmentBytesDelta
        }
    }

    /// Реально ли идут данные: пришёл хотя бы один буфер **или** вырос размер текущего сегмента.
    /// Основной сигнал самодиагностики и watchdog'а.
    public static func isDataFlowing(bufferCount: Int, segmentBytesDelta: Int) -> Bool {
        bufferCount > 0 || segmentBytesDelta > 0
    }

    /// Определить причину «немой» записи по снимку, либо `nil`, если данные идут.
    ///
    /// Порядок важен: сперва самый частый и легко лечимый случай (нет права на запись экрана →
    /// без него стрим вообще не поднимется), затем не поднявшийся стрим, затем нет микрофона и,
    /// наконец, «стрим есть, но тишина» (нет девайса).
    public static func diagnose(_ snapshot: Snapshot) -> StartupFailure? {
        if isDataFlowing(bufferCount: snapshot.bufferCount, segmentBytesDelta: snapshot.segmentBytesDelta) {
            return nil
        }
        if !snapshot.hasScreenRecording { return .noScreenRecordingPermission }
        if !snapshot.streamStarted { return .streamNotStarted }
        if !snapshot.hasMicrophone { return .noMicrophonePermission }
        return .noData
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
        case .streamNotStarted, .noData:
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
