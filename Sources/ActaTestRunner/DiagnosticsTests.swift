import Testing
import ActaKit

// Самодиагностика старта и watchdog — чистая логика, покрыта отдельно от ScreenCaptureKit/таймеров:
// детектор «данные не текут» на фейковом источнике и выбор действия по типу ошибки (Task 4).

// MARK: - Детектор «данные не текут»

@Test
func dataFlowingWhenBuffersAreWritten() {
    #expect(SelfDiagnosis.isDataFlowing(writtenBufferCount: 1, segmentBytesDelta: 0))
    #expect(SelfDiagnosis.isDataFlowing(writtenBufferCount: 42, segmentBytesDelta: 0))
}

@Test
func dataFlowingWhenSegmentGrows() {
    // Второй сигнал: буферов не считали, но текущий сегмент растёт на диске.
    #expect(SelfDiagnosis.isDataFlowing(writtenBufferCount: 0, segmentBytesDelta: 4096))
}

@Test
func dataNotFlowingWhenSilent() {
    #expect(SelfDiagnosis.isDataFlowing(writtenBufferCount: 0, segmentBytesDelta: 0) == false)
}

// MARK: - Диагноз причины по снимку

private func snapshot(hasScreen: Bool = true, hasMic: Bool = true, streamStarted: Bool = true,
                      buffers: Int = 0, written: Int = 0, bytesDelta: Int = 0,
                      system: TrackFlow = TrackFlow(),
                      mic: TrackFlow = TrackFlow()) -> SelfDiagnosis.Snapshot {
    SelfDiagnosis.Snapshot(hasScreenRecording: hasScreen, hasMicrophone: hasMic,
                           streamStarted: streamStarted, bufferCount: buffers,
                           writtenBufferCount: written, segmentBytesDelta: bytesDelta,
                           system: system, mic: mic)
}

@Test
func diagnoseNilWhenDataFlows() {
    // Данные идут — причины нет, даже если чего-то по мелочи не хватает.
    #expect(SelfDiagnosis.diagnose(snapshot(buffers: 5, written: 5)) == nil)
}

@Test
func diagnoseDiskWriteFailedWhenBuffersArriveButNothingIsWritten() {
    // Звук идёт, а writer его не принимает и файлы не растут: показывать «recording» нельзя,
    // и «проверьте аудиоустройство» тут не поможет — проблема в записи на диск.
    let result = SelfDiagnosis.diagnose(snapshot(buffers: 120, written: 0, bytesDelta: 0))
    #expect(result == .diskWriteFailed)
}

@Test
func diagnoseNotFooledByBuffersThatNeverReachDisk() {
    // Ключевое требование: сигналом «идёт запись» считается записанное, а не пришедшее.
    #expect(SelfDiagnosis.diagnose(snapshot(buffers: 500, written: 0)) != nil)
}

@Test
func diagnoseNoScreenRecordingFirst() {
    // Нет права записи экрана — приоритетная причина (без него стрим не поднимется).
    let result = SelfDiagnosis.diagnose(snapshot(hasScreen: false, hasMic: false, streamStarted: false))
    #expect(result == .noScreenRecordingPermission)
}

@Test
func diagnoseStreamNotStarted() {
    let result = SelfDiagnosis.diagnose(snapshot(streamStarted: false))
    #expect(result == .streamNotStarted)
}

@Test
func diagnoseStreamNotStartedBeatsMissingMic() {
    // И стрим не поднялся, и нет микрофона: приоритет у стрима (без него звука нет вовсе).
    let result = SelfDiagnosis.diagnose(snapshot(hasMic: false, streamStarted: false))
    #expect(result == .streamNotStarted)
}

@Test
func diagnoseNoMicrophone() {
    let result = SelfDiagnosis.diagnose(snapshot(hasMic: false))
    #expect(result == .noMicrophonePermission)
}

@Test
func diagnoseNoDataWhenStreamUpButSilent() {
    // Право есть, стрим поднялся, микрофон разрешён — но буферов нет: нет девайса/тишина.
    let result = SelfDiagnosis.diagnose(snapshot())
    #expect(result == .noData)
}

