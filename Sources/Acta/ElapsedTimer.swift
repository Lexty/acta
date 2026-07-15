import Foundation

/// The once-a-second tick behind the menu bar's `HH:MM:SS` readout.
///
/// Split out of `RecordingController` because it is the one piece of that class with no bearing on
/// the recording itself: it owns a task and a start instant, and nothing it does can affect what
/// lands on disk. Keeping it separate means the controller's state is all recording state.
@MainActor
final class ElapsedTimer {
    private var task: Task<Void, Never>?

    /// Tick every second with the whole seconds elapsed since `origin`, until `stop()`.
    ///
    /// `origin` is passed in rather than captured as "now": the caller measures from the moment
    /// audio actually started flowing, which is several seconds after the user pressed Start.
    func start(from origin: Date, tick: @escaping @MainActor (Int) -> Void) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                tick(max(0, Int(Date().timeIntervalSince(origin))))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
