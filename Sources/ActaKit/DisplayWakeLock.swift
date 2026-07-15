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
/// Lives in `ActaKit` for the historical reason `SegmentRepair` does: when both were written, the
/// test runner depended on `ActaKit` alone, so nothing else was reachable from a test. Since Task 11
/// extracted `ActaRuntime` that constraint is gone — new I/O-touching code belongs there — but this
/// type touches no file system, so it stays. The question worth testing is "was the assertion
/// actually taken, and actually released again": a leaked assertion keeps the machine awake forever
/// and nobody knows why. `DisplayWakeLockTests` asks `pmset -g assertions` rather than trust `isHeld`.
///
/// Thread-safe: `token` is guarded by a lock. The stated invariant used to be "`RecordingSession`
/// calls acquire/release from the main actor", which is **false** — `RecordingSession.start`/`stop`
/// are `nonisolated async`, so under SE-0338 they run on the cooperative pool, not on the caller's
/// actor. The calls happen to be serialized today by `RecordingController`'s phase gate, but a lock
/// costs nothing twice per recording and removes the reliance on a caller-side invariant: a torn
/// `token` means either a leaked kernel assertion or a lost one — the two failures this type exists
/// to prevent.
public final class DisplayWakeLock: @unchecked Sendable {
    /// The reason string, which is what `pmset -g assertions` shows a human. Named after the app so
    /// that the answer to "what is keeping this Mac awake?" is one line long.
    public static let reason = "\(AppInfo.name) is recording audio"

    /// The activity token, `nil` when nothing is held. Its presence *is* the state — which is what
    /// makes `acquire`/`release` idempotent: a watchdog stream restart must neither stack a second
    /// assertion nor drop the one already held.
    private var token: NSObjectProtocol?
    private let lock = NSLock()
    private let begin: (String) -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void

    public init() {
        self.begin = { reason in
            ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: reason)
        }
        self.end = { ProcessInfo.processInfo.endActivity($0) }
    }

    /// A testing seam, and the only way to observe `endActivity`. `beginActivity` returns a token
    /// that ends its own activity when it deallocates — verified, not assumed — so dropping the token
    /// and releasing it properly are **indistinguishable through `pmset`**. Every "the assertion went
    /// away" test therefore passes even against a `release()` that never calls `endActivity` and a
    /// `deinit` that does nothing. Counting the calls is the only way to prove the documented
    /// counterpart is actually invoked, so this init exists. `public` because `Scripts/bundle.sh`
    /// builds every target in release, where `@testable import` is unavailable.
    public init(begin: @escaping (String) -> NSObjectProtocol, end: @escaping (NSObjectProtocol) -> Void) {
        self.begin = begin
        self.end = end
    }

    /// Whether an assertion is held right now.
    public var isHeld: Bool {
        lock.withLock { token != nil }
    }

    /// Take the assertion, unless it is already held.
    public func acquire() {
        lock.withLock {
            guard token == nil else { return }
            token = begin(Self.reason)
        }
    }

    /// Release the assertion, if one is held. Safe to call when it is not: every recording exit path
    /// — clean stop, the watchdog giving up, a failed start, any error — calls this, and they
    /// overlap.
    public func release() {
        lock.withLock {
            guard let token else { return }
            end(token)
            self.token = nil
        }
    }

    /// The assertion must never outlive the recording. `endActivity` is the documented counterpart of
    /// `beginActivity`; dropping the token without it is not.
    deinit {
        release()
    }
}
