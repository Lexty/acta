import AVFoundation
import ActaKit
import ActaRuntime
import Foundation

// The two seams that answer questions about the *system* rather than about audio: what TCC would say,
// and what `powerd` was told. They sit apart from `CaptureTestFixtures` because they have nothing to
// do with a capture source — and because that file had grown past what one file should hold.

// MARK: - Fake permissions

/// `PermissionChecking` with no system dialog behind it: it answers granted/denied per permission
/// and counts what was asked of it.
final class FakePermissions: PermissionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var screenGranted: Bool
    private var micStatus: AVAuthorizationStatus
    /// What a `requestScreenRecording()` / `requestMicrophone()` turns the answer into — the user
    /// agreeing in the dialog, or refusing.
    private var grantsOnRequest: Bool
    private var screenRequests = 0
    private var micRequests = 0

    init(screenGranted: Bool = true,
         micStatus: AVAuthorizationStatus = .authorized,
         grantsOnRequest: Bool = false) {
        self.screenGranted = screenGranted
        self.micStatus = micStatus
        self.grantsOnRequest = grantsOnRequest
    }

    /// How many times the code asked the system to prompt, per permission. Requesting when nothing
    /// needs requesting is a real bug — it is a dialog in the user's face on every restart.
    var screenRequestCount: Int { withLock { screenRequests } }
    var micRequestCount: Int { withLock { micRequests } }

    /// The user taking a permission away in System Settings while the app is running. Without these,
    /// an answer is fixed at construction and `SelfCheck`'s whole permission-diagnosis branch is
    /// unreachable: `AudioRecorder` rejects a start that has no permissions, so the only way into that
    /// code is a permission that disappears *after* the start.
    func revokeScreenRecording() { withLock { screenGranted = false } }

    /// The microphone answer going back to "never asked" — a TCC reset (`tccutil`, "Reset Location &
    /// Privacy") mid-run. Rare, but it is what makes the two request flags observably independent.
    func resetMicrophone() { withLock { micStatus = .notDetermined } }

    var hasScreenRecording: Bool { withLock { screenGranted } }

    @discardableResult
    func requestScreenRecording() -> Bool {
        withLock {
            screenRequests += 1
            if grantsOnRequest { screenGranted = true }
            return screenGranted
        }
    }

    var microphoneStatus: AVAuthorizationStatus { withLock { micStatus } }

    func requestMicrophone() async -> Bool {
        withLock {
            micRequests += 1
            if grantsOnRequest { micStatus = .authorized }
            return micStatus == .authorized
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Wake lock counting

/// A `DisplayWakeLock` whose activity calls are counted rather than made — the only way to prove a
/// failed start gave the assertion back, since a dropped token ends its activity by itself and the
/// OS therefore cannot tell a correct release from a leak.
final class CountingWakeLock: @unchecked Sendable {
    private let lock = NSLock()
    private var begun = 0
    private var ended = 0

    var beginCount: Int { lock.withLock { begun } }
    var endCount: Int { lock.withLock { ended } }

    func makeWakeLock() -> DisplayWakeLock {
        DisplayWakeLock(
            begin: { _ in
                self.lock.withLock { self.begun += 1 }
                return NSObject()
            },
            end: { _ in self.lock.withLock { self.ended += 1 } })
    }
}
