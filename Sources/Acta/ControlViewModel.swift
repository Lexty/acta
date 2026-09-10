import ActaKit
import ActaRuntime
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
final class ControlViewModel: ObservableObject {
    private let api: ControlAPI

    /// The latest typed state the menu renders. Seeded synchronously so the first frame is not blank.
    @Published private(set) var state: ControlState

    /// The title shown in the field — optimistic and local, updated synchronously on every keystroke.
    @Published var titleText: String

    /// A title write not yet reflected back by the stream. While set, incoming snapshots' `title` is
    /// ignored (the local value stands); reconciliation resumes once a snapshot's title equals it.
    private var pendingTitle: String?

    init(api: ControlAPI = .shared) {
        self.api = api
        let current = api.state
        state = current
        titleText = current.title
        microphone = api.microphoneStatus
    }

    /// Everything the microphone section renders. Refreshed on every state the façade publishes and on
    /// every microphone command, which is what the menu already does for the recording state.
    @Published private(set) var microphone: ControlAPI.MicrophoneStatus

    /// A microphone the user has just picked, held locally until the status reflects it.
    ///
    /// ⚠️ **The optimistic value is the *request*, and it is never rendered as "recording from".** The
    /// same anti-clobber shape the title field uses, with one difference that matters: a title is true
    /// the moment it is typed, and a microphone is not true until capture succeeds on it. So this
    /// drives the selection tick, and `microphone.recordingFrom` — read from what actually came up —
    /// drives what the menu says is recording.
    @Published private(set) var pendingSelection: String?

    /// Subscribe to the façade's state stream. Driven from the view's `.task {}` modifier, which
    /// cancels it when the menu closes — ending the `for await` so `AsyncStream.onTermination`
    /// unregisters the continuation. Repeated opens of the `.window` menu therefore do not accumulate
    /// subscriptions.
    func subscribe() async {
        for await snapshot in api.states() {
            apply(snapshot)
            refreshMicrophone()
        }
    }

    /// Re-read the microphone status. Cheap — it is a projection over values the manager already holds.
    func refreshMicrophone() {
        let next = api.microphoneStatus
        // The request stands until what is actually in force matches it, exactly as `pendingTitle`
        // does for the title.
        if let pending = pendingSelection,
           next.override == pending || next.recordingFrom?.uid == pending || next.preferred == pending {
            pendingSelection = nil
        }
        microphone = next
    }

    // MARK: - Microphone commands

    /// *Use now* — one action with two effects, and the menu shows which of them landed.
    func useMicrophoneNow(_ uid: String) {
        pendingSelection = uid
        Task {
            await api.useMicrophoneNow(uid: uid)
            refreshMicrophone()
        }
    }

    func resumeAutomaticMicrophoneSelection() {
        Task {
            await api.resumeAutomaticMicrophoneSelection()
            refreshMicrophone()
        }
    }

    func moveMicrophone(_ uid: String, up: Bool) {
        var order = microphone.priority
        if !order.contains(uid) { order.append(uid) }
        guard let index = order.firstIndex(of: uid) else { return }
        let target = up ? index - 1 : index + 1
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        setPriority(order)
    }

    func togglePreferred(_ uid: String) {
        var order = microphone.priority
        if let index = order.firstIndex(of: uid) { order.remove(at: index) } else { order.append(uid) }
        setPriority(order)
    }

    private func setPriority(_ order: [String]) {
        Task {
            await api.setMicrophonePriority(order)
            var settings = api.settings
            settings.microphonePriority = order
            api.settings = settings
            api.saveSettings()
            refreshMicrophone()
        }
    }

    func setManagingSystemInput(_ on: Bool) {
        Task {
            if on { await api.enableMicrophoneManagement() } else { await api.disableMicrophoneManagement() }
            var settings = api.settings
            settings.managesSystemDefaultInput = on
            settings.microphonePriority = api.microphoneStatus.priority
            api.settings = settings
            api.saveSettings()
            refreshMicrophone()
        }
    }

    func pauseMicrophoneManagement() {
        Task { await api.pauseMicrophoneManagement(); refreshMicrophone() }
    }

    func resumeMicrophoneManagement() {
        Task { await api.resumeMicrophoneManagement(); refreshMicrophone() }
    }

    func setCaptureChoice(_ choice: CaptureMicrophoneChoice) {
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

    var titleBinding: Binding<String> {
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

    var archivePathBinding: Binding<String> {
        Binding(get: { [weak self] in self?.api.settings.archivePath ?? "" },
                set: { [weak self] in self?.update(.archivePath($0)) })
    }

    var segmentSecondsBinding: Binding<Int> {
        Binding(get: { [weak self] in self?.api.settings.segmentSeconds
                          ?? RecordingSettings.default.segmentSeconds },
                set: { [weak self] in self?.update(.segmentSeconds($0)) })
    }

    var deleteSegmentsBinding: Binding<Bool> {
        Binding(get: { [weak self] in self?.api.settings.deleteSegmentsAfterAssembly
                          ?? RecordingSettings.default.deleteSegmentsAfterAssembly },
                set: { [weak self] in self?.update(.deleteSegmentsAfterAssembly($0)) })
    }

    // MARK: - Commands

    /// Start recording. The title written through `setTitle` is already the façade's `title`, so this
    /// starts with what the user typed — exactly as the field-bound `start()` does today.
    func start() { api.start() }
    func stop() { api.stop() }
    func openArchive() { api.openArchive() }
    func openInFinder(_ url: URL) { api.openInFinder(url) }
    func dismissRecoveryNotice() { api.dismissRecoveryNotice() }
    /// Refresh the suggested title and recordings list — the controller's `onAppear()`.
    func refresh() { api.refresh() }
}
