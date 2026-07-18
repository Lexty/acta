import Foundation

/// A continuation that is resumed exactly once, whichever of the two racers gets there first.
///
/// Resuming a `CheckedContinuation` twice traps, and both the completion and the cancellation paths of
/// `ControlDispatcher.awaitAbandonably` legitimately try. A lock rather than actor isolation: `onCancel`
/// runs synchronously on whatever thread cancelled, with no isolation of its own to borrow.
final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        // A cancellation that landed before the continuation existed still counts: resume immediately
        // rather than waiting for a `fire()` that has already been and gone.
        if fired {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func fire() {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