// MARK: - Мёртвая дорожка при живой второй

@Test
func trackIsWriteBrokenOnlyWhenBuffersArriveButNothingIsWritten() {
    #expect(TrackFlow(received: 100, written: 0).isWriteBroken)
    #expect(TrackFlow(received: 100, written: 1).isWriteBroken == false)
    // Молчащий источник поломкой не считается: писать просто нечего.
    #expect(TrackFlow(received: 0, written: 0).isWriteBroken == false)
}

@Test
func diagnoseDetectsDeadMicMaskedByLiveSystemAudio() {
    // Ключевой случай: системный звук пишется и держит суммарные счётчики растущими, а буферы
    // микрофона приходят и пропадают. Показывать «recording» нельзя — потеряется половина встречи.
    let result = SelfDiagnosis.diagnose(snapshot(buffers: 200, written: 100, bytesDelta: 65_536,
                                                 system: TrackFlow(received: 100, written: 100),
                                                 mic: TrackFlow(received: 100, written: 0)))
    #expect(result == .diskWriteFailed)
    #expect(SelfDiagnosis.brokenTrack(snapshot(mic: TrackFlow(received: 100, written: 0))) == .mic)
}

@Test
func diagnoseDetectsDeadSystemTrackMaskedByLiveMic() {
    let result = SelfDiagnosis.diagnose(snapshot(buffers: 200, written: 100, bytesDelta: 65_536,
                                                 system: TrackFlow(received: 100, written: 0),
                                                 mic: TrackFlow(received: 100, written: 100)))
    #expect(result == .diskWriteFailed)
    #expect(SelfDiagnosis.brokenTrack(snapshot(system: TrackFlow(received: 100, written: 0)))
        == .system)
}

@Test
func diagnoseAllowsSilentTrackWhenBothWritersAreAlive() {
    // Собеседники молчат (буферов системной дорожки нет вовсе) — это не поломка записи.
    let result = SelfDiagnosis.diagnose(snapshot(buffers: 100, written: 100, bytesDelta: 65_536,
                                                 system: TrackFlow(received: 0, written: 0),
                                                 mic: TrackFlow(received: 100, written: 100)))
    #expect(result == nil)
    #expect(SelfDiagnosis.brokenTrack(snapshot(system: TrackFlow(received: 0, written: 0))) == nil)
}

@Test
func diagnoseNilWhenBothTracksWrite() {
    #expect(SelfDiagnosis.diagnose(snapshot(buffers: 200, written: 200,
                                            system: TrackFlow(received: 100, written: 100),
                                            mic: TrackFlow(received: 100, written: 100))) == nil)
}

// MARK: - Выбор действия по типу ошибки

@Test
func actionRequestsPermissionForPermissionFailures() {
    #expect(SelfDiagnosis.action(for: .noScreenRecordingPermission, restartAttemptsLeft: 3)
        == .requestScreenRecording)
    #expect(SelfDiagnosis.action(for: .noMicrophonePermission, restartAttemptsLeft: 3)
        == .requestMicrophone)
}

@Test
func actionRestartsWhileAttemptsRemain() {
    #expect(SelfDiagnosis.action(for: .streamNotStarted, restartAttemptsLeft: 2) == .restartStream)
    #expect(SelfDiagnosis.action(for: .noData, restartAttemptsLeft: 1) == .restartStream)
    #expect(SelfDiagnosis.action(for: .diskWriteFailed, restartAttemptsLeft: 1) == .restartStream)
}

@Test
func actionReportsErrorWhenAttemptsExhausted() {
    #expect(SelfDiagnosis.action(for: .streamNotStarted, restartAttemptsLeft: 0)
        == .reportError(.streamNotStarted))
    #expect(SelfDiagnosis.action(for: .noData, restartAttemptsLeft: 0)
        == .reportError(.noData))
    #expect(SelfDiagnosis.action(for: .diskWriteFailed, restartAttemptsLeft: 0)
        == .reportError(.diskWriteFailed))
}

