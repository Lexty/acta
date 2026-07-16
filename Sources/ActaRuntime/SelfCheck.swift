import ActaKit
import Foundation
import os

/// Startup self-diagnosis and recording watchdog (see the `crash-safe-recording` skill, SPEC §7).
///
/// Acta's requirement: **never** show "recording" when data is not being written. After the start,
/// `SelfCheck` spends the first ~2 s making sure buffers really are flowing; if they are not, it
/// determines the cause (`SelfDiagnosis.diagnose`) and heals it (re-request the permission / restart
/// the stream 2–3 times), and when healing does not help it returns a clear error to show in the
/// menu bar. During recording it runs a watchdog: if the buffer flow stalls, it restarts the stream,
/// keeping the segments already recorded.
///
/// All decision-making logic is pure (`SelfDiagnosis`, `FlowWatchdog` in `ActaKit`, covered by
/// tests); here there is only polling of the recorder and timers, which are checked by a live run
/// manually.
@available(macOS 15.0, *)
final class SelfCheck: @unchecked Sendable {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "SelfCheck")
    private let recorder: AudioRecorder
    private let permissions: PermissionChecking
    private let clock: SelfCheckClock

    init(recorder: AudioRecorder,
         permissions: PermissionChecking = SystemPermissions(),
         clock: SelfCheckClock = SystemClock()) {
        self.recorder = recorder
        self.permissions = permissions
        self.clock = clock
    }

    /// A snapshot of the recorder's counters — the baseline for deltas over the observation window.
    /// Tracks are kept separate: from the sum alone a dead track is indistinguishable from a live
    /// one (Task 4).
    private struct Counters {
        var system: TrackFlow
        var mic: TrackFlow
        var bytes: Int

        var received: Int { system.received + mic.received }
        var written: Int { system.written + mic.written }

        /// A snapshot of the tracks for the pure diagnosis logic (`SelfDiagnosis`).
        var flows: TrackFlows { TrackFlows(system: system, mic: mic) }

        /// Counter growth relative to the baseline snapshot — exactly what the diagnosis evaluates.
        func delta(from base: Counters) -> Counters {
            Counters(system: TrackFlow(received: system.received - base.system.received,
                                       written: system.written - base.system.written),
                     mic: TrackFlow(received: mic.received - base.mic.received,
                                    written: mic.written - base.mic.written),
                     bytes: bytes - base.bytes)
        }
    }

    /// - Parameter includingBytes: whether to measure the size of the segments on disk. This walks
    ///   both directories with a `stat` per file; an hour of recording produces hundreds of them,
    ///   while the watchdog polls the counters once a second — load that grows for no reason. The
    ///   size is only needed by the startup probe (a second signal, independent of the writer, that
    ///   "data landed on disk"); the watchdog looks at the buffer counters and does not read
    ///   `bytes` at all.
    private func counters(includingBytes: Bool = true) -> Counters {
        let received = recorder.receivedBufferCounts
        let written = recorder.writtenBufferCounts
        return Counters(system: TrackFlow(received: received.system, written: written.system),
                        mic: TrackFlow(received: received.mic, written: written.mic),
                        bytes: includingBytes ? recorder.segmentBytesOnDisk : 0)
    }

    /// After the start, make sure data is flowing; on failure — self-healing. Returns `nil` on
    /// success, or the reason for the failure (its `userMessage` text is shown in the UI).
    func verifyStartAndHeal() async -> StartupFailure? {
        var attemptsLeft = SelfCheckTuning.maxRestartAttempts
        // Show the TCC dialog at most once per check: after a denial it will not appear again
        // anyway, and without this the healing loop would spin for nothing.
        var permissionRequested = false
        while true {
            // Permissions are a precondition: without screen recording there will be no system
            // audio, without the microphone only half the meeting gets recorded. Restarting the
            // stream here is pointless.
            if let missing = await missingPermission(alreadyRequested: &permissionRequested) {
                log.error("Self-diagnosis: \(missing.userMessage, privacy: .public)")
                return missing
            }

            let delta = await probeDataFlow(from: counters())
            let snapshot = SelfDiagnosis.Snapshot(
                hasScreenRecording: permissions.hasScreenRecording,
                hasMicrophone: permissions.hasMicrophone,
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
                log.error("Track '\(broken.title, privacy: .public)' is not being written: buffers rejected")
            }

            switch SelfDiagnosis.action(for: failure, restartAttemptsLeft: attemptsLeft) {
            case .restartStream:
                attemptsLeft -= 1
                let reason = String(describing: failure)
                log.error("""
                    Data is not flowing (\(reason, privacy: .public)); restarting stream, \
                    attempts left: \(attemptsLeft)
                    """)
                do {
                    try await recorder.restart()
                } catch let failure as StartupFailure {
                    log.error("Stream restart failed: \(failure.userMessage, privacy: .public)")
                    // A stream that failed to come up is exactly what the attempts exist for: it is
                    // too early to give up after the first one, the next iteration will see
                    // `streamStarted == false` and try again. Everything else (missing permissions)
                    // is not healed by a restart — report it right away.
                    guard failure == .streamNotStarted else { return failure }
                } catch {
                    log.error("Stream restart failed: \(error.localizedDescription, privacy: .public)")
                    return .streamNotStarted
                }
            case .requestScreenRecording, .requestMicrophone:
                // The permission was revoked on the fly — the next loop iteration will request it
                // and return an error with a hint if it still could not be granted.
                continue
            case .reportError(let reported):
                log.error("Self-diagnosis: healing did not help — \(reported.userMessage, privacy: .public)")
                return reported
            }
        }
    }

    /// Check both permissions, showing the system dialog if needed (once per check).
    /// Returns the reason for the failure if a permission is still missing, otherwise `nil`.
    private func missingPermission(alreadyRequested: inout Bool) async -> StartupFailure? {
        if !permissions.hasScreenRecording {
            if !alreadyRequested {
                alreadyRequested = true
                permissions.requestScreenRecording()
            }
            // The screen recording permission only applies to the next launch of the process, so
            // even after the user agrees in the dialog this recording cannot start — show a hint.
            guard permissions.hasScreenRecording else { return .noScreenRecordingPermission }
        }
        if !permissions.hasMicrophone {
            if !alreadyRequested, permissions.microphoneStatus == .notDetermined {
                alreadyRequested = true
                _ = await permissions.requestMicrophone()
            }
            guard permissions.hasMicrophone else { return .noMicrophonePermission }
        }
        return nil
    }

    /// Watch the counters for the whole startup window and return the growth over it.
    ///
    /// We watch the window to the end even if data started flowing on the very first step: an early
    /// exit would confirm the start based on the first track that came alive, while the second one
    /// might not have started writing yet — and a dead track would be indistinguishable from a
    /// merely slow one.
    private func probeDataFlow(from baseline: Counters) async -> Counters {
        await clock.sleep(for: SelfCheckTuning.startupProbeSeconds)
        return counters().delta(from: baseline)
    }

    /// Data is flowing and both tracks are being written, but the source of one of them is silent.
    /// We do not treat this as an error: silence in a meeting room is indistinguishable from a dead
    /// device, and a recording must not be aborted because of it. We log it so that the cause can be
    /// found during a post-mortem.
    private func warnIfTrackSilent(_ delta: Counters) {
        for track in Track.allCases where (track == .system ? delta.system : delta.mic).received == 0 {
            log.error("Track source '\(track.title, privacy: .public)' is silent: no buffers arriving")
        }
    }

    /// The watchdog during recording: makes sure buffers keep arriving. If the flow stalls, it
    /// restarts the stream (keeping the segments); when the attempts are exhausted, it reports the
    /// error via `onStall`. Finishes when the task is cancelled (on a clean stop).
    func runWatchdog(onStall: @Sendable @escaping (StartupFailure) -> Void = { _ in }) async {
        // We watch what has been written, not what has arrived: if writing to disk breaks, buffers
        // from the system keep coming and a watchdog based on them would notice nothing. On top of
        // the aggregate counter — one watchdog per track: the sum keeps growing while at least one
        // track is alive, and the aggregate watchdog would never see the dead second one (half the
        // meeting!).
        var trackers = makeWatchdogs(from: counters(includingBytes: false))
        var receivedAtWindowStart = trackers.received
        var restartsLeft = SelfCheckTuning.maxRestartAttempts
        /// Counters right after the last restart: growth relative to them tells whether it helped.
        var countersAfterRestart = Counters(system: TrackFlow(), mic: TrackFlow(), bytes: 0)
        // The reason for the last failed restart: it cannot be reconstructed from the counters
        // later, and it is exactly what the user must be told — not a guess like "no data / disk is
        // not being written".
        var restartFailure: StartupFailure?

        watch: while !Task.isCancelled {
            await clock.sleep(for: SelfCheckTuning.watchdogTickSeconds)
            if Task.isCancelled { break }

            let now = counters(includingBytes: false)
            let time = clock.now
            // The restart healed the flow — give the attempt budget back. Otherwise three attempts
            // would be a quota for the whole recording: an hour-long meeting with rare failures,
            // each successfully healed, would be cut off at the fourth one. The limit must catch a
            // hopeless stream (consecutive failed restarts), not the sum of long-fixed glitches.
            if restartsLeft < SelfCheckTuning.maxRestartAttempts,
               SelfDiagnosis.restartHealed(now.flows, since: countersAfterRestart.flows) {
                restartsLeft = SelfCheckTuning.maxRestartAttempts
                restartFailure = nil
            }
            let stalled = trackers.flow.observe(bufferCount: now.written, at: time)
            // Both observations are mandatory: short-circuiting would leave the second track without
            // an update.
            let systemStalled = trackers.system.observe(now.system, at: time)
            let micStalled = trackers.mic.observe(now.mic, at: time)
            let stalledTrack: Track? = systemStalled ? .system : (micStalled ? .mic : nil)
            guard stalled || stalledTrack != nil else { continue }

            if let stalledTrack {
                log.error("Watchdog: track '\(stalledTrack.title, privacy: .public)' is not being written")
            }

            if restartsLeft > 0 {
                restartsLeft -= 1
                log.error("Watchdog: recording stalled, restarting stream (attempts left: \(restartsLeft))")
                switch await attemptRestart() {
                case .succeeded:
                    restartFailure = nil
                case .retriable(let failure):
                    restartFailure = failure
                case .fatal(let failure):
                    onStall(failure)
                    break watch
                }
                // After the restart, reset the observation windows to the new counters.
                let fresh = counters(includingBytes: false)
                trackers = makeWatchdogs(from: fresh)
                receivedAtWindowStart = trackers.received
                countersAfterRestart = fresh
            } else {
                // The restart was failing with a concrete reason — it is more precise than a guess
                // based on the counters. Otherwise: the track receives buffers but does not write
                // them (or buffers were flowing the whole window and nothing got written) → it is
                // not the stream that stalled, but the writing to disk.
                let failure: StartupFailure = restartFailure
                    ?? (stalledTrack != nil || now.received > receivedAtWindowStart
                        ? .diskWriteFailed : .noData)
                log.error("Watchdog: recording stalled, giving up — \(failure.userMessage, privacy: .public)")
                onStall(failure)
                break
            }
        }
    }

    /// How an attempt to restart the stream ended.
    private enum RestartOutcome {
        case succeeded
        /// The stream did not come up — exactly what the attempts exist for: try again.
        case retriable(StartupFailure)
        /// Not healed by a restart (the permission was revoked on the fly) — no point spending
        /// attempts on it.
        case fatal(StartupFailure)
    }

    private func attemptRestart() async -> RestartOutcome {
        do {
            try await recorder.restart()
            return .succeeded
        } catch let failure as StartupFailure {
            log.error("Watchdog: restart failed — \(failure.userMessage, privacy: .public)")
            return failure == .streamNotStarted ? .retriable(failure) : .fatal(failure)
        } catch {
            log.error("Watchdog: restart failed: \(error.localizedDescription, privacy: .public)")
            return .retriable(.streamNotStarted)
        }
    }

    /// The set of recording watchdogs: the aggregate one (catches the death of the stream) plus one
    /// per track (they catch a track that the aggregate one cannot see behind the live other one).
    private struct Watchdogs {
        var flow: FlowWatchdog
        var system: TrackWatchdog
        var mic: TrackWatchdog
        /// Buffers received at the moment the window started — it tells "no audio" from
        /// "not being written".
        var received: Int

        /// A fresh set, primed with the current counters (recording start and every stream restart).
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
        Watchdogs(from: now, threshold: SelfCheckTuning.watchdogStallSeconds, startTime: clock.now)
    }
}
