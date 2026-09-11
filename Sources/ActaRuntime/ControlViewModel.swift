import ActaKit
import SwiftUI

/// The UI-owned adapter between the SwiftUI menu and the `ControlAPI` façade.
///
/// The menu renders the `ControlState` this object publishes and calls its commands; it never touches
/// the recording controller (or anything below it). `MenuContent` owns one as a `@StateObject` — the
/// view creates it, so it must not be `@ObservedObject`.
///
/// Two hazards shape this type:
///
/// - **No blank first frame.** `state` is initialised **synchronously** from `ControlAPI.shared.state`
///   in `init`; a `Task` started here would not have run when SwiftUI first renders. The stream then
///   keeps it current.
/// - **Optimistic local title.** A `TextField` bound directly to the asynchronously-refreshed
///   `state.title` can revert characters or jump the cursor when an unrelated snapshot arrives
///   mid-typing. `titleText` is updated synchronously on every edit and written through the façade,
///   and while that write is unacknowledged incoming snapshots' `title` field is ignored (every other
///   field still applies).
@available(macOS 15.0, *)
@MainActor
public final class ControlViewModel: ObservableObject {
    private let api: ControlAPI

    /// The latest typed state the menu renders. Seeded synchronously so the first frame is not blank.
    @Published public private(set) var state: ControlState

    /// The title shown in the field — optimistic and local, updated synchronously on every keystroke.
    @Published public var titleText: String

    /// A title write not yet reflected back by the stream. While set, incoming snapshots' `title` is
    /// ignored (the local value stands); reconciliation resumes once a snapshot's title equals it.
    private var pendingTitle: String?

    public init(api: ControlAPI = .shared) {
        self.api = api
        let current = api.state
        state = current
        titleText = current.title
        microphone = api.microphoneStatus
    }

    /// Everything the microphone section renders. Refreshed from three places, and all three are
    /// needed: the microphone stream (device arrivals, the Mac's input moving, enforcement suspending),
    /// every controller state the façade publishes (`recordingFrom` lives on the controller, and no HAL
    /// event accompanies a recording starting or a watchdog adopting a device) and every microphone
    /// command.
    @Published public private(set) var microphone: ControlAPI.MicrophoneStatus

    /// A microphone the user has just picked, held locally until the status reflects it.
    ///
    /// ⚠️ **The optimistic value is the *request*, and it is never rendered as "recording from".** The
    /// same anti-clobber shape the title field uses, with one difference that matters: a title is true
    /// the moment it is typed, and a microphone is not true until capture succeeds on it. So this
    /// drives the selection tick, and `microphone.recordingFrom` — read from what actually came up —
    /// drives what the menu says is recording.
    @Published public private(set) var pendingSelection: String?

