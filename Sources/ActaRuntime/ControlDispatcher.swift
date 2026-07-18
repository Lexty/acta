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
///
/// ⚠️ **`settingsSet` is the one command that takes a caller-supplied path, and Plan 2 has decided what
/// that means: `Confinement`.** `ControlRecordingLookup`'s rule — "the only thing a client may name is
/// an id it was given" — holds for `openInFinder`; `archive_path`, left alone, is written through
/// verbatim, so `settingsSet` + `refresh` + `list` would enumerate any readable directory and a later
/// `start` would record into it. That is exactly the authority the *menu* already has — fine in-process,
/// where the only client is the UI and a human is holding it — and it stops being equivalent the moment
/// a socket makes it a one-line request from any process. So the dispatcher is **configured** at
/// construction: a `.trusted` (in-process) dispatcher is unrestricted, while a `.socket` dispatcher
/// **ignores the wire `archive_path` and substitutes the current authoritative one** on `settingsSet`
/// (ignore-and-substitute, not a path compare — race-free and free of spelling ambiguity), and rejects
/// any over-long or control-character-bearing command-payload string (`ControlStringPolicy`) — the
/// strings a command carries into recorder state, not the envelope's echo-only correlation id or an
/// unknown-tag discriminator, both of which are round-tripped verbatim and already framing-bounded.
/// Because the socket
/// can never make the in-memory `archivePath` anything but the current one, `settingsSave` persisting
/// the current settings can never persist a smuggled path — no separate guard is needed there.
@available(macOS 15.0, *)
@MainActor
public final class ControlDispatcher: ControlRequestHandling {
    /// How much authority this dispatcher grants its client — the whole of Plan 2's settings policy.
    public enum Confinement: Sendable {
        /// The in-process UI. Unrestricted: a human relocating their own archive is fine.
        case trusted
        /// A socket client. Cannot relocate the archive; every caller-supplied command-payload string is
        /// bounded and validated.
        case socket
    }

    private let service: any ControlServing
    private let confinement: Confinement

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
    /// as its final act, inside its own body, before any awaiter resumes (`awaitAbandonably` waits on
    /// `task.value`, which completes only after the assignment).
    ///
    /// ⚠️ **The window that leaves open, stated rather than denied.** `await service.stopAndWait()` is a
    /// main-actor suspension point: other main-actor jobs run between the callee returning and
    /// `finalisation = nil` executing. In that gap the slot is non-nil while its stop is already
    /// finished, so a `stopAndWait` arriving there joins a spent task and returns having stopped
    /// nothing. It only *matters* if a new recording started in that same gap — otherwise the
    /// `hasWorkInFlight` guard turns it away and the answer is right anyway. An identity check here
    /// would not close it: a joiner in that window finds the slot occupied by the very task that put it
    /// there, so any comparison passes. Closing it properly means re-checking `hasWorkInFlight` after
    /// the join and minting a fresh stop — which changes what `stopAndWait` promises (it would then
    /// stop a recording that began after the request arrived) and belongs in a plan, not a comment.
    /// Accepted as-is: it needs a stop to finish, a start to land, and a `stopAndWait` to arrive, all
    /// inside one scheduling gap.
    private var finalisation: Task<Void, Never>?

    /// - Parameters:
    ///   - service: the recorder. Production passes `ControlAPI.shared` — the menu's own controller,
    ///     per the privacy invariant. A test passes a fake.
    ///   - confinement: `.trusted` for the in-process UI (the default), `.socket` for a dispatcher a
    ///     socket transport hands untrusted requests.
    public init(service: any ControlServing, confinement: Confinement = .trusted) {
        self.service = service
        self.confinement = confinement
    }

    // MARK: - Dispatch

