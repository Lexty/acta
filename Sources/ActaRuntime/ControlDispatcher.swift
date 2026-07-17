import ActaControlProtocol
import ActaKit
import Foundation

/// What handling one decoded command produced: a result, an error, or — for `watch` alone — a stream of
/// events the transport writes until the client goes away.
@available(macOS 15.0, *)
public enum ControlResponse: Sendable {
    case result(CommandResult)
    case error(WireError)
    case events(AsyncStream<WatchEvent>)
}

/// The abstraction the **future transport depends on** — deliberately not the concrete
/// `ControlDispatcher` and emphatically not `ControlAPI.shared`.
///
/// Plan 2's socket code is descriptor work: `flock`, `sockaddr_un`, `SO_NOSIGPIPE`, non-blocking I/O.
/// Nothing there should be able to reach the recorder, and a socket test should be able to answer "did
/// the bytes arrive and did the reply go back out" against a handler that records commands and returns
/// canned results. That is only possible if the transport names *this*, so the seam is introduced here,
/// with the dispatcher, rather than retrofitted once the descriptor code already knows the singleton.
@available(macOS 15.0, *)
@MainActor
public protocol ControlRequestHandling: AnyObject {
    /// Handle one decoded command.
    func handle(_ command: Command) async -> ControlResponse
}

/// The command dispatcher: a decoded `Command` becomes a `ControlServing` call and a wire result.
///
/// This is where the transport-facing **policy** lives, and each rule below is load-bearing:
///
/// - **A busy `start` is rejected before the recorder is touched.** `ControlAPI.start(title:)` sets the
///   title and *then* calls `start()`, whose guard no-ops when busy — so a naive forward would edit the
///   title of a live recording and answer as if nothing happened. The guard is checked here, on the
///   same main-actor turn, and the command is refused with `command_rejected`.
/// - **Answers are honest about *when*.** `start` returns "accepted, here is the state right now" — not
///   "capture started"; capture may not be live for another turn, and `ControlState` says so
///   (`.starting`). `stop` returns "stop initiated". Only `stopAndWait` claims completion, and it earns
///   the claim by awaiting one.
/// - **`status`/`list` never call `refresh()`.** A read that mutates is a read a client cannot poll.
/// - **`openInFinder` resolves an opaque id, never a path.**
@available(macOS 15.0, *)
@MainActor
public final class ControlDispatcher: ControlRequestHandling {
    private let service: any ControlServing

    /// The finalisation currently in flight, if any — the whole of `stopAndWait`'s ownership model.
    ///
    /// ⚠️ **Why it is stored at all.** The stop must outlive the request that asked for it: a client
    /// that hits its timeout, or drops the connection, must not abort the assembly of a real recording.
    /// So the finalisation runs in an **unstructured** `Task` that belongs to the dispatcher, and a
    /// request merely `await`s its value. Cancelling a request cancels *only that await* (see
    /// `awaitAbandonably`); the task itself is never cancelled by anyone.
    ///
    /// ⚠️ **Why it is cleared on completion.** Concurrent `stopAndWait`s for the *same* stop must share
    /// one task (one underlying stop, one answer). But a *later* recording's `stopAndWait` must not
    /// reuse a completed task and return instantly having stopped nothing — so the task clears itself
    /// as its final act, inside its own body, before any awaiter resumes. A stale hit is therefore not
    /// merely unlikely; it is unreachable.
    private var finalisation: Task<Void, Never>?
    /// Identifies the current finalisation so the task clears only *itself*.
    private var finalisationID: UUID?

    /// - Parameter service: the recorder. Production passes `ControlAPI.shared` — the menu's own
    ///   controller, per the privacy invariant. A test passes a fake.
    public init(service: any ControlServing) {
        self.service = service
    }

    // MARK: - Dispatch

