import Foundation

/// Holds the display (and the system) awake for exactly as long as a recording runs.
///
/// Why this exists — proven live on 2026-07-15, not theorised. A recording stopped on its own after
/// 2:20 because the display went idle: ScreenCaptureKit is a *screen* capture API, and the moment
/// macOS turned the display off it reported `"Failed to find any displays or windows to capture"`,
/// the watchdog restarted the stream three times, failed, and stopped the recording. Sitting in a
/// meeting *listening* is precisely the inactivity that puts the display to sleep, so this is a
/// failure on every other meeting. Letting the display sleep and reconnecting on wake was rejected:
/// it would leave a hole in the audio for the whole sleep, which is the worst trade a recorder can
/// make.
///
/// `ProcessInfo.beginActivity` is the modern wrapper over `IOPMAssertion`; its assertion is released
/// by the kernel if the process dies, so a `kill -9` mid-recording cannot leave the machine pinned
/// awake forever. System idle sleep is disabled alongside display sleep because it kills a recording
/// just as dead.
///
/// ⚠️ The honest limit: an activity assertion only prevents **idle** sleep. Closing the lid, a hot
/// corner or an explicit Sleep still tears the stream down, and for those the watchdog remains the
/// only defence — it stops the recording and says so.
///
/// Lives in `ActaKit` for the same reason `SegmentRepair` does: it touches no file system, but under
/// CLT-only a unit test can only reach what lives here, and "was the assertion actually taken, and
/// actually released again" is exactly the question that reading the code cannot answer — a leaked
/// assertion keeps the machine awake forever and nobody knows why. `DisplayWakeLockTests` asks
/// `pmset -g assertions` instead.
///
/// Not thread-safe by itself: `RecordingSession` calls `acquire`/`release` from the main actor.
public final class DisplayWakeLock {
    /// The reason string, which is what `pmset -g assertions` shows a human. Named after the app so
    /// that the answer to "what is keeping this Mac awake?" is one line long.
    public static let reason = "\(AppInfo.name) is recording audio"

    /// The activity token, `nil` when nothing is held. Its presence *is* the state — which is what
    /// makes `acquire`/`release` idempotent: a watchdog stream restart must neither stack a second
    /// assertion nor drop the one already held.
    private var token: NSObjectProtocol?

    public init() {}

    /// Whether an assertion is held right now.
    public var isHeld: Bool { token != nil }

    /// Take the assertion, unless it is already held.
    public func acquire() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: Self.reason)
    }

    /// Release the assertion, if one is held. Safe to call when it is not: every recording exit path
    /// — clean stop, the watchdog giving up, a failed start, any error — calls this, and they
    /// overlap.
    public func release() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    /// The assertion must never outlive the recording. `endActivity` is the documented counterpart of
    /// `beginActivity`; dropping the token without it is not.
    deinit {
        release()
    }
}