@Test
func failureMessagesAreNonEmptyAndActionable() {
    let failures: [StartupFailure] = [
        .noScreenRecordingPermission, .noMicrophonePermission, .streamNotStarted,
        .diskWriteFailed, .noData
    ]
    for failure in failures {
        #expect(failure.userMessage.isEmpty == false)
    }
    // Право экрана — самый частый случай, подсказка указывает путь в Системные настройки.
    #expect(StartupFailure.noScreenRecordingPermission.userMessage.contains("Запись экрана"))
}

// MARK: - Watchdog потока буферов

@Test
func watchdogNoStallWhileBuffersGrow() {
    var watchdog = FlowWatchdog(stallThreshold: 5, startTime: 0, initialBufferCount: 0)
    #expect(watchdog.observe(bufferCount: 10, at: 1) == false)
    #expect(watchdog.observe(bufferCount: 20, at: 3) == false)
    #expect(watchdog.observe(bufferCount: 30, at: 6) == false)
}

@Test
func watchdogFiresAfterThresholdWithoutProgress() {
    var watchdog = FlowWatchdog(stallThreshold: 5, startTime: 0, initialBufferCount: 100)
    // Счётчик замер на 100.
    #expect(watchdog.observe(bufferCount: 100, at: 2) == false) // ещё в пределах порога
    #expect(watchdog.observe(bufferCount: 100, at: 4) == false)
    #expect(watchdog.observe(bufferCount: 100, at: 5) == true)  // 5 с без прогресса → встал
}

@Test
func watchdogResetsAfterProgressResumes() {
    var watchdog = FlowWatchdog(stallThreshold: 5, startTime: 0, initialBufferCount: 0)
    #expect(watchdog.observe(bufferCount: 0, at: 4) == false)
    // Прогресс возобновился — окно сдвигается на момент t=4.
    #expect(watchdog.observe(bufferCount: 5, at: 4) == false)
    #expect(watchdog.observe(bufferCount: 5, at: 8) == false) // 4 с от прогресса — ещё ок
    #expect(watchdog.observe(bufferCount: 5, at: 9) == true)  // 5 с без прогресса → встал
}

// MARK: - Watchdog отдельной дорожки

@Test
func trackWatchdogNoStallWhileTrackWrites() {
    var watchdog = TrackWatchdog(stallThreshold: 5, startTime: 0)
    #expect(watchdog.observe(TrackFlow(received: 10, written: 10), at: 2) == false)
    #expect(watchdog.observe(TrackFlow(received: 20, written: 20), at: 4) == false)
    #expect(watchdog.observe(TrackFlow(received: 30, written: 30), at: 9) == false)
}

@Test
func trackWatchdogFiresWhenBuffersArriveButTrackWritesNothing() {
    // Дорожка умерла: буферы идут, writer молчит. Суммарный счётчик при этом может расти за счёт
    // живой второй дорожки — поэтому и нужен отдельный watchdog.
    var watchdog = TrackWatchdog(stallThreshold: 5, startTime: 0,
                                 initialFlow: TrackFlow(received: 10, written: 10))
    #expect(watchdog.observe(TrackFlow(received: 20, written: 10), at: 3) == false)
    #expect(watchdog.observe(TrackFlow(received: 30, written: 10), at: 5) == true)
}

@Test
func trackWatchdogTreatsSilentSourceAsIdleNotStalled() {
    // Буферы дорожки не приходят вовсе (пауза в разговоре) — записывать нечего, это не простой.
    var watchdog = TrackWatchdog(stallThreshold: 5, startTime: 0,
                                 initialFlow: TrackFlow(received: 10, written: 10))
    #expect(watchdog.observe(TrackFlow(received: 10, written: 10), at: 30) == false)
    #expect(watchdog.observe(TrackFlow(received: 10, written: 10), at: 60) == false)
    // Источник ожил, а записи по-прежнему нет — окно отсчитывается от последнего наблюдения.
    #expect(watchdog.observe(TrackFlow(received: 20, written: 10), at: 62) == false)
    #expect(watchdog.observe(TrackFlow(received: 30, written: 10), at: 65) == true)
}