    // One switch over the closed command algebra: an added command fails to compile here rather than
    // going quietly unanswered.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func handle(_ command: Command) async -> ControlResponse {
        // A torn-down connection must not still mutate the recorder. `teardown()` (an orderly quit)
        // cancels every connection task, but cancellation is cooperative and `ControlConnection` does not
        // re-check it between reading a frame and dispatching it — so a buffered command can reach here
        // after teardown returned. This is the last gate, and it is reliable here: teardown cancels every
        // task synchronously on the main actor before yielding, so this dispatch — running on that same
        // now-cancelled task — observes `Task.isCancelled`. Without it a buffered `.start` could begin a
        // recording during quit finalisation, the very window the quit-time teardown exists to close.
        if Task.isCancelled {
            return .error(.commandRejected(reason: Rejection.closing))
        }
        // A `.socket` dispatcher validates every caller-supplied string before the command is acted on,
        // so an over-long or control-character title can never reach the recorder's state. `.trusted`
        // (the UI) skips this: it never drives an adversarial string.
        if let rejection = wireStringRejection(in: command) {
            return .error(rejection)
        }
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
                return .error(Self.refusalToStop(service.state))
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
            service.settings = appliedSettings(from: wire)
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
        /// A `stop` during the startup probe.
        public static let starting = "the recording is still starting"
        /// A `stop` while the assembly is already running.
        public static let saving = "a stop is already in flight"
        /// A command whose delivering connection was torn down before it could be acted on — the app
        /// quitting cancels every connection task (see `handle`).
        public static let closing = "the control connection is closing"
    }

    /// Why a `stop` was refused — and specifically **when `not_recording` is a true statement**.
    ///
    /// The controller stops only from `phase == .recording`, so a `stop` outside it is refused either
    /// way; what is not free is *which* refusal. `not_recording`'s frozen message is "There is no
    /// recording in progress.", and during `.starting` that is simply false — the frozen controller
    /// contract has capture already writing segments while the startup probe runs, and `.saving` means a
    /// stop already happened. Answering either with `not_recording` tells a client that the recording it
    /// just started does not exist, contradicting the `.starting` the same dispatcher projected a turn
    /// earlier and inviting it to walk away from a recording that keeps running to disk. It also split
    /// `stop` from `stop_and_wait`, which guards on `hasWorkInFlight` and gets this right. So the code is
    /// reserved for the one state it describes — nothing in flight — and the other two are
    /// `command_rejected` with a reason that names the state rather than denying it.
    private static func refusalToStop(_ state: ControlState) -> WireError {
        switch state.operation {
        case .idle: return .notRecording()
        case .starting: return .commandRejected(reason: Rejection.starting)
        case .saving: return .commandRejected(reason: Rejection.saving)
        case .recording: return .notRecording() // unreachable: `canStop` is exactly this case.
        }
    }

    private var wireState: WireControlState { WireControlState(state: service.state) }

    // MARK: - Confinement policy

    /// The settings a `settingsSet` actually applies. A `.socket` dispatcher **ignores** the wire
    /// `archive_path` and substitutes the current authoritative one, read on this same main-actor turn;
    /// only `segmentSeconds`/`deleteSegmentsAfterAssembly` come from the wire. A `.trusted` dispatcher
    /// takes the wire settings whole, exactly as the menu's bindings do.
    private func appliedSettings(from wire: WireSettings) -> RecordingSettings {
        var applied = RecordingSettings(wire)
        if confinement == .socket {
            applied.archivePath = service.settings.archivePath
        }
        return applied
    }

    /// For a `.socket` dispatcher, the first caller-supplied string in `command` that
    /// `ControlStringPolicy` rejects, as a `bad_request` naming the offending field; `nil` when every
    /// string is acceptable or the dispatcher is `.trusted`.
    private func wireStringRejection(in command: Command) -> WireError? {
        guard confinement == .socket else { return nil }
        func check(_ field: String, _ value: String?) -> WireError? {
            guard let value, let rejection = ControlStringPolicy.validate(value) else { return nil }
            return .badRequest(reason: Self.reason(field: field, rejection))
        }
        switch command {
        case .start(let title): return check("title", title)
        case .titleSet(let title): return check("title", title)
        case .openInFinder(let id): return check("id", id)
        default: return nil
        }
    }

    private static func reason(field: String, _ rejection: ControlStringPolicy.Rejection) -> String {
        switch rejection {
        case .tooLong(let max): return "\(field) exceeds \(max) characters"
        case .controlCharacter: return "\(field) contains a control character"
        }
    }

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
            // The body clears the dispatcher's reference as its final act, *before* resuming any
            // awaiter, so the "cleared when it completes" rule holds without a second observer task
            // whose ordering against the awaiters would be a race. The task cannot begin before this
            // synchronous region suspends, so `finalisation` is assigned by the time the body reads it —
            // and since a second task can only be minted once this one has cleared the slot, the task
            // running here is always the one in it. See `finalisation` for the one window this leaves.
            let created = Task { @MainActor [weak self, service] in
                await service.stopAndWait()
                self?.finalisation = nil
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
