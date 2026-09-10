import Foundation

/// The reason a recording is "mute": the app thinks it is recording, but no data reaches the disk.
///
/// A key Acta requirement is to **never** show "recording" when data is not being written (see the
/// `crash-safe-recording` skill, SPEC §7). The type and its text stay in `ActaKit` as pure logic:
/// the reason is determined by `SelfDiagnosis.diagnose`, while the runtime (`SelfCheck`) only
/// collects a state snapshot and shows `userMessage` in the menu bar.
/// `CaseIterable` so that a reverse lookup over `userMessage` (`ControlState`'s classification of the
/// controller's single untyped `errorMessage`) enumerates the closed set rather than restating it.
public enum StartupFailure: Error, Equatable, Sendable, CaseIterable {
    /// No TCC permission for screen recording (required even for an audio-only `SCStream` capture).
    case noScreenRecordingPermission
    /// No TCC permission for the microphone.
    case noMicrophonePermission
    /// `SCStream` failed to come up / the delegate reported an error.
    case streamNotStarted
    /// Buffers arrive from the system but never reach the disk (the writer was not created / no free
    /// space / no permissions).
    case diskWriteFailed
    /// The stream came up, but no buffers arrive (no audio device / silence at the device input).
    case noData
    /// There is no microphone to record from: nothing is configured, or nothing configured is present.
    ///
    /// ⚠️ **Distinct from `.noMicrophonePermission` and from `.streamNotStarted`, and it must stay
    /// distinct.** Permission is granted, the machine may be full of microphones, and no stream was
    /// even attempted — the recording did not start because Acta will not silently record from
    /// "whatever the system default happens to be". The fix is a choice, not a retry, which is also
    /// why it is not worth a restart attempt below.
    case microphoneUnavailable

    /// User-facing text with a path to a fix — for display in the menu bar (Task 6).
    public var userMessage: String {
        switch self {
        case .noScreenRecordingPermission:
            return "No Screen Recording access. Grant it in System Settings > Privacy & Security > "
                + "Screen Recording, then restart Acta."
        case .noMicrophonePermission:
            return "No Microphone access. Grant it in System Settings > Privacy & Security > "
                + "Microphone."
        case .streamNotStarted:
            return "Could not start audio capture. Try starting the recording again."
        case .diskWriteFailed:
            return "Audio is arriving but is not being written to disk. Check free space and access "
                + "to the archive folder in Settings."
        case .noData:
            return "Not recording: no audio is arriving. Check your audio device and the audio source."
        case .microphoneUnavailable:
            return "No microphone selected. Choose one in Acta's menu, or pick \"Use system default\"."
        }
    }
}

/// A recording track. We count and diagnose tracks separately: live system audio must not mask a
/// dead microphone (or the other way round) — that is half the meeting.
public enum Track: String, Equatable, Sendable, CaseIterable {
    /// System audio — the other participants' voices.
    case system
    /// Microphone — the user's own voice.
    case mic

    /// Name for logs and messages.
    public var title: String {
        switch self {
        case .system: return "system audio"
        case .mic: return "microphone"
        }
    }
}

/// The flow of one track over an observation window: how many buffers arrived from the system and
/// how many of them the writer actually accepted into a segment.
public struct TrackFlow: Equatable, Sendable {
    /// Buffers that arrived from the system.
    public var received: Int
    /// Buffers the writer accepted into a segment.
    public var written: Int

    public init(received: Int = 0, written: Int = 0) {
        self.received = received
        self.written = written
    }

    /// The track's recording is broken: buffers keep arriving, but the writer accepted **none**.
    ///
    /// A silent source (`received == 0`) deliberately does not qualify: there is no way to tell a
    /// pause in the conversation or a missing device from a breakage, and killing a recording over
    /// silence is not acceptable. "Buffers yes, writes no", on the other hand, is unambiguous — the
    /// track's writer is broken (no free space, no access to the folder).
    public var isWriteBroken: Bool { received > 0 && written == 0 }
}

/// The flow of both tracks at a single moment — the snapshot the watchdog judges the recording's
/// health by.
public struct TrackFlows: Equatable, Sendable {
    public var system: TrackFlow
    public var mic: TrackFlow

    public init(system: TrackFlow = TrackFlow(), mic: TrackFlow = TrackFlow()) {
        self.system = system
        self.mic = mic
    }

    /// Buffers written by both tracks in total.
    public var written: Int { system.written + mic.written }
}