    // One switch over the closed command algebra: an added command fails to compile here rather than
    // going quietly unanswered.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func handle(_ command: Command) async -> ControlResponse {
        switch command {
        case .status:
            // A snapshot, and nothing else — deliberately no `refresh()`.
            return .result(.state(wireState))

        case .list:
            return .result(.recordings(service.state.recordings.map(RecordingSummary.init)))

        case .watch:
            return .events(watchEvents())

        case .start(let title):
            // The guard, before `start(title:)` can edit the title. Same turn, no `await` in between.
            guard service.state.canStart else {
                return .error(.commandRejected(reason: Rejection.busy))
            }
            service.start(title: title)
            // "Accepted", with the state as it is right now. Not "recording".
            return .result(.state(wireState))

        case .stop:
            guard service.state.canStop else {
                return .error(.notRecording())
            }
            service.stop()
            // "Stop initiated". The assembly is still ahead; the state says `.saving` when it starts.
            return .result(.state(wireState))

        case .stopAndWait:
            await stopAndWait()
            return .result(.state(wireState))

        case .recover:
            service.recover()
            return .result(.ok)

        case .refresh:
            service.refresh()
            return .result(.ok)

        case .openArchive:
            service.openArchive()
            return .result(.ok)

        case .openInFinder(let id):
            guard let recording = ControlRecordingLookup.recording(forID: id,
                                                                   in: service.state.recordings) else {
                return .error(.unknownRecording(id: id))
            }
            service.openInFinder(recording.directory)
            return .result(.ok)

        case .settingsGet:
            return .result(.settings(WireSettings(service.settings)))

        case .settingsSet(let wire):
            service.settings = RecordingSettings(wire)
            return .result(.ok)

        case .settingsSave:
            service.saveSettings()
            return .result(.ok)

        case .titleGet:
            return .result(.title(service.title))

        case .titleSet(let title):
            service.title = title
            return .result(.ok)

        case .dismissRecoveryNotice:
            service.dismissRecoveryNotice()
            return .result(.ok)

        case .unsupportedCommand(let raw):
            // The reason `Command` decodes an unknown tag to data instead of throwing: it gets answered.
            return .error(.unsupportedCommand(raw: raw))
        }
    }

    /// The rejection reasons this dispatcher can produce. Named constants for the same reason
    /// `ControllerMessage` exists: a `reason` a client branches on must have exactly one writer.
    public enum Rejection {
        /// A `start` while the recorder is not idle.
        public static let busy = "a recording is already in flight"
    }

    private var wireState: WireControlState { WireControlState(state: service.state) }

    // MARK: - stopAndWait

    private func stopAndWait() async {
        // Nothing recording, starting or saving: there is no finalisation to create or to join, and
        // creating one would stop nothing while parking a task in `finalisation` for the next caller to
        // trip over. Answer with the current state.
        guard service.state.hasWorkInFlight else { return }

        let task: Task<Void, Never>
        if let existing = finalisation {
            // A stop is already in flight — join it. One stop, one answer, however many clients ask.
            task = existing
        } else {
            let id = UUID()
            finalisationID = id
            // The body clears the dispatcher's reference as its final act, *before* resuming any
            // awaiter, so the "cleared when it completes" rule holds without a second observer task
            // whose ordering against the awaiters would be a race. The task cannot begin before this
            // synchronous region suspends, so `finalisation` is assigned by the time the body reads it.
            let created = Task { @MainActor [weak self, service] in
                await service.stopAndWait()
                guard let self, self.finalisationID == id else { return }
                self.finalisation = nil
                self.finalisationID = nil
            }
            finalisation = created
            task = created
        }
        await awaitAbandonably(task)
    }

    /// Await a task's completion, abandoning the wait — and only the wait — if *this* task is cancelled.
    ///
    /// `await task.value` on a `Task<Void, Never>` is not cancellable: a client that gave up would keep
    /// a request suspended until the assembly finished. Racing the wait against cancellation is what
    /// makes "a timeout cancels only its own await" true rather than aspirational. The awaited task is
    /// never cancelled here, by construction — there is no `cancel()` call in this type at all.
    private func awaitAbandonably(_ task: Task<Void, Never>) async {
        let resumer = SingleResume()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                resumer.arm(continuation)
                Task { @MainActor in
                    await task.value
                    resumer.fire()
                }
            }
        } onCancel: {
            resumer.fire()
        }
    }

    // MARK: - watch

    /// The `watch` event stream.
    ///
    /// **The initial event is the first element of `states()`**, not a separate read of `state`. Reading
    /// `state` and *then* subscribing has two failure modes — a duplicate if nothing changed, a missed
    /// transition if something did — and `ControlAPI.states()` already replays the current state inside
    /// the same main-actor turn it registers in. So the loop below simply treats element one as the
    /// initial event; there is no ordering gap to close because there is no second step.
    ///
    /// ⚠️ **Transport coalescing, which is not `states()`'s sampling contract.** `states()` buffers
    /// **unbounded**, on the reasoning that nothing it sampled should be dropped. That reasoning does
    /// not survive a socket: a client that stops reading turns an unbounded buffer into unbounded
    /// memory held by a process that must never fall over mid-recording. So a bounded primitive sits
    /// between the two — `bufferingNewest(1)`, a single slot holding the newest pending state, older
    /// pending states replaced. For a state feed that is the right loss: a stale state has no value
    /// once a newer one exists.
    ///
    /// **The `sequence` is assigned before coalescing**, which is what keeps that loss honest: a client
    /// receiving 1 then 4 is *told* that two states it never saw existed, rather than being handed a
    /// gapless-looking sequence that quietly lies about the history.
    private func watchEvents() -> AsyncStream<WatchEvent> {
        let upstream = service.states()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let pump = Task { @MainActor in
                var sequence = 0
                for await state in upstream {
                    sequence += 1
                    continuation.yield(WatchEvent(sequence: sequence,
                                                  state: WireControlState(state: state)))
                }
                continuation.finish()
            }
            // The client went away (its iterator was dropped or its task cancelled): stop pumping and
            // let the upstream subscription terminate. Without this the pump would outlive every reader.
            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}

/// A continuation that is resumed exactly once, whichever of the two racers gets there first.
///
/// Resuming a `CheckedContinuation` twice traps, and both the completion and the cancellation paths of
/// `awaitAbandonably` legitimately try. A lock rather than actor isolation: `onCancel` runs
/// synchronously on whatever thread cancelled, with no isolation of its own to borrow.
private final class SingleResume: @unchecked Sendable {
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
