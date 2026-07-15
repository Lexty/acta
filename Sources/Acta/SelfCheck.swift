import ActaKit
import Foundation
import os

/// Самодиагностика старта и watchdog записи (см. скилл `crash-safe-recording`, SPEC §7).
///
/// Требование Acta: **никогда** не показывать «recording», если данные не пишутся. После старта
/// `SelfCheck` в первые ~2 с убеждается, что буферы реально идут; если нет — определяет причину
/// (`SelfDiagnosis.diagnose`) и лечит её (перезапрос права / рестарт стрима 2–3 раза), а когда
/// лечение не помогло — возвращает понятную ошибку для показа в меню-баре. Во время записи крутит
/// watchdog: если поток буферов встал, перезапускает стрим, сохраняя уже записанные сегменты.
///
/// Вся принимающая решение логика — чистая (`SelfDiagnosis`, `FlowWatchdog` в `ActaKit`, покрыты
/// тестами); здесь только опрос рекордера и таймеры, которые проверяются живым прогоном вручную.
@available(macOS 15.0, *)
final class SelfCheck: @unchecked Sendable {
    /// Сколько раз пытаться перезапустить стрим, прежде чем сдаться с понятной ошибкой.
    static let maxRestartAttempts = 3
    /// Окно наблюдения на старте, с — за это время должны прийти первые буферы.
    static let startupProbeSeconds = 2.0
    /// Порог watchdog, с: буферы не растут дольше — считаем, что стрим встал.
    static let watchdogStallSeconds = 6.0
    /// Период опроса watchdog'а, с.
    static let watchdogTickSeconds = 1.0

    private let log = Logger(subsystem: AppInfo.bundleID, category: "SelfCheck")
    private let recorder: AudioRecorder

    init(recorder: AudioRecorder) {
        self.recorder = recorder
    }

    /// После старта убедиться, что данные идут; при провале — самолечение. Возвращает `nil` при
    /// успехе, либо причину провала (её текст `userMessage` показывается в UI).
    func verifyStartAndHeal() async -> StartupFailure? {
        var attemptsLeft = Self.maxRestartAttempts
        while true {
            // Право на запись экрана — необходимое условие для системного звука; без него нет
            // смысла ни пробовать, ни рестартить.
            guard Permissions.hasScreenRecording else {
                log.error("Самодиагностика: нет права Screen Recording")
                return .noScreenRecordingPermission
            }

            if await probeDataFlow() {
                return nil
            }

            let snapshot = SelfDiagnosis.Snapshot(
                hasScreenRecording: Permissions.hasScreenRecording,
                hasMicrophone: Permissions.hasMicrophone,
                streamStarted: recorder.isStreaming,
                bufferCount: recorder.receivedBufferCount,
                segmentBytesDelta: 0
            )
            let failure = SelfDiagnosis.diagnose(snapshot) ?? .noData

            switch SelfDiagnosis.action(for: failure, restartAttemptsLeft: attemptsLeft) {
            case .restartStream:
                attemptsLeft -= 1
                let reason = String(describing: failure)
                log.error("Данные не идут (\(reason, privacy: .public)); рестарт стрима, осталось: \(attemptsLeft)")
                do {
                    try await recorder.restart()
                } catch {
                    log.error("Рестарт стрима не удался: \(error.localizedDescription, privacy: .public)")
                    return .streamNotStarted
                }
            case .requestScreenRecording:
                return .noScreenRecordingPermission
            case .requestMicrophone:
                return .noMicrophonePermission
            case .reportError(let reported):
                log.error("Самодиагностика: лечение не помогло — \(reported.userMessage, privacy: .public)")
                return reported
            }
        }
    }

    /// Опросить поток буферов в течение окна старта. `true`, как только пришёл хотя бы один буфер.
    private func probeDataFlow() async -> Bool {
        let baseline = recorder.receivedBufferCount
        let steps = 4
        let perStepNanos = UInt64((Self.startupProbeSeconds / Double(steps)) * 1_000_000_000)
        for _ in 0..<steps {
            try? await Task.sleep(nanoseconds: perStepNanos)
            let delta = recorder.receivedBufferCount - baseline
            if SelfDiagnosis.isDataFlowing(bufferCount: delta, segmentBytesDelta: 0) {
                return true
            }
        }
        return false
    }

    /// Watchdog во время записи: следит, что буферы продолжают приходить. Если поток встал —
    /// перезапускает стрим (сохраняя сегменты); когда попытки исчерпаны — сообщает ошибку через
    /// `onStall`. Завершается по отмене задачи (на чистом стопе).
    func runWatchdog(onStall: @Sendable @escaping (StartupFailure) -> Void = { _ in }) async {
        var watchdog = FlowWatchdog(stallThreshold: Self.watchdogStallSeconds,
                                    startTime: Self.monotonicSeconds(),
                                    initialBufferCount: recorder.receivedBufferCount)
        var restartsLeft = Self.maxRestartAttempts
        let tickNanos = UInt64(Self.watchdogTickSeconds * 1_000_000_000)

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: tickNanos)
            if Task.isCancelled { break }

            let stalled = watchdog.observe(bufferCount: recorder.receivedBufferCount,
                                           at: Self.monotonicSeconds())
            guard stalled else { continue }

            if restartsLeft > 0 {
                restartsLeft -= 1
                log.error("Watchdog: поток буферов встал, рестарт стрима (осталось: \(restartsLeft))")
                try? await recorder.restart()
                // После рестарта сбрасываем окно наблюдения на новый счётчик буферов.
                watchdog = FlowWatchdog(stallThreshold: Self.watchdogStallSeconds,
                                        startTime: Self.monotonicSeconds(),
                                        initialBufferCount: recorder.receivedBufferCount)
            } else {
                log.error("Watchdog: поток встал, попытки рестарта исчерпаны")
                onStall(.noData)
                break
            }
        }
    }

    /// Монотонное время в секундах (не зависит от перевода системных часов) — для watchdog'а.
    private static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
