import Foundation

/// Everything a `RecordingSession` needs from the outside world, in one value: where buffers come
/// from, who answers permission questions, and what tells the time.
///
/// **Why a value and not three default arguments.** The shipped wiring is a claim worth testing —
/// "in production these are the real implementations" is exactly what a refactor silently breaks —
/// and a default argument is unreachable from a test: you cannot ask a function what it *would* have
/// passed. `RecordingDependencies.live` is that claim, written once, in a form a test can assert
/// against directly instead of prying open a session's private fields (which proves nothing about
/// how they got there).
///
/// The members are factories, not instances: a source is stateful and belongs to exactly one
/// recording, so `.live` must mint a fresh one per session rather than hand the same one round.
@available(macOS 15.0, *)
public struct RecordingDependencies: Sendable {
    /// Where the audio buffers come from.
    public var makeSource: @Sendable () -> CaptureSource
    /// Who answers the TCC questions.
    public var makePermissions: @Sendable () -> PermissionChecking
    /// What the self-diagnosis waits on and measures stalls against.
    public var makeClock: @Sendable () -> SelfCheckClock

    public init(makeSource: @escaping @Sendable () -> CaptureSource,
                makePermissions: @escaping @Sendable () -> PermissionChecking,
                makeClock: @escaping @Sendable () -> SelfCheckClock) {
        self.makeSource = makeSource
        self.makePermissions = makePermissions
        self.makeClock = makeClock
    }

    /// The production wiring: real capture, real TCC, real time.
    public static let live = RecordingDependencies(
        makeSource: { SCKCaptureSource() },
        makePermissions: { SystemPermissions() },
        makeClock: { SystemClock() }
    )
}
