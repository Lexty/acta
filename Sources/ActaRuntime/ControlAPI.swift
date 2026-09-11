import ActaKit
import Combine
import Foundation

/// The typed, observable boundary over the recording pipeline — a **façade**, not a replacement.
///
/// It wraps an unchanged `RecordingController`: the same object the SwiftUI menu talks to, whose
/// lifecycle is frozen by `RecordingControllerLifecycleTests` / `RecordingControllerGuardTests`. Every
/// command below forwards to that controller and every state it publishes is
/// `ControlState(from:)` over a snapshot of the controller's own published fields, so the façade
/// cannot drift from the behaviour those contracts froze — there is nothing here for it to drift *to*.
///
/// ⚠️ **Privacy invariant: a recording is always visible in the UI.** `ControlAPI.shared` wraps
/// `RecordingController.shared` — the menu's own instance — and that is *why* it must. A façade over a
/// second controller would record into the archive while the menu, still reading `.shared`, showed
/// nothing: an API-initiated recording no one on the machine could see. A test therefore never touches
/// `.shared` (it reaches for the real `~/Acta`, real TCC and real time) and injects its own controller
/// instead; production never constructs a second one.
@available(macOS 15.0, *)
@MainActor
public final class ControlAPI {
    private let controller: RecordingController
    private var cancellables: Set<AnyCancellable> = []
    private var continuations: [UUID: AsyncStream<ControlState>.Continuation] = [:]
    /// The last state handed to the subscribers — dedupe memory only, never a source of truth. `state`
    /// is always recomputed from the controller; this exists so an `objectWillChange` fire that changes
    /// nothing the typed state can see (a private field, an identical rewrite) does not emit.
    private var lastPublished: ControlState

    /// Microphone management: the device inventory, and feature (B)'s enforcement of the system
    /// default input.
    ///
    /// ⚠️ **It hangs here because this is the route the menu already has**, not because a façade over
    /// the recording pipeline naturally owns audio-device policy. The alternative was a second global
    /// the UI would have to reach for directly, which is how two sources of truth start. The manager
    /// itself owns nothing of the recorder and the recorder owns nothing of it; `ControlAPI` is the
    /// place they are handed to the same client.
    ///
    /// ⚠️ Its state is **not** folded into `ControlState` yet, and the reason is scheduling, not
    /// necessity. `WireProjection` selects the fields it projects explicitly, so a runtime-only field on
    /// `ControlState` would *not* by itself change the wire — the earlier claim that it forced a
    /// protocol bump was wrong. What is true is that the aggregation and the wire fields belong in one
    /// change with the fixtures they invalidate, which is Task 6 of the microphone plan. Until then the
    /// menu reads `microphone` directly.
    public let microphone: MicrophoneManager

    /// The production façade. Wraps the menu's controller — see the privacy invariant above.
    public static let shared = ControlAPI(controller: .shared, microphone: .shared)

    /// - Parameter controller: the controller to wrap. Production passes `.shared`; a test passes one
    ///   built with the injected seams.
    /// - Parameter microphone: the app-lifetime microphone owner. Production passes `.shared`; a test
    ///   passes one built over a fake directory. ⚠️ Not a default argument, for the reason
    ///   `RecordingDependencies` is not one: a default argument is a wiring claim no test can read back.
    public init(controller: RecordingController, microphone: MicrophoneManager) {
        self.controller = controller
        self.microphone = microphone
        lastPublished = ControlState(from: ControlAPI.snapshot(of: controller))
        observe()
    }

    // MARK: - State

    /// The current typed state — mapped fresh from the controller on every read, which is what makes it
    /// the one source of truth `states()` replays rather than a second, drifting copy.
    public var state: ControlState { ControlState(from: ControlAPI.snapshot(of: controller)) }

