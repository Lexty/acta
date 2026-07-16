import Foundation

/// Tuning of the startup self-diagnosis and the recording watchdog: how long to watch, how often to
/// look, and how many times to try healing before giving up.
///
/// These are pure values, and they live here rather than on the runtime's `SelfCheck` for one
/// reason: a test that drives the healing path has to assert the **exact** number of restarts, and
/// "3" written twice — once in the code, once in the test — is a test that agrees with itself rather
/// than with the app. `SelfCheck` is internal to `ActaRuntime`, so its constants were unreachable.
public enum SelfCheckTuning {
    /// How many times to try restarting the stream before giving up with a clear error.
    public static let maxRestartAttempts = 3
    /// Startup observation window, s — the first buffers must arrive within it.
    public static let startupProbeSeconds = 2.0
    /// Watchdog threshold, s: if buffers stop growing for longer, we consider the stream stalled.
    public static let watchdogStallSeconds = 6.0
    /// Watchdog polling period, s.
    public static let watchdogTickSeconds = 1.0
}
