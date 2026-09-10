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

    /// Everything the microphone section renders. Refreshed on every state the façade publishes and on
    /// every microphone command, which is what the menu already does for the recording state.
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

    /// Every microphone command runs here, **in order**, and each checks whether it is still the
    /// user's current intent before publishing or persisting anything.
    ///
    /// ⚠️ **Unowned `Task`s around a two-stage change were a reentrancy bug one layer above the one
    /// Task 6 fixed.** Enable and disable each awaited a command and *then* wrote a captured `Bool`
    /// into settings: hold an Enable, complete an Off, release the Enable, and it persisted ON and
    /// wrote the system default again — after the user had turned it off. Ordering the saves was not
    /// enough, because the stale continuation is the part that publishes.
    private func command(_ body: @escaping @Sendable @MainActor () async -> Void) {
        enqueue(supersedes: false, body)
    }

    /// A command whose **latest** value is the user's intent: switching management on and then off is
    /// one decision, not two to be applied in turn.
    ///
    /// ⚠️ **Not the same as a priority edit**, which is what my first version got wrong: one counter
    /// for everything meant a second click cancelled the first, so adding two microphones persisted
    /// only the second — the same loss as the stale-base bug it replaced, arriving from the other
    /// direction. Superseding is right when a later value *replaces* an earlier one and wrong when both
    /// are wanted.
    private func exclusiveCommand(_ body: @escaping @Sendable @MainActor () async -> Void) {
        enqueue(supersedes: true, body)
    }

    private func enqueue(supersedes: Bool, _ body: @escaping @Sendable @MainActor () async -> Void) {
        if supersedes { exclusiveIntent &+= 1 }
        let mine = exclusiveIntent
        let previous = commandChain
        commandChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            // A superseded command publishes and persists nothing; a queued edit always runs.
            //
            // ⚠️ **The queue is what fixes the reported bug, and this check is belt and braces.** With
            // commands chained, an Off cannot overtake an Enable and its continuation cannot run out of
            // order, so removing this line fails no test — I checked. It is kept because superseding is
            // the right meaning for a switch, and a future path that does not go through the chain would
            // need it; it is recorded as undistinguished rather than implied to be load-bearing.
            guard !supersedes || mine == exclusiveIntent else { return }
            await body()
            refreshMicrophone()
        }
    }

    private var exclusiveIntent: UInt64 = 0
    private var commandChain: Task<Void, Never>?

    /// *Use now* — one action with two effects, and the menu shows which of them landed.
    public func useMicrophoneNow(_ uid: String) {
        pendingSelection = uid
        exclusiveCommand { [weak self] in await self?.api.useMicrophoneNow(uid: uid) }
    }

    public func resumeAutomaticMicrophoneSelection() {
        exclusiveCommand { [weak self] in await self?.api.resumeAutomaticMicrophoneSelection() }
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
        command { [weak self] in
            guard let self else { return }
            // ⚠️ Read from the façade rather than the cached copy — also belt and braces, for the same
            // reason: the chain already guarantees the previous edit has published before this one
            // runs, and reading the cache instead fails no test. The authoritative read is what keeps
            // that true if the chain ever stops being the only path.
            let order = edit(api.microphoneStatus.priority)
            await api.setMicrophonePriority(order)
            var settings = api.settings
            settings.microphonePriority = api.microphoneStatus.priority
            api.settings = settings
            api.saveSettings()
        }
    }

    public func setManagingSystemInput(_ on: Bool) {
        exclusiveCommand { [weak self] in
            guard let self else { return }
            if on { await api.enableMicrophoneManagement() } else { await api.disableMicrophoneManagement() }
            var settings = api.settings
            // ⚠️ Read back rather than replayed from the captured flag: what was actually applied is
            // what gets persisted.
            let status = api.microphoneStatus
            settings.managesSystemDefaultInput = status.managingSystemInput
            settings.microphonePriority = status.priority
            api.settings = settings
            api.saveSettings()
        }
    }

    public func pauseMicrophoneManagement() {
        command { [weak self] in await self?.api.pauseMicrophoneManagement() }
    }

    public func resumeMicrophoneManagement() {
        command { [weak self] in await self?.api.resumeMicrophoneManagement() }
    }

    public func setCaptureChoice(_ choice: CaptureMicrophoneChoice) {
        api.setCaptureMicrophoneChoice(choice)
        var settings = api.settings
        settings.captureMicrophoneChoice = choice
        api.settings = settings
        api.saveSettings()
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
        api.settings = api.settings.merging(field)
        api.saveSettings()
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
