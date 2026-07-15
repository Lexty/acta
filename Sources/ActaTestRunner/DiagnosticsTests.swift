import Testing
import ActaKit

// Самодиагностика старта и watchdog — чистая логика, покрыта отдельно от ScreenCaptureKit/таймеров:
// детектор «данные не текут» на фейковом источнике и выбор действия по типу ошибки (Task 4).

// MARK: - Детектор «данные не текут»

@Test
func dataFlowingWhenBuffersArrive() {
    #expect(SelfDiagnosis.isDataFlowing(bufferCount: 1, segmentBytesDelta: 0))
    #expect(SelfDiagnosis.isDataFlowing(bufferCount: 42, segmentBytesDelta: 0))
}

@Test
func dataFlowingWhenSegmentGrows() {
    // Второй сигнал: буферов не считали, но текущий сегмент растёт на диске.
    #expect(SelfDiagnosis.isDataFlowing(bufferCount: 0, segmentBytesDelta: 4096))
}

@Test
func dataNotFlowingWhenSilent() {
    #expect(SelfDiagnosis.isDataFlowing(bufferCount: 0, segmentBytesDelta: 0) == false)
}

// MARK: - Диагноз причины по снимку

private func snapshot(hasScreen: Bool = true, hasMic: Bool = true, streamStarted: Bool = true,
                      buffers: Int = 0, bytesDelta: Int = 0) -> SelfDiagnosis.Snapshot {
    SelfDiagnosis.Snapshot(hasScreenRecording: hasScreen, hasMicrophone: hasMic,
                           streamStarted: streamStarted, bufferCount: buffers,
                           segmentBytesDelta: bytesDelta)
}

@Test
func diagnoseNilWhenDataFlows() {
    // Данные идут — причины нет, даже если чего-то по мелочи не хватает.
    #expect(SelfDiagnosis.diagnose(snapshot(buffers: 5)) == nil)
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
}

@Test
func actionReportsErrorWhenAttemptsExhausted() {
    #expect(SelfDiagnosis.action(for: .streamNotStarted, restartAttemptsLeft: 0)
        == .reportError(.streamNotStarted))
    #expect(SelfDiagnosis.action(for: .noData, restartAttemptsLeft: 0)
        == .reportError(.noData))
}

@Test
func failureMessagesAreNonEmptyAndActionable() {
    let failures: [StartupFailure] = [
        .noScreenRecordingPermission, .noMicrophonePermission, .streamNotStarted, .noData
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