    /// Subscribe to the façade's state stream. Driven from the view's `.task {}` modifier, which
    /// cancels it when the menu closes — ending the `for await` so `AsyncStream.onTermination`
    /// unregisters the continuation. Repeated opens of the `.window` menu therefore do not accumulate
    /// subscriptions.
    public func subscribe() async {
        // ⚠️ **Two streams, both tied to this call's lifetime.** The menu's `.task {}` cancels it when
        // the menu closes, which ends both loops and unregisters both continuations — so repeated opens
        // do not accumulate subscriptions, which is the hazard the recording stream already documents.
        // Both streams are taken here, on the main actor, and iterated without isolation.
        let states = api.states()
        let statuses = api.microphoneStatuses()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await snapshot in states { await MainActor.run { self.apply(snapshot) } }
            }
            group.addTask {
                for await status in statuses { await MainActor.run { self.applyMicrophone(status) } }
            }
        }
    }

    /// Re-read the microphone status. Cheap — it is a projection over values the manager already holds.
    public func refreshMicrophone() { applyMicrophone(api.microphoneStatus) }

    private func applyMicrophone(_ next: ControlAPI.MicrophoneStatus) {
        // The request stands until what is actually in force matches it, exactly as `pendingTitle`
        // does for the title.
        if let pending = pendingSelection,
           next.override == pending || next.recordingFrom?.uid == pending || next.preferred == pending {
            pendingSelection = nil
        }
        microphone = next
    }


    // MARK: - Microphone commands

    /// Microphone commands run on **one queue per independent decision**, and that shape is the whole
    /// mechanism — two earlier versions of it were defects.
    ///
    /// ⚠️ **Unowned `Task`s around a two-stage change were a reentrancy bug one layer above the one
    /// Task 6 fixed.** Enable and disable each awaited a command and *then* wrote a captured `Bool`
    /// into settings: hold an Enable, complete an Off, release the Enable, and it persisted ON and
    /// wrote the system default again — after the user had turned it off. Ordering the saves was not
    /// enough, because the stale continuation is the part that publishes.
    ///
    /// ⚠️ **One queue for everything was the next defect, and a worse one.** Pause exists to withdraw
    /// permission to write *now*; queued behind a *Use now* that is parked on its verification deadline,
    /// it did not reach the reconciler until that pass had finished — and the pass then performed one
    /// more write. A revocation that waits for the operation it is meant to interrupt is not a
    /// revocation.
    ///
    /// ⚠️ **Per-decision queues were not enough either, and this is the correction.** Putting Enable,
    /// Resume, Off and Pause on one "management" queue still left a revocation waiting: Resume also
    /// awaits a full reconciliation, so an Off clicked while a Resume was parked did not reach the
    /// reconciler, and the released Resume then wrote a fallback device first. A revocation must be
    /// admitted independently of **any** slow granting operation, **including one of its own kind**.
    /// So revocations have their own queue and wait for nothing but each other.
    ///
    /// ⚠️ **And supersession is gone — with one asymmetric exception that is not it.** A symmetric
    /// "latest wins" counter shared across kinds meant an Off followed by a *Use now* discarded the Off
    /// entirely. That is removed. What remains is one-directional and stated as a rule rather than a
    /// race: **a revocation cancels grants issued before it; a grant never cancels a revocation.**
    /// Without it, an Enable still queued when the user clicks Off would run afterwards and switch
    /// management back on.
    private enum CommandQueue: Hashable {
        /// Granting: Enable, Resume. Both await reconciliation and can be slow.
        case grant
        /// Withdrawing: Off, Pause. Waits for nothing but other revocations.
        case revocation
        /// Which microphone Acta records from — *Use now*, *Resume automatic*.
        case selection
        /// The priority list. ⚠️ Two edits are **both** wanted and neither replaces the other, which is
        /// why they are ordered against each other and against nothing else.
        case priority
    }

    /// - Parameter withdrawingPermission: whether this command **takes back** permission to hold the
    ///   Mac's input, cancelling grants issued before it.
    ///   ⚠️ **Being on the revocation queue is not the same thing, and conflating them was a defect I
    ///   introduced.** Pause must be admitted immediately — that is what the queue is for — but it
    ///   *presupposes* enforcement: cancelling an Enable behind it left the feature **off** rather than
    ///   paused, persisted off, and made the following Resume resume nothing. Only switching the feature
    ///   off withdraws permission.
    private func enqueue(_ queue: CommandQueue,
                         withdrawingPermission: Bool = false,
                         _ body: @escaping @Sendable @MainActor () async -> Void) {
        // Bumped synchronously, at the moment the user acts — not when the command runs, which is the
        // whole point: the grant it cancels may not have started.
        if withdrawingPermission { revocations &+= 1 }
        let issuedAfter = revocations
        let previous = chains[queue]
        chains[queue] = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            // A grant issued before a revocation does not get to run after it.
            if queue == .grant, issuedAfter != revocations { return }
            await body()
            refreshMicrophone()
        }
    }

    private var chains: [CommandQueue: Task<Void, Never>] = [:]
    private var revocations: UInt64 = 0

    /// The one place this adapter writes settings — **one field at a time, merged into the
    /// authoritative value, with no suspension inside**.
    ///
    /// ⚠️ **The suspension was the defect, and it is the half a test can see.** A save carries every
    /// field and saving re-applies them, so a read-modify-write that suspends in the middle discards
    /// whatever landed during the hop: the first version awaited the enablement *after* copying the
    /// value, and a priority save overwrote a capture choice made after it — measured 15 times in 20 by
    /// a review, and reproduced here by putting the suspension back. Every statement below runs in one
    /// main-actor turn. That is why `ControlAPI.isMicrophoneManagementEnabled` had to become
    /// synchronous.
    ///
    /// ⚠️ **The field merge is belt and braces, and no test distinguishes it — that is recorded rather
    /// than implied away.** Writing the whole value back with only the enablement re-read passes every
    /// test in the suite; `RecordingSettings.merging` is kept because it is the anti-clobber primitive
    /// that already existed for exactly this question, and because a command writing only the field it
    /// owns cannot stamp a sibling field a different queue is responsible for. The reason the 20-in-20
    /// enable/edit loss is *not* evidence for this line: that was the seeding race, fixed in
    /// `MicrophoneReconciler.enable(seedingWith:)`.
    private func persist(_ field: RecordingSettings.Field) {
        api.settings = api.settings.merging(field)
        api.saveSettings()
    }

    /// *Use now* — one action with two effects, and the menu shows which of them landed.
    public func useMicrophoneNow(_ uid: String) {
        pendingSelection = uid
        enqueue(.selection) { [weak self] in await self?.api.useMicrophoneNow(uid: uid) }
    }

    public func resumeAutomaticMicrophoneSelection() {
        enqueue(.selection) { [weak self] in await self?.api.resumeAutomaticMicrophoneSelection() }
    }

    public func moveMicrophone(_ uid: String, up: Bool) {
        // ⚠️ **An intent, not a computed list.** Two clicks in one turn both used to read the same
        // cached order and each build a whole new list from it, so the second silently discarded the
        // first: adding two microphones persisted only one. The edit is applied to the *authoritative*
        // order at the moment it runs.
        editPriority { order in
            var order = order
            if !order.contains(uid) { order.append(uid) }
            guard let index = order.firstIndex(of: uid) else { return order }
            let target = up ? index - 1 : index + 1
            guard order.indices.contains(target) else { return order }
            order.swapAt(index, target)
            return order
        }
    }

    public func togglePreferred(_ uid: String) {
        editPriority { order in
            var order = order
            if let index = order.firstIndex(of: uid) { order.remove(at: index) } else { order.append(uid) }
            return order
        }
    }

    private func editPriority(_ edit: @escaping @Sendable ([String]) -> [String]) {
        enqueue(.priority) { [weak self] in
            guard let self else { return }
            // ⚠️ Read from the façade rather than the cached copy — also belt and braces, for the same
            // reason: the chain already guarantees the previous edit has published before this one
            // runs, and reading the cache instead fails no test. The authoritative read is what keeps
            // that true if the chain ever stops being the only path.
            let order = edit(api.microphoneStatus.priority)
            await api.setMicrophonePriority(order)
            let applied = api.microphoneStatus.priority
            persist(.microphonePriority(applied))
        }
    }

    public func setManagingSystemInput(_ on: Bool) {
        if !on {
            // ⚠️ **The revocation lands in the settings synchronously, at the moment the user acts.**
            // A queue is not enough, because a settings *save* is another granting path: an unrelated
            // command — a capture choice, a priority edit — merges its own field into a value that still
            // says `managesSystemDefaultInput = true`, and saving re-applies the whole value, which
            // re-enables the reconciler while the Off is still completing. Measured 20 runs in 20 by a
            // review. Writing the field here, before anything is enqueued, means every later merge
            // carries the withdrawal with it.
            persist(.managesSystemDefaultInput(false))
        }
        enqueue(on ? .grant : .revocation, withdrawingPermission: !on) { [weak self] in
            guard let self else { return }
            if on {
                await api.enableMicrophoneManagement()
                // ⚠️ Read back rather than replayed from the captured flag: an enable refused during
                // shutdown must persist as off, which a captured `true` could never express.
                persist(.managesSystemDefaultInput(api.isMicrophoneManagementEnabled))
                // The reconciler may have seeded an empty list; that order is the authoritative one.
                persist(.microphonePriority(api.microphoneStatus.priority))
            } else {
                await api.disableMicrophoneManagement()
                // ⚠️ **Not read back**, and the asymmetry is the point: disabling cannot be refused, so
                // there is nothing to learn from the mirror — while reading it is exactly how a
                // concurrent settings application that had re-enabled enforcement got written back as
                // though it were the user's decision. Off writes off.
                persist(.managesSystemDefaultInput(false))
            }
        }
    }

    public func pauseMicrophoneManagement() {
        enqueue(.revocation) { [weak self] in await self?.api.pauseMicrophoneManagement() }
    }

    public func resumeMicrophoneManagement() {
        enqueue(.grant) { [weak self] in await self?.api.resumeMicrophoneManagement() }
    }

    public func setCaptureChoice(_ choice: CaptureMicrophoneChoice) {
        api.setCaptureMicrophoneChoice(choice)
        persist(.captureMicrophoneChoice(choice))
        refreshMicrophone()
    }

    /// Reconcile an incoming snapshot with the optimistic local title.
    private func apply(_ snapshot: ControlState) {
        if let pending = pendingTitle {
            // The write is now reflected — resume reconciling `title`. Until then the local value
            // stands and a stale buffered snapshot cannot overwrite it.
            if snapshot.title == pending { pendingTitle = nil }
        } else {
            titleText = snapshot.title
        }
        state = snapshot
        // ⚠️ **The microphone status is refreshed here too, and removing this was a real regression.**
        // `recordingFrom` is read from the *controller* (`ControlAPI.microphoneStatus` takes it from
        // `controller.recordingMicrophone`), so it changes when a recording starts or stops and when the
        // watchdog adopts a different device — none of which is a CoreAudio `DeviceChange`, so
        // `microphoneStatuses()` never fires for any of them. With this line gone an open menu showed a
        // stale pin indefinitely: still naming a microphone after the recording had stopped.
        applyMicrophone(api.microphoneStatus)
    }

    // MARK: - Title

    /// Edit the title: set the local value synchronously and write it through the façade.
    private func setTitle(_ newValue: String) {
        titleText = newValue
        pendingTitle = newValue
        api.title = newValue
    }

    public var titleBinding: Binding<String> {
        Binding(get: { [weak self] in self?.titleText ?? "" },
                set: { [weak self] in self?.setTitle($0) })
    }

    // MARK: - Settings

    /// Merge one edited field into the **authoritative** current settings (never the lagging
    /// `state.settings` snapshot, which could clobber a recent sibling-field edit), then persist —
    /// reproducing today's save-on-change, including the normalisation `saveSettings()` applies.
    private func update(_ field: RecordingSettings.Field) {
        persist(field)
    }

    public var archivePathBinding: Binding<String> {
        Binding(get: { [weak self] in self?.api.settings.archivePath ?? "" },
                set: { [weak self] in self?.update(.archivePath($0)) })
    }

    public var segmentSecondsBinding: Binding<Int> {
        Binding(get: { [weak self] in self?.api.settings.segmentSeconds
                          ?? RecordingSettings.default.segmentSeconds },
                set: { [weak self] in self?.update(.segmentSeconds($0)) })
    }

    public var deleteSegmentsBinding: Binding<Bool> {
        Binding(get: { [weak self] in self?.api.settings.deleteSegmentsAfterAssembly
                          ?? RecordingSettings.default.deleteSegmentsAfterAssembly },
                set: { [weak self] in self?.update(.deleteSegmentsAfterAssembly($0)) })
    }

    // MARK: - Commands

    /// Start recording. The title written through `setTitle` is already the façade's `title`, so this
    /// starts with what the user typed — exactly as the field-bound `start()` does today.
    public func start() { api.start() }
    public func stop() { api.stop() }
    public func openArchive() { api.openArchive() }
    public func openInFinder(_ url: URL) { api.openInFinder(url) }
    public func dismissRecoveryNotice() { api.dismissRecoveryNotice() }
    /// Refresh the suggested title and recordings list — the controller's `onAppear()`.
    public func refresh() { api.refresh() }
}