/// A self-healing action chosen from the failure reason. The runtime performs it (re-request a
/// permission, restart the stream, show the error); choosing the action is pure logic
/// (`SelfDiagnosis.action`).
public enum HealingAction: Equatable, Sendable {
    /// Request/prompt for the screen recording permission.
    case requestScreenRecording
    /// Request/prompt for the microphone permission.
    case requestMicrophone
    /// Restart the stream (attempts still remain).
    case restartStream
    /// Attempts exhausted / healing impossible — show a clear error.
    case reportError(StartupFailure)
}

/// Pure logic of startup self-diagnosis: from a state snapshot, decide whether recording is
/// happening, and if not — name the reason and choose an action. Kept apart from
/// ScreenCaptureKit/timers so it can be covered by unit tests (`DiagnosticsTests`) against a fake
/// source.
public enum SelfDiagnosis {
    /// A recording state snapshot for diagnosis. Assembled by the runtime from `Permissions` and the
    /// recorder.
    public struct Snapshot: Equatable, Sendable {
        /// Whether the Screen Recording permission is granted.
        public var hasScreenRecording: Bool
        /// Whether the Microphone permission is granted.
        public var hasMicrophone: Bool
        /// Whether `SCStream` came up (start did not throw, the stream is alive).
        public var streamStarted: Bool
        /// How many buffers arrived from the system over the observation window.
        public var bufferCount: Int
        /// How many buffers over the observation window the writer actually accepted into a segment.
        /// Differs from `bufferCount` when audio is arriving but writing to disk is broken.
        public var writtenBufferCount: Int
        /// How much the segments on disk grew over the observation window, bytes.
        public var segmentBytesDelta: Int
        /// The system-audio track's flow over the observation window.
        public var system: TrackFlow
        /// The microphone track's flow over the observation window.
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

    /// Whether data is really being **written**: the writer accepted at least one buffer **or** the
    /// segments grew on disk. The primary signal of self-diagnosis and of the watchdog.
    ///
    /// We count what was written, not what arrived from the system: "buffers are arriving" does not
    /// yet mean "data on disk", and showing "recording" without data on disk is not allowed
    /// (SPEC §7).
    public static func isDataFlowing(writtenBufferCount: Int, segmentBytesDelta: Int) -> Bool {
        writtenBufferCount > 0 || segmentBytesDelta > 0
    }

    /// The track whose recording is broken, or `nil` if both are fine. Checked even when data is
    /// flowing overall: without this a live track masks a dead one and the app shows "recording"
    /// while capturing half the meeting.
    public static func brokenTrack(_ snapshot: Snapshot) -> Track? {
        if snapshot.system.isWriteBroken { return .system }
        if snapshot.mic.isWriteBroken { return .mic }
        return nil
    }

    /// Determine the reason a recording is "mute" from a snapshot, or `nil` if data is flowing.
    ///
    /// The order matters: first the most common and most easily fixed case (no screen recording
    /// permission → without it the stream will not come up at all), then a stream that failed to
    /// start, then a missing microphone; after that "audio arrives but is not written" (a broken
    /// writer) and, finally, "the stream is there, but it is silent".
    public static func diagnose(_ snapshot: Snapshot) -> StartupFailure? {
        if isDataFlowing(writtenBufferCount: snapshot.writtenBufferCount,
                         segmentBytesDelta: snapshot.segmentBytesDelta) {
            // Data is flowing in aggregate — but if one of the tracks has buffers and no writes, we
            // will record only half the meeting. That is the same broken writer, healed by the same
            // restart.
            return brokenTrack(snapshot) == nil ? nil : .diskWriteFailed
        }
        if !snapshot.hasScreenRecording { return .noScreenRecordingPermission }
        if !snapshot.streamStarted { return .streamNotStarted }
        if !snapshot.hasMicrophone { return .noMicrophonePermission }
        if snapshot.bufferCount > 0 { return .diskWriteFailed }
        return .noData
    }

    /// Whether restarting the stream healed the recording — the watchdog's decision on refunding the
    /// budget of attempts.
    ///
    /// The budget is refunded only if more has been written **and** no track was left broken. Both
    /// halves are mandatory:
    ///
    /// - With the aggregate alone (`written` of the two tracks), a live track pulls the counter up
    ///   on behalf of a dead one: the budget would be refunded after every restart, the attempts
    ///   would never run out, and the error about a stalled recording would never show up once. The
    ///   app would keep spinning "recording in progress", recreating the stream every few seconds
    ///   and losing half the meeting — exactly what the per-track watchdogs exist to prevent.
    /// - With the tracks alone it is the other way round: a dead stream delivers no buffers at all,
    ///   both tracks look "silent", and silence does not count as a breakage (see `trackHealed`), so
    ///   the restart would be deemed successful. A growing aggregate rules that out.
    public static func restartHealed(_ now: TrackFlows, since base: TrackFlows) -> Bool {
        now.written > base.written
            && trackHealed(now.system, since: base.system)
            && trackHealed(now.mic, since: base.mic)
    }