    /// A stream of typed states: the current one first, then every distinct state observation settles on.
    ///
    /// **The guarantee, stated as what sampling can actually prove — no more:**
    ///
    /// - **Replay is atomic.** The continuation is registered and the current state yielded inside the
    ///   same main-actor turn, so there is no fetch-then-subscribe gap for a transition to fall into.
    /// - **Ordered and distinct.** Every subscriber sees the same states in the same order; a state
    ///   equal to the previous one is not re-emitted.
    /// - **The dangerous transitions are visible**, including a normal `.saving`: `stop()` sets the
    ///   stop-in-flight flag synchronously before the assembly's first `await`, so the state is already
    ///   `.saving` when the observation samples it.
    ///
    /// ⚠️ **It is not lossless, and does not pretend to be.** `RecordingController` is unchanged, so
    /// the only signal available is `objectWillChange` — which fires *before* the value lands and names
    /// neither the property nor its new value. The façade therefore *samples*: synchronously (settling
    /// the previous change) and again one main-actor turn later (settling this one), exactly as
    /// `ControllerTestSupport`'s recorder does. Buffering is unbounded, so nothing the façade *did*
    /// sample is dropped — but unbounded buffering cannot recover a state that was never sampled, and
    /// no claim here rests on it doing so.
    ///
    /// ⚠️ **A yielded state is not necessarily one the controller settled on.** Several mutations in one
    /// turn do *not* collapse: the synchronous sample runs per `objectWillChange`, so a turn that writes
    /// two fields is sampled between them and yields the half-applied state in between. `start(title:)`
    /// on a controller showing a recovery banner really does yield `.starting` *with* the banner before
    /// yielding `.starting` without it, and a retry after a failed start yields `.starting` still
    /// carrying the previous `lifecycleFailure`. These are real intermediate states of a real object,
    /// not fabrications — but a consumer that renders every state verbatim will show them, and one that
    /// needs only settled states must debounce to the end of the turn itself.
    public func states() -> AsyncStream<ControlState> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            // Runs synchronously inside `AsyncStream.init`, on the main actor: register and replay
            // without ever leaving the turn.
            MainActor.assumeIsolated { register(continuation) }
        }
    }

    private func register(_ continuation: AsyncStream<ControlState>.Continuation) {
        let id = UUID()
        continuations[id] = continuation
        let current = state
        if current == lastPublished {
            continuation.yield(current)
        } else {
            // The sampler has not caught up with a change that already landed. Yielding to everyone —
            // the new subscriber included — keeps the single ordered sequence single: a state replayed
            // to one subscriber and withheld from the rest is two histories.
            publish(current)
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.continuations[id] = nil }
        }
    }

    private func observe() {
        controller.objectWillChange.sink { [weak self] _ in
            // `@Published` publishes from the setter and every one of the controller's setters runs on
            // the main actor, so this callback does too.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Two samples per fire, for the reason `ControllerStateLog` takes two: this one reads
                // the state the *previous* change settled into (`objectWillChange` precedes the write),
                // which is what makes a window opened at one change and closed at a later one
                // observable without scheduling luck…
                self.publish(self.state)
                // …and this one reads the state *this* change settles into — the last change of all has
                // no later fire to report it.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.publish(self.state)
                }
            }
        }.store(in: &cancellables)
    }

    private func publish(_ current: ControlState) {
        guard current != lastPublished else { return }
        lastPublished = current
        for continuation in continuations.values { continuation.yield(current) }
    }

    /// End every stream `states()` handed out. Not a `deinit`: this type is a `@MainActor` singleton in
    /// production and nothing ever tears it down, while a test needs its collector's `for await` loop to
    /// finish at a point in its own timeline rather than whenever a deallocation happens to run.
    public func finish() {
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    private static func snapshot(of controller: RecordingController) -> ControllerSnapshot {
        // `isSaving`, never the controller's `isStopping`: that field is `@Published private`, and the
        // public flag already folds it in (see `ControllerSnapshot`).
        ControllerSnapshot(phase: controller.phase,
                           isStarting: controller.isStarting,
                           isSaving: controller.isSaving,
                           errorMessage: controller.errorMessage,
                           recoveredBanner: controller.recoveredBanner,
                           title: controller.title,
                           suggestedTitle: controller.suggestedTitle,
                           settings: controller.settings,
                           recordings: controller.recordings,
                           elapsedSeconds: controller.elapsedSeconds)
    }

    // MARK: - Title and settings

    /// The editable meeting title — the field the menu binds to today. Exposed as settable because the
    /// UI genuinely edits it; without this, "the façade covers every operation" would be false.
    public var title: String {
        get { controller.title }
        set { controller.title = newValue }
    }

    /// The auto-suggested title (the field's placeholder). Read-only, as on the controller.
    public var suggestedTitle: String { controller.suggestedTitle }

    /// The current settings. Assigning mirrors the UI's binding; `saveSettings()` normalises and
    /// persists them, exactly as the menu does.
    public var settings: RecordingSettings {
        get { controller.settings }
        set { controller.settings = newValue }
    }

    /// Everything the menu needs about microphones, in one value it can render without asking three
    /// different objects three different questions.
    ///
    /// ⚠️ **The three states are carried apart, and the menu must not collapse them** (plan decision
    /// 6). System Settings showing the right default does not prove Acta's capture followed, and Acta
    /// recording from a device says nothing about what the Mac prefers. They disagree exactly when
    /// someone is looking.
    public struct MicrophoneStatus: Equatable, Sendable {
        /// Every input the machine currently offers, for the chooser.
        public var devices: [AudioInputDevice]
        /// The user's order.
        public var priority: [String]
        /// The temporary *Use now*, if one is in force.
        public var override: String?
        /// What the policy would pick — feature (B)'s preference.
        public var preferred: String?
        /// What the Mac's default input actually is.
        public var systemDefault: ObservedDefaultInput
        /// What Acta is recording from **right now**, or `nil` when nothing is recording.
        public var recordingFrom: AudioInputDevice?
        /// Whether Acta is managing the Mac's default input.
        public var managingSystemInput: Bool
        /// Whether recordings follow the list or start from the system default.
        public var captureChoice: CaptureMicrophoneChoice
        /// Enforcement's own status — waiting, paused, suspended, refused, uncertain.
        public var enforcement: MicrophoneEnforcementStatus
        /// Set when the **enumeration** failed outright.
        ///
        /// ⚠️ Separate from `observationDegraded`, and the separation is load-bearing rather than tidy:
        /// this one blocks every claim about the hardware — a selection resolved from a list that was
        /// never described says nothing — while a lost subscription leaves the last snapshot perfectly
        /// usable and only means it will stop changing.
        public var enumerationFailure: String?
        /// Set while there is no change subscription.
        public var observationDegraded: String?
        /// Set when reading the Mac's **default input** failed. Blocks only what depends on that read —
        /// a recording that follows the user's list needs it not at all.
        public var defaultReadFailure: String?
        /// Any of them, for the one warning line the menu shows. ⚠️ Combining them for *display* is
        /// fine; combining them as *input to a selection* is what made a working machine unavailable.
        public var inventoryFailure: String? {
            enumerationFailure ?? defaultReadFailure ?? observationDegraded
        }
        /// Devices the directory could not describe. ⚠️ **Not the same as absent**, and the menu must
        /// not turn an incomplete read into "there is nothing here".
        public var uninspectable: [String]

        /// Whether the machine was described completely.
        /// What a recording started **now** would be pinned to.
        ///
        /// ⚠️ **Derived from this snapshot, not by asking the resolver again.** The menu needs one
        /// honest line for "which microphone will be used", and the two wrong ways to get it are
        /// restating the policy in view code — where nothing tests it — and calling the live resolver a
        /// second time, which other code counts. `MicrophonePolicy.resolveCapture` is the same pure
        /// decision the recorder makes, so this is that answer rather than an impression of it.
        public var captureSelection: CaptureMicrophoneResolution {
            MicrophonePolicy.resolveCapture(
                CaptureObservation(devices: devices,
                                   uninspectable: uninspectable,
                                   enumerationFailure: enumerationFailure,
                                   systemDefault: systemDefault,
                                   defaultReadFailure: defaultReadFailure),
                priority: MicrophonePriority(order: priority, override: override),
                choice: captureChoice)
        }

        /// The same answer as a short phrase for the menu's always-visible summary.
        ///
        /// ⚠️ It never says a microphone is in use because one is *preferred*: "recording from" comes
        /// from what actually came up, and everything else is phrased as intent.
        public var captureSummary: String {
            if let recording = recordingFrom { return "Recording from \(recording.name)" }
            switch captureSelection {
            case .pinned(let device, _):
                return override == device.uid ? "Will use \(device.name) — chosen for now"
                                              : "Will use \(device.name)"
            case .unavailable(.noneConfigured):
                return "No microphone chosen yet"
            case .unavailable(.noPreferredDeviceAvailable):
                // ⚠️ "available", not "connected": this case is also reached by a device that is listed
                // and not usable, and telling the user to plug in something already plugged in sends
                // them looking in the wrong place.
                return "None of your microphones is available"
            case .unavailable(.noEligibleDevice):
                return "No microphone available"
            case .unavailable(.systemDefaultUnreadable):
                return "The audio devices could not be read"
            case .unavailable(.snapshotIncomplete):
                return "Some audio devices could not be read"
            }
        }

        /// What feature (B) is **actually** doing, as a phrase for the menu — or `nil` when it is off.
        ///
        /// ⚠️ **"Enabled" is not "holding", and rendering it as such was a defect.** `managingSystemInput`
        /// is true for every state except `.disabled`, so a suspended, refused, degraded or still-waiting
        /// enforcement all reported "Holding the Mac's input on your list" — while the only explanation
        /// sat inside a collapsed section. A feature that has *stopped* doing what it promised must say
        /// so in the line that is always visible, and only a verified `.enforcing` may claim it holds a
        /// device.
        ///
        /// ⚠️ It is a projection with tests rather than a ternary in the view, for the same reason
        /// `captureSummary` is: the view is the one layer nothing checks.
        public var managementSummary: String? {
            switch enforcement {
            case .disabled:
                return nil
            case .enforcing(let uid):
                let name = devices.first { $0.uid == uid }?.name ?? uid
                return "Holding the Mac's input on \(name)"
            case .waitingForPreferredDevice:
                return "Waiting for a microphone from your list"
            case .noEligibleDevice:
                return "No microphone the Mac will accept as its input"
            case .writesRefused:
                return "The Mac refused the input change"
            case .uncertain:
                return "Cannot confirm the Mac's input"
            case .paused:
                return "Not changing the Mac's input — paused"
            case .suspended(.repeatedReversals):
                return "Stopped changing the Mac's input — something kept changing it back"
            case .suspended(.repeatedConvergenceFailures):
                // ⚠️ **Not a reversal, and saying so was an invention.** This cause means Acta's writes
                // never visibly took; nobody was observed changing anything back, and the budget keeps
                // the two apart precisely so the user is not sent looking for a culprit that may not
                // exist.
                return "Stopped changing the Mac's input after repeated unsuccessful attempts"
            case .degraded:
                return "Cannot read the Mac's input"
            }
        }

        /// What the priority list actually governs, given the choice and any override in force.
        ///
        /// ⚠️ **Four combinations, and the first version of this sentence was wrong in two of them.** It
        /// said recordings use the highest microphone on the list — false when the user has asked to
        /// follow the Mac's input, and false again while a *Use now* is in force. Then the corrected
        /// version still told a user in system-default mode that resuming automatic selection returns
        /// them "to the list", when it returns them to the Mac's input. An instruction that teaches the
        /// feature must not be the thing that misdescribes it, so it lives here where it is tested
        /// rather than in the view, where nothing checks a string.
        public var listExplanation: String {
            if override != nil, !overrideInForce {
                return "A microphone is chosen for now but is not available, so it is not being used. "
                    + "Resume automatic selection to retire the choice."
            }
            if override != nil {
                return captureChoice == .systemDefault
                    ? "A microphone is chosen for now, so it is used instead of the Mac's input. "
                        + "Resume automatic selection to go back to your recording setting."
                    : "A microphone is chosen for now, so it is used instead of your list. "
                        + "Resume automatic selection to go back to the list."
            }
            if captureChoice == .systemDefault {
                return "Recordings currently use the Mac's input at the time they start, not this list. "
                    + "Your list still decides what the Mac's input becomes, if you turn that on below."
            }
            return priority.isEmpty
                ? "Tick a microphone to put it on your list. Recordings use the highest one available."
                : "Recordings use the highest one available. Use the arrows to reorder."
        }

        /// Whether that state is one the user should act on rather than merely be told about.
        public var managementNeedsAttention: Bool {
            switch enforcement {
            case .disabled, .enforcing, .paused: return false
            default: return true
            }
        }

        /// Whether the **device list** was described completely.
        ///
        /// ⚠️ It asks about the enumeration and nothing else. Built from the combined warning it also
        /// took a failed default-input read and a lost subscription as evidence about the list — so a
        /// perfectly described machine reported an absent microphone as "not readable" rather than "not
        /// connected", and a successful enumeration that found nothing said the devices could not be
        /// read. Neither failure is evidence about a list that was read successfully.
        public var isComplete: Bool { enumerationFailure == nil && uninspectable.isEmpty }

        /// Whether a stored *Use now* is the device a recording would actually come up on.
        ///
        /// ⚠️ **A stored override is not a used one**, and saying otherwise was an unsupported claim in
        /// two places: the explanation said the list was being bypassed, and the row said "using now" —
        /// while the selection had correctly fallen back to the list because the chosen device was
        /// unusable. One row could say "using now" and "unavailable" at once.
        public var overrideInForce: Bool {
            guard let override else { return false }
            if case .pinned(let device, _) = captureSelection { return device.uid == override }
            return false
        }

        public init(devices: [AudioInputDevice] = [], priority: [String] = [], override: String? = nil,
                    preferred: String? = nil, systemDefault: ObservedDefaultInput = .unread,
                    recordingFrom: AudioInputDevice? = nil, managingSystemInput: Bool = false,
                    captureChoice: CaptureMicrophoneChoice = .followPriority,
                    enforcement: MicrophoneEnforcementStatus = .disabled,
                    enumerationFailure: String? = nil,
                    observationDegraded: String? = nil,
                    defaultReadFailure: String? = nil,
                    uninspectable: [String] = []) {
            self.devices = devices
            self.priority = priority
            self.override = override
            self.preferred = preferred
            self.systemDefault = systemDefault
            self.recordingFrom = recordingFrom
            self.managingSystemInput = managingSystemInput
            self.captureChoice = captureChoice
            self.enforcement = enforcement
            self.enumerationFailure = enumerationFailure
            self.observationDegraded = observationDegraded
            self.defaultReadFailure = defaultReadFailure
            self.uninspectable = uninspectable
        }
    }

    /// A stream of microphone statuses: the current one first, then one for every change either the
    /// device inventory or enforcement publishes.
    ///
    /// ⚠️ **Without this the menu was static.** `states()` is driven by the recording controller's
    /// `objectWillChange`, and microphone state is deliberately not part of `ControlState`, so an open
    /// idle menu never learned that a microphone was plugged in, that the Mac's default had moved, that
    /// enforcement had suspended itself, or that a *Use now* had expired. Refreshing after a command is
    /// not observation.
    public func microphoneStatuses() -> AsyncStream<MicrophoneStatus> {
        let inventories = microphone.inventories()
        let enforcements = microphone.enforcementStates()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuation.yield(microphoneStatus)
            let pump = Task { [weak self] in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await _ in inventories {
                            guard let api = self else { return }
                            let next = await MainActor.run { api.microphoneStatus }
                            continuation.yield(next)
                        }
                    }
                    group.addTask {
                        for await _ in enforcements {
                            guard let api = self else { return }
                            let next = await MainActor.run { api.microphoneStatus }
                            continuation.yield(next)
                        }
                    }
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    public var microphoneStatus: MicrophoneStatus {
        let preference = microphone.capturePreference.snapshot
        return MicrophoneStatus(
            devices: microphone.inventory.devices,
            priority: preference.priority.order,
            override: preference.priority.override,
            preferred: microphone.enforcement.preferred,
            systemDefault: microphone.inventory.observedDefault,
            recordingFrom: controller.recordingMicrophone,
            managingSystemInput: microphone.enforcement.status != .disabled,
            captureChoice: preference.choice,
            enforcement: microphone.enforcement.status,
            enumerationFailure: microphone.inventory.failure,
            observationDegraded: microphone.inventory.observationDegraded,
            defaultReadFailure: microphone.inventory.defaultReadFailure,
            // ⚠️ **Carried, not dropped.** Without it a snapshot that could not describe some driver
            // projected as a successfully enumerated empty machine, and the menu said "No microphones
            // found" — a settled claim about the hardware drawn from a read that admitted it was
            // incomplete.
            uninspectable: microphone.inventory.uninspectable
        )
    }

    /// Turn management of the Mac's default input on, seeding the list if it is empty.
    public func enableMicrophoneManagement() async { _ = await microphone.enableManagement() }
    public func disableMicrophoneManagement() async { await microphone.disableManagement() }

    /// Whether feature (B) is in force — the authoritative answer, not the published mirror, and
    /// readable **without suspending**. See `MicrophoneManager.managementEnabled` for why that matters:
    /// its consumer is in the middle of a read-modify-write of the whole settings value.
    public var isMicrophoneManagementEnabled: Bool { microphone.managementEnabled }
    public func pauseMicrophoneManagement() async { await microphone.pauseEnforcement() }
    public func resumeMicrophoneManagement() async { await microphone.resumeEnforcement() }
    public func setMicrophonePriority(_ order: [String]) async { await microphone.setPriorityOrder(order) }
    public func setCaptureMicrophoneChoice(_ choice: CaptureMicrophoneChoice) {
        microphone.setCaptureChoice(choice)
    }

    /// *Use now*: point Acta at this microphone.
    ///
    /// ⚠️ **One user action with two effects, and they are not the same promise.** It sets the
    /// temporary override — which the reconciler expires when that device disconnects, and which Acta's
    /// own capture resolves against — and, if a recording is running, switches its live capture through
    /// the one serialized lifecycle. The two can legitimately disagree: capture does not filter on
    /// `canBeSystemDefault` and the system default does, so a click can land on one and not the other.
    public func useMicrophoneNow(uid: String) async {
        await microphone.useNow(uid: uid)
        await controller.switchMicrophone(to: uid)
    }

    /// Retire the temporary override and go back to the priority list.
    public func resumeAutomaticMicrophoneSelection() async {
        await microphone.resumeAutomaticSelection()
    }

    /// Normalise and persist the settings — and hand the microphone half of them to the app-lifetime
    /// owner, so an edit reaches the reconciler and the capture pin without the menu wiring each field
    /// separately.
    public func saveSettings() {
        controller.saveSettings()
        // Owned and ordered by the manager rather than an unowned Task here — see `applySettings`.
        microphone.applySettings(controller.settings)
    }

    /// Persist a change the caller has **already carried out**, and ask the microphone owner for
    /// nothing.
    ///
    /// ⚠️ **An acknowledgement is not a command, and treating it as one was the root of a family of
    /// defects.** A control that switches management on has already enabled it; routing the subsequent
    /// save through `apply` ran the grant a *second* time, as fresh work, outside the permission fence
    /// that governed the first — so a Pause issued in between was cleared by the completion of the very
    /// Enable it was clicked on top of, and a management field captured before an Off wrote the Mac's
    /// input after it. Every save the menu makes is of this kind: the command performed the change, the
    /// save records it.
    public func persistSettings() {
        controller.saveSettings()
    }

    /// The saved recordings, newest first.
    public var recordings: [MeetingStore.Recording] { controller.recordings }

    // MARK: - Commands

    /// Start recording.
    ///
    /// - Parameter title: the meeting title. Passing one **sets the controller's `title` and then**
    ///   calls `start()` — an observable intermediate mutation, not an atomic parameter, because the
    ///   controller exposes `start()` over its own mutable field and this plan does not change it.
    ///   `nil` leaves whatever `title` holds (what the menu does: the user typed into the field).
    ///   An empty title, here as in the menu, means "use the auto-suggestion".
    ///
    /// ⚠️ A title passed while the controller is busy still lands: the existing guard makes the *start*
    /// a no-op, and the title mutation happened before it. That is the controller's behaviour today,
    /// reproduced rather than replaced by a rejection this façade would have had to invent.
    public func start(title: String? = nil) {
        if let title { controller.title = title }
        controller.start()
    }

    /// Stop the recording, fire-and-forget — returns as soon as the work is kicked off.
    public func stop() { controller.stop() }

    /// Stop the recording and wait until it is saved. The quit path: it awaits a start in flight first,
    /// so a capture that is already live while the operation still reads `.starting` is actually torn
    /// down instead of dying mid-segment.
    public func stopAndWait() async { await controller.stopAndWait() }

    /// Recover recordings interrupted by a crash — the controller's `onLaunch()`. Recovery runs **once
    /// per controller**; a second call is a no-op, as it is for a second `onLaunch`.
    public func recover() { controller.onLaunch() }

    /// Refresh the suggested title and the recordings list — the controller's `onAppear()`. It does
    /// **not** recover: recovery belongs to `recover()` and nowhere else.
    public func refresh() { controller.onAppear() }

    /// Reveal the archive root in Finder. A failure sets a `notice`, never a `lifecycleFailure` — and
    /// never touches the operation.
    public func openArchive() { controller.openArchive() }

    /// Reveal one recording's folder in Finder.
    public func openInFinder(_ url: URL) { controller.openInFinder(url) }

    /// Dismiss the recovery banner — the controller's `dismissRecoveredBanner()`.
    public func dismissRecoveryNotice() { controller.dismissRecoveredBanner() }
}
