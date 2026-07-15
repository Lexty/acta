import Testing
import ActaKit

// Startup self-diagnosis and the watchdog - pure logic, covered separately from
// ScreenCaptureKit/timers: the "data is not flowing" detector on a fake source and the choice of
// action per failure type (Task 4).

// MARK: - The "data is not flowing" detector

@Test
func dataFlowingWhenBuffersAreWritten() {
    #expect(SelfDiagnosis.isDataFlowing(writtenBufferCount: 1, segmentBytesDelta: 0))
    #expect(SelfDiagnosis.isDataFlowing(writtenBufferCount: 42, segmentBytesDelta: 0))
}

@Test
func dataFlowingWhenSegmentGrows() {
    // The second signal: no buffers were counted, but the current segment is growing on disk.
    #expect(SelfDiagnosis.isDataFlowing(writtenBufferCount: 0, segmentBytesDelta: 4096))
}

@Test
func dataNotFlowingWhenSilent() {
    #expect(SelfDiagnosis.isDataFlowing(writtenBufferCount: 0, segmentBytesDelta: 0) == false)
}

// MARK: - Diagnosing the cause from a snapshot

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
    // Data is flowing - there is no failure, even if some minor thing is missing.
    #expect(SelfDiagnosis.diagnose(snapshot(buffers: 5, written: 5)) == nil)
}

@Test
func diagnoseDiskWriteFailedWhenBuffersArriveButNothingIsWritten() {
    // Audio is arriving, but the writer does not accept it and the files are not growing: we
    // must not show "recording", and "check your audio device" would not help here - the problem
    // is the write to disk.
    let result = SelfDiagnosis.diagnose(snapshot(buffers: 120, written: 0, bytesDelta: 0))
    #expect(result == .diskWriteFailed)
}

@Test
func diagnoseNotFooledByBuffersThatNeverReachDisk() {
    // Key requirement: the signal for "recording is under way" is what was written, not what
    // arrived.
    #expect(SelfDiagnosis.diagnose(snapshot(buffers: 500, written: 0)) != nil)
}

@Test
func diagnoseNoScreenRecordingFirst() {
    // No Screen Recording permission - the top-priority cause (without it the stream will not
    // come up).
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
    // Both the stream failed to come up and there is no microphone: the stream wins (without it
    // there is no audio at all).
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
    // The permission is there, the stream came up, the microphone is allowed - but there are no
    // buffers: no device, or silence.
    let result = SelfDiagnosis.diagnose(snapshot())
    #expect(result == .noData)
}

// MARK: - A dead track while the other one is alive

@Test
func trackIsWriteBrokenOnlyWhenBuffersArriveButNothingIsWritten() {
    #expect(TrackFlow(received: 100, written: 0).isWriteBroken)
    #expect(TrackFlow(received: 100, written: 1).isWriteBroken == false)
    // A silent source is not considered broken: there is simply nothing to write.
    #expect(TrackFlow(received: 0, written: 0).isWriteBroken == false)
}

@Test
func diagnoseDetectsDeadMicMaskedByLiveSystemAudio() {
    // The key case: system audio is being written and keeps the aggregate counters growing,
    // while the microphone buffers arrive and vanish. We must not show "recording" - half the
    // meeting would be lost.
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
    // The other participants are silent (there are no system track buffers at all) - this is not
    // a recording failure.
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

// MARK: - Choosing the action per failure type

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
    // The screen permission is the most common case; the hint points the way to System Settings.
    #expect(StartupFailure.noScreenRecordingPermission.userMessage.contains("Screen Recording"))
}

// MARK: - Watchdog for the buffer flow

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
    // The counter froze at 100.
    #expect(watchdog.observe(bufferCount: 100, at: 2) == false) // still within the threshold
    #expect(watchdog.observe(bufferCount: 100, at: 4) == false)
    #expect(watchdog.observe(bufferCount: 100, at: 5) == true)  // 5 s with no progress -> stalled
}

@Test
func watchdogResetsAfterProgressResumes() {
    var watchdog = FlowWatchdog(stallThreshold: 5, startTime: 0, initialBufferCount: 0)
    #expect(watchdog.observe(bufferCount: 0, at: 4) == false)
    // Progress resumed - the window shifts to t=4.
    #expect(watchdog.observe(bufferCount: 5, at: 4) == false)
    #expect(watchdog.observe(bufferCount: 5, at: 8) == false) // 4 s since progress - still fine
    #expect(watchdog.observe(bufferCount: 5, at: 9) == true)  // 5 s with no progress -> stalled
}

// MARK: - Watchdog for an individual track

@Test
func trackWatchdogNoStallWhileTrackWrites() {
    var watchdog = TrackWatchdog(stallThreshold: 5, startTime: 0)
    #expect(watchdog.observe(TrackFlow(received: 10, written: 10), at: 2) == false)
    #expect(watchdog.observe(TrackFlow(received: 20, written: 20), at: 4) == false)
    #expect(watchdog.observe(TrackFlow(received: 30, written: 30), at: 9) == false)
}