    /// Whether a track is alive: the writer is accepting buffers again — or the source is silent and
    /// there is nothing to write.
    ///
    /// Silence is not treated as a breakage (the same logic as in
    /// `TrackWatchdog`/`TrackFlow.isWriteBroken`): otherwise a Mac without a microphone would burn
    /// through the restart budget for no reason.
    public static func trackHealed(_ now: TrackFlow, since base: TrackFlow) -> Bool {
        now.written > base.written || now.received == base.received
    }

    /// Choose an action for a reason, taking the remaining restart attempts into account.
    ///
    /// Permission problems are healed by a request/prompt; a stream that failed to come up and
    /// "silence" are worth a restart (2–3 times), and once the attempts run out we show a clear
    /// error.
    public static func action(for failure: StartupFailure, restartAttemptsLeft: Int) -> HealingAction {
        switch failure {
        case .noScreenRecordingPermission:
            return .requestScreenRecording
        case .noMicrophonePermission:
            return .requestMicrophone
        case .streamNotStarted, .diskWriteFailed, .noData:
            // A restart recreates both the stream and the segment — it heals a stalled stream as well
            // as a one-off write failure.
            return restartAttemptsLeft > 0 ? .restartStream : .reportError(failure)
        case .microphoneUnavailable:
            // ⚠️ **Never a restart.** Restarting re-resolves and reaches the same answer, so spending
            // the budget here would burn the attempts that a genuinely stalled stream needs, and delay
            // by the whole watchdog window a message the user could have acted on immediately.
            return .reportError(failure)
        }
    }
}

/// Watchdog over the buffer flow during a recording — the **pure logic** of detecting "the flow has
/// stalled".
///
/// The runtime (`SelfCheck`) periodically feeds monotonic time and the accumulated buffer counter in
/// here; the watchdog remembers the moment the counter last grew and raises a signal if there has
/// been no progress for longer than the threshold. Time is passed in from outside, which makes the
/// detector deterministic and testable.
public struct FlowWatchdog: Sendable, Equatable {
    /// Stall threshold, s: no growth of the counter for longer than this and the flow is considered
    /// stalled.
    public let stallThreshold: Double

    private var lastBufferCount: Int
    private var lastProgressTime: Double

    public init(stallThreshold: Double, startTime: Double, initialBufferCount: Int = 0) {
        self.stallThreshold = stallThreshold
        self.lastBufferCount = initialBufferCount
        self.lastProgressTime = startTime
    }

    /// Record an observation. Returns `true` if the flow has stalled: the buffer counter has not
    /// grown for longer than `stallThreshold` since the last progress.
    public mutating func observe(bufferCount: Int, at time: Double) -> Bool {
        if bufferCount > lastBufferCount {
            lastBufferCount = bufferCount
            lastProgressTime = time
            return false
        }
        return (time - lastProgressTime) >= stallThreshold
    }
}

/// Watchdog over a **single track** — it catches what the aggregate `FlowWatchdog` misses by
/// construction: a track receives buffers but does not write them, while the other track is alive
/// and keeps the shared counter growing. Without this, a dead microphone alongside live system audio
/// (or the other way round) is never detected at all.
///
/// Silence does not count as a stall: if a track's buffers are not arriving, there is nothing to
/// write — the observation window simply shifts. Otherwise a pause in the conversation would bring
/// the recording down (see `TrackFlow.isWriteBroken`).
public struct TrackWatchdog: Sendable, Equatable {
    /// Stall threshold, s: buffers arriving with no writes for longer than this and the track is
    /// considered stalled.
    public let stallThreshold: Double

    private var lastFlow: TrackFlow
    private var lastProgressTime: Double

    public init(stallThreshold: Double, startTime: Double, initialFlow: TrackFlow = TrackFlow()) {
        self.stallThreshold = stallThreshold
        self.lastFlow = initialFlow
        self.lastProgressTime = startTime
    }

    /// Record an observation (the track's counters accumulated since the recording started). Returns
    /// `true` if the track is receiving buffers but has not written a single one for longer than
    /// `stallThreshold`.
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