@Test
func trackWatchdogResetsAfterWritesResume() {
    var watchdog = TrackWatchdog(stallThreshold: 5, startTime: 0,
                                 initialFlow: TrackFlow(received: 0, written: 0))
    #expect(watchdog.observe(TrackFlow(received: 10, written: 0), at: 4) == false)
    // Запись пошла — окно сдвигается на t=4 (рестарт стрима вылечил дорожку).
    #expect(watchdog.observe(TrackFlow(received: 20, written: 5), at: 4) == false)
    #expect(watchdog.observe(TrackFlow(received: 30, written: 5), at: 8) == false)
    #expect(watchdog.observe(TrackFlow(received: 40, written: 5), at: 9) == true)
}

// MARK: - Возврат бюджета рестартов (SelfDiagnosis.restartHealed)

@Test
func restartHealedWhenBothTracksResumeWriting() {
    // Рестарт вылечил обе дорожки — бюджет попыток честно возвращается: иначе три попытки стали бы
    // квотой на всю встречу и часовая запись с редкими вылеченными сбоями оборвалась бы.
    let base = TrackFlows(system: TrackFlow(received: 100, written: 100),
                          mic: TrackFlow(received: 100, written: 100))
    let now = TrackFlows(system: TrackFlow(received: 200, written: 200),
                         mic: TrackFlow(received: 200, written: 200))
    #expect(SelfDiagnosis.restartHealed(now, since: base))
}

@Test
func restartNotHealedWhileOneTrackStaysBroken() {
    // Регрессия: живой системный звук тянет агрегатный счётчик вверх, а микрофон получает буферы и
    // не пишет НИ ОДНОГО. По сумме это выглядело бы как «рестарт помог» — бюджет возвращался бы
    // вечно, ошибка не показалась бы никогда, а половина встречи молча терялась бы.
    let base = TrackFlows(system: TrackFlow(received: 100, written: 100),
                          mic: TrackFlow(received: 100, written: 50))
    let now = TrackFlows(system: TrackFlow(received: 200, written: 200),
                         mic: TrackFlow(received: 200, written: 50))
    #expect(SelfDiagnosis.restartHealed(now, since: base) == false)
}

@Test
func restartNotHealedWhenNothingIsWritten() {
    // Стрим мёртв: буферы не идут вообще, обе дорожки «молчат». Молчание дорожки поломкой не
    // считается, поэтому отсечь этот случай обязан рост агрегата — иначе рестарты были бы вечными.
    let base = TrackFlows(system: TrackFlow(received: 100, written: 100),
                          mic: TrackFlow(received: 100, written: 100))
    #expect(SelfDiagnosis.restartHealed(base, since: base) == false)
}

@Test
func restartHealedWithSilentButWorkingTrack() {
    // Микрофона на машине нет: его буферы не приходят, писать нечего. Это норма, а не поломка —
    // иначе Mac без микрофона исчерпывал бы бюджет рестартов на ровном месте и запись срывалась бы.
    let base = TrackFlows(system: TrackFlow(received: 100, written: 100),
                          mic: TrackFlow(received: 0, written: 0))
    let now = TrackFlows(system: TrackFlow(received: 200, written: 200),
                         mic: TrackFlow(received: 0, written: 0))
    #expect(SelfDiagnosis.restartHealed(now, since: base))
}

@Test
func trackHealedTreatsSilenceAsHealthyAndWriteStallAsBroken() {
    let base = TrackFlow(received: 10, written: 10)
    // Буферы идут, записи нет — сломана.
    #expect(SelfDiagnosis.trackHealed(TrackFlow(received: 20, written: 10), since: base) == false)
    // Буферы не идут — писать нечего, поломкой не считаем.
    #expect(SelfDiagnosis.trackHealed(TrackFlow(received: 10, written: 10), since: base))
    // Запись пошла — жива.
    #expect(SelfDiagnosis.trackHealed(TrackFlow(received: 20, written: 20), since: base))
}