@Test
func trackWatchdogFiresWhenBuffersArriveButTrackWritesNothing() {
    // The track died: buffers keep coming, the writer stays silent. The aggregate counter may
    // still grow thanks to the other, live track - which is exactly why a separate watchdog is
    // needed.
    var watchdog = TrackWatchdog(stallThreshold: 5, startTime: 0,
                                 initialFlow: TrackFlow(received: 10, written: 10))
    #expect(watchdog.observe(TrackFlow(received: 20, written: 10), at: 3) == false)
    #expect(watchdog.observe(TrackFlow(received: 30, written: 10), at: 5) == true)
}

@Test
func trackWatchdogTreatsSilentSourceAsIdleNotStalled() {
    // No buffers arrive for the track at all (a pause in the conversation) - there is nothing to
    // write, so this is not a stall.
    var watchdog = TrackWatchdog(stallThreshold: 5, startTime: 0,
                                 initialFlow: TrackFlow(received: 10, written: 10))
    #expect(watchdog.observe(TrackFlow(received: 10, written: 10), at: 30) == false)
    #expect(watchdog.observe(TrackFlow(received: 10, written: 10), at: 60) == false)
    // The source came back to life but there are still no writes - the window is counted from
    // the last observation.
    #expect(watchdog.observe(TrackFlow(received: 20, written: 10), at: 62) == false)
    #expect(watchdog.observe(TrackFlow(received: 30, written: 10), at: 65) == true)
}

@Test
func trackWatchdogResetsAfterWritesResume() {
    var watchdog = TrackWatchdog(stallThreshold: 5, startTime: 0,
                                 initialFlow: TrackFlow(received: 0, written: 0))
    #expect(watchdog.observe(TrackFlow(received: 10, written: 0), at: 4) == false)
    // Writing started - the window shifts to t=4 (a stream restart healed the track).
    #expect(watchdog.observe(TrackFlow(received: 20, written: 5), at: 4) == false)
    #expect(watchdog.observe(TrackFlow(received: 30, written: 5), at: 8) == false)
    #expect(watchdog.observe(TrackFlow(received: 40, written: 5), at: 9) == true)
}

// MARK: - Refunding the restart budget (SelfDiagnosis.restartHealed)

@Test
func restartHealedWhenBothTracksResumeWriting() {
    // The restart healed both tracks - the attempt budget is duly refunded: otherwise three
    // attempts would become a quota for the whole meeting, and an hour-long recording with rare
    // but healed glitches would be cut short.
    let base = TrackFlows(system: TrackFlow(received: 100, written: 100),
                          mic: TrackFlow(received: 100, written: 100))
    let now = TrackFlows(system: TrackFlow(received: 200, written: 200),
                         mic: TrackFlow(received: 200, written: 200))
    #expect(SelfDiagnosis.restartHealed(now, since: base))
}

@Test
func restartNotHealedWhileOneTrackStaysBroken() {
    // Regression: live system audio drags the aggregate counter up while the microphone receives
    // buffers and writes NOT A SINGLE one. In aggregate this would look like "the restart
    // helped" - the budget would be refunded forever, the error would never surface, and half
    // the meeting would be silently lost.
    let base = TrackFlows(system: TrackFlow(received: 100, written: 100),
                          mic: TrackFlow(received: 100, written: 50))
    let now = TrackFlows(system: TrackFlow(received: 200, written: 200),
                         mic: TrackFlow(received: 200, written: 50))
    #expect(SelfDiagnosis.restartHealed(now, since: base) == false)
}

@Test
func restartNotHealedWhenNothingIsWritten() {
    // The stream is dead: no buffers arrive at all, both tracks are "silent". A silent track is
    // not considered broken, so it is the growth of the aggregate that must rule this case out -
    // otherwise the restarts would go on forever.
    let base = TrackFlows(system: TrackFlow(received: 100, written: 100),
                          mic: TrackFlow(received: 100, written: 100))
    #expect(SelfDiagnosis.restartHealed(base, since: base) == false)
}

@Test
func restartHealedWithSilentButWorkingTrack() {
    // There is no microphone on the machine: its buffers never arrive, there is nothing to
    // write. This is normal, not a failure - otherwise a Mac without a microphone would burn
    // through the restart budget for no reason and the recording would break down.
    let base = TrackFlows(system: TrackFlow(received: 100, written: 100),
                          mic: TrackFlow(received: 0, written: 0))
    let now = TrackFlows(system: TrackFlow(received: 200, written: 200),
                         mic: TrackFlow(received: 0, written: 0))
    #expect(SelfDiagnosis.restartHealed(now, since: base))
}

@Test
func trackHealedTreatsSilenceAsHealthyAndWriteStallAsBroken() {
    let base = TrackFlow(received: 10, written: 10)
    // Buffers arrive, nothing is written - broken.
    #expect(SelfDiagnosis.trackHealed(TrackFlow(received: 20, written: 10), since: base) == false)
    // No buffers arrive - there is nothing to write, so we do not treat it as broken.
    #expect(SelfDiagnosis.trackHealed(TrackFlow(received: 10, written: 10), since: base))
    // Writing started - alive.
    #expect(SelfDiagnosis.trackHealed(TrackFlow(received: 20, written: 20), since: base))
}
