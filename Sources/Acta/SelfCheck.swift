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

    /// Снимок счётчиков рекордера — база для дельт за окно наблюдения. Дорожки держим раздельно:
    /// по сумме мёртвую дорожку не отличить от живой (Task 4).
    private struct Counters {
        var system: TrackFlow
        var mic: TrackFlow
        var bytes: Int

        var received: Int { system.received + mic.received }
        var written: Int { system.written + mic.written }

        /// Прирост счётчиков относительно базового снимка — то, что и оценивает диагностика.
        func delta(from base: Counters) -> Counters {
            Counters(system: TrackFlow(received: system.received - base.system.received,
                                       written: system.written - base.system.written),
                     mic: TrackFlow(received: mic.received - base.mic.received,
                                    written: mic.written - base.mic.written),
                     bytes: bytes - base.bytes)
        }
    }

    private func counters() -> Counters {
        let received = recorder.receivedBufferCounts
        let written = recorder.writtenBufferCounts
        return Counters(system: TrackFlow(received: received.system, written: written.system),
                        mic: TrackFlow(received: received.mic, written: written.mic),
                        bytes: recorder.segmentBytesOnDisk)
    }

    /// После старта убедиться, что данные идут; при провале — самолечение. Возвращает `nil` при
    /// успехе, либо причину провала (её текст `userMessage` показывается в UI).
    func verifyStartAndHeal() async -> StartupFailure? {
        var attemptsLeft = Self.maxRestartAttempts
        // Диалог TCC показываем не больше одного раза за проверку: при отказе он всё равно не
        // появится повторно, а цикл лечения без этого крутился бы вхолостую.
        var permissionRequested = false
        while true {
            // Права — необходимое условие: без записи экрана не будет системного звука, без
            // микрофона запишется только половина встречи. Рестартить стрим тут бессмысленно.
            if let missing = await missingPermission(alreadyRequested: &permissionRequested) {
                log.error("Самодиагностика: \(missing.userMessage, privacy: .public)")
                return missing
            }

            let delta = await probeDataFlow(from: counters())
            let snapshot = SelfDiagnosis.Snapshot(
                hasScreenRecording: Permissions.hasScreenRecording,
                hasMicrophone: Permissions.hasMicrophone,
                streamStarted: recorder.isStreaming,
                bufferCount: delta.received,
                writtenBufferCount: delta.written,
                segmentBytesDelta: delta.bytes,
                system: delta.system,
                mic: delta.mic
            )
            guard let failure = SelfDiagnosis.diagnose(snapshot) else {
                warnIfTrackSilent(delta)
                return nil
            }
            if let broken = SelfDiagnosis.brokenTrack(snapshot) {
                log.error("Дорожка «\(broken.title, privacy: .public)» не пишется: буферы идут, writer их не принимает")
            }

            switch SelfDiagnosis.action(for: failure, restartAttemptsLeft: attemptsLeft) {
            case .restartStream:
                attemptsLeft -= 1
                let reason = String(describing: failure)
                log.error("Данные не идут (\(reason, privacy: .public)); рестарт стрима, осталось: \(attemptsLeft)")
                do {
                    try await recorder.restart()
                } catch let failure as StartupFailure {
                    log.error("Рестарт стрима не удался: \(failure.userMessage, privacy: .public)")
                    // Не поднявшийся стрим — ровно то, ради чего попытки и заведены: сдаваться после
                    // первой рано, следующая итерация увидит `streamStarted == false` и попробует
                    // снова. Всё остальное (нет прав) рестартом не лечится — сообщаем сразу.
                    guard failure == .streamNotStarted else { return failure }
                } catch {
                    log.error("Рестарт стрима не удался: \(error.localizedDescription, privacy: .public)")
                    return .streamNotStarted
                }
            case .requestScreenRecording, .requestMicrophone:
                // Право отозвали на ходу — следующая итерация цикла запросит его и вернёт ошибку
                // с подсказкой, если выдать так и не удалось.
                continue
            case .reportError(let reported):
                log.error("Самодиагностика: лечение не помогло — \(reported.userMessage, privacy: .public)")
                return reported
            }
        }
    }

    /// Проверить оба права, при необходимости показав системный диалог (один раз за проверку).
    /// Возвращает причину провала, если права так и нет, иначе `nil`.
    private func missingPermission(alreadyRequested: inout Bool) async -> StartupFailure? {
        if !Permissions.hasScreenRecording {
            if !alreadyRequested {
                alreadyRequested = true
                Permissions.requestScreenRecording()
            }
            // Право на запись экрана применяется только к следующему запуску процесса, поэтому
            // даже после согласия в диалоге эту запись начать нельзя — показываем подсказку.
            guard Permissions.hasScreenRecording else { return .noScreenRecordingPermission }
        }
        if !Permissions.hasMicrophone {
            if !alreadyRequested, Permissions.microphoneStatus == .notDetermined {
                alreadyRequested = true
                _ = await Permissions.requestMicrophone()
            }
            guard Permissions.hasMicrophone else { return .noMicrophonePermission }
        }
        return nil
    }

    /// Понаблюдать за счётчиками всё окно старта и вернуть прирост за него.
    ///
    /// Окно досматриваем до конца, даже если данные пошли на первом же шаге: ранний выход
    /// подтверждал бы старт по первой ожившей дорожке, а вторая могла ещё не начать писать —
    /// и мёртвую дорожку было бы не отличить от просто медленной.
    private func probeDataFlow(from baseline: Counters) async -> Counters {
        try? await Task.sleep(nanoseconds: UInt64(Self.startupProbeSeconds * 1_000_000_000))
        return counters().delta(from: baseline)
    }

    /// Данные пошли, и обе дорожки пишутся, но источник одной из них молчит. Ошибкой это не
    /// считаем: тишину в переговорке от мёртвого устройства не отличить, а сорвать из-за неё запись
    /// нельзя. Пишем в лог, чтобы причина нашлась при разборе.
    private func warnIfTrackSilent(_ delta: Counters) {
        for track in Track.allCases where (track == .system ? delta.system : delta.mic).received == 0 {
            log.error("Источник дорожки «\(track.title, privacy: .public)» молчит: буферы не приходят")
        }
    }

    /// Watchdog во время записи: следит, что буферы продолжают приходить. Если поток встал —
    /// перезапускает стрим (сохраняя сегменты); когда попытки исчерпаны — сообщает ошибку через
    /// `onStall`. Завершается по отмене задачи (на чистом стопе).
    func runWatchdog(onStall: @Sendable @escaping (StartupFailure) -> Void = { _ in }) async {
        // Следим за записанным, а не за пришедшим: если сломается запись на диск, буферы от
        // системы продолжат идти, и watchdog по ним ничего бы не заметил. Плюс к суммарному
        // счётчику — по watchdog'у на дорожку: сумма растёт, пока жива хотя бы одна, и мёртвую
        // вторую (половину встречи!) агрегатный watchdog не увидит никогда.
        var trackers = makeWatchdogs(from: counters())
        var receivedAtWindowStart = trackers.received
        var restartsLeft = Self.maxRestartAttempts
        /// Сколько было записано сразу после последнего рестарта: рост сверх этого = рестарт помог.
        var writtenAfterRestart = 0
        // Причина последнего неудавшегося рестарта: по счётчикам её потом не восстановить, а
        // сообщить пользователю надо именно её, а не догадку «нет данных / не пишется диск».
        var restartFailure: StartupFailure?
        let tickNanos = UInt64(Self.watchdogTickSeconds * 1_000_000_000)

        watch: while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: tickNanos)
            if Task.isCancelled { break }

            let now = counters()
            let time = Self.monotonicSeconds()
            // Рестарт вылечил поток — возвращаем бюджет попыток. Иначе три попытки были бы квотой
            // на всю запись: часовая встреча с редкими, каждый раз успешно вылеченными провалами
            // оборвалась бы на четвёртом. Лимит должен ловить безнадёжный стрим (подряд идущие
            // неудачные рестарты), а не сумму давно устранённых сбоев.
            if restartsLeft < Self.maxRestartAttempts, now.written > writtenAfterRestart {
                restartsLeft = Self.maxRestartAttempts
                restartFailure = nil
            }
            let stalled = trackers.flow.observe(bufferCount: now.written, at: time)
            // Оба наблюдения обязательны: короткое замыкание оставило бы вторую дорожку без апдейта.
            let systemStalled = trackers.system.observe(now.system, at: time)
            let micStalled = trackers.mic.observe(now.mic, at: time)
            let stalledTrack: Track? = systemStalled ? .system : (micStalled ? .mic : nil)
            guard stalled || stalledTrack != nil else { continue }

            if let stalledTrack {
                log.error("Watchdog: дорожка «\(stalledTrack.title, privacy: .public)» не пишется на диск")
            }

            if restartsLeft > 0 {
                restartsLeft -= 1
                log.error("Watchdog: запись встала, рестарт стрима (осталось: \(restartsLeft))")
                switch await attemptRestart() {
                case .succeeded:
                    restartFailure = nil
                case .retriable(let failure):
                    restartFailure = failure
                case .fatal(let failure):
                    onStall(failure)
                    break watch
                }
                // После рестарта сбрасываем окна наблюдения на новые счётчики.
                let fresh = counters()
                trackers = makeWatchdogs(from: fresh)
                receivedAtWindowStart = trackers.received
                writtenAfterRestart = fresh.written
            } else {
                // Рестарт падал с конкретной причиной — она точнее догадки по счётчикам. Иначе:
                // дорожка получает буферы, но не пишет их (или буферы шли всё окно, а записи нет)
                // → встал не стрим, а запись на диск.
                let failure: StartupFailure = restartFailure
                    ?? (stalledTrack != nil || now.received > receivedAtWindowStart
                        ? .diskWriteFailed : .noData)
                log.error("Watchdog: запись встала, попытки рестарта исчерпаны — \(failure.userMessage, privacy: .public)")
                onStall(failure)
                break
            }
        }
    }

    /// Чем кончилась попытка рестарта стрима.
    private enum RestartOutcome {
        case succeeded
        /// Стрим не поднялся — ровно то, ради чего попытки и заведены: пробуем ещё.
        case retriable(StartupFailure)
        /// Рестартом не лечится (право отозвали на ходу) — тратить на это попытки незачем.
        case fatal(StartupFailure)
    }

    private func attemptRestart() async -> RestartOutcome {
        do {
            try await recorder.restart()
            return .succeeded
        } catch let failure as StartupFailure {
            log.error("Watchdog: рестарт не удался — \(failure.userMessage, privacy: .public)")
            return failure == .streamNotStarted ? .retriable(failure) : .fatal(failure)
        } catch {
            log.error("Watchdog: рестарт не удался: \(error.localizedDescription, privacy: .public)")
            return .retriable(.streamNotStarted)
        }
    }

    /// Набор watchdog'ов записи: суммарный (ловит смерть стрима) + по одному на дорожку (ловят
    /// дорожку, которую суммарный не видит за живой второй).
    private struct Watchdogs {
        var flow: FlowWatchdog
        var system: TrackWatchdog
        var mic: TrackWatchdog
        /// Пришло буферов на момент старта окна — по нему отличаем «нет звука» от «не пишется».
        var received: Int

        /// Свежий набор, заряженный текущими счётчиками (старт записи и каждый рестарт стрима).
        init(from now: Counters, threshold: Double, startTime: Double) {
            flow = FlowWatchdog(stallThreshold: threshold, startTime: startTime,
                                initialBufferCount: now.written)
            system = TrackWatchdog(stallThreshold: threshold, startTime: startTime,
                                   initialFlow: now.system)
            mic = TrackWatchdog(stallThreshold: threshold, startTime: startTime,
                                initialFlow: now.mic)
            received = now.received
        }
    }

    private func makeWatchdogs(from now: Counters) -> Watchdogs {
        Watchdogs(from: now, threshold: Self.watchdogStallSeconds, startTime: Self.monotonicSeconds())
    }

    /// Монотонное время в секундах (не зависит от перевода системных часов) — для watchdog'а.
    private static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
