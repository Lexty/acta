import ActaKit
import Foundation

/// A plain snapshot of the observable fields `RecordingController` publishes — the input of the
/// `ControlAPI` façade's translation, taken as a value so the translation itself is a pure function.
///
/// It lives in `ActaRuntime` rather than `ActaKit` despite being pure: it names
/// `RecordingController.Phase` and `MeetingStore.Recording`, both of which are runtime types, and it
/// inherits the `macOS 15` availability the phase carries. `ActaKit`'s rule is "no I/O", and the rule
/// this file obeys instead is the one that matters here — no I/O, no clock, no `RecordingController`
/// — so `ControlStateTests` drives it with nothing but literals.
///
/// The snapshot deliberately reads the controller's **public** `isSaving`, not its private
/// `isStopping`: the public flag already folds the private one in, and it is the only form a façade
/// outside the controller can observe at all.
@available(macOS 15.0, *)
public struct ControllerSnapshot: Equatable, Sendable {
    /// The controller's settled phase.
    public var phase: RecordingController.Phase
    /// Whether an asynchronous start is in flight (capture may already be live while `phase` is
    /// `.idle` or, on a retry after a failed start, `.error`).
    public var isStarting: Bool
    /// Whether a stop is in flight — the controller's `isSaving`, which is `phase == .saving` **or**
    /// its private `isStopping` (the fatal-stall path parks `phase` in `.error` while the assembly runs).
    public var isSaving: Bool
    /// The controller's single untyped error banner (empty when there is none).
    public var errorMessage: String
    /// The controller's separate recovery banner (empty when there is none).
    public var recoveredBanner: String
    /// The editable meeting title.
    public var title: String
    /// The auto-suggested title (the field's placeholder).
    public var suggestedTitle: String
    /// The current recording settings.
    public var settings: RecordingSettings
    /// The saved recordings, newest first.
    public var recordings: [MeetingStore.Recording]
    /// Elapsed time of the current recording, s.
    public var elapsedSeconds: Int

    public init(phase: RecordingController.Phase = .idle,
                isStarting: Bool = false,
                isSaving: Bool = false,
                errorMessage: String = "",
                recoveredBanner: String = "",
                title: String = "",
                suggestedTitle: String = "",
                settings: RecordingSettings = .default,
                recordings: [MeetingStore.Recording] = [],
                elapsedSeconds: Int = 0) {
        self.phase = phase
        self.isStarting = isStarting
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.recoveredBanner = recoveredBanner
        self.title = title
        self.suggestedTitle = suggestedTitle
        self.settings = settings
        self.recordings = recordings
        self.elapsedSeconds = elapsedSeconds
    }
}

/// A lifecycle failure — a recording that did not start, or stopped without producing its final file.
///
/// ⚠️ **The provenance is a best-effort classification, not truthful typed provenance.** The
/// controller publishes exactly one untyped `errorMessage`; nothing in it says which code path wrote
/// it. `category` is therefore inferred by a reverse lookup over the strings production is known to
/// write, and `.unknown` is the honest answer for anything else. `displayMessage` carries no such
/// doubt: it is the controller's own string, passed through byte for byte, which is why the UI can be
/// migrated onto this type without a single message changing.
public struct ControlFailure: Equatable, Sendable {
    /// What the message was recognised as.
    public enum Category: Equatable, Sendable {
        /// Self-diagnosis rejected the start, and the message matched a known `StartupFailure`.
        /// Reached both by a failed start and by a fatal stall — the controller writes
        /// `StartupFailure.userMessage` on both paths, so the message cannot tell them apart.
        case startup(StartupFailure)
        /// A start that threw something other than a `StartupFailure`.
        case startFailed
        /// The capture stopped, but the segments were not assembled into the final file.
        /// `ffmpegMissing` distinguishes the two branches the controller words differently.
        case assemblyFailed(ffmpegMissing: Bool)
        /// A non-empty message no known production string accounts for. Not an error in the mapping:
        /// a string the reverse lookup has never seen is exactly what it cannot classify, and
        /// guessing would be worse than saying so.
        case unknown
    }

    public var category: Category
    /// The controller's `errorMessage`, verbatim.
    public var displayMessage: String

    public init(category: Category, displayMessage: String) {
        self.category = category
        self.displayMessage = displayMessage
    }
}

/// A message that is **not** about the recording lifecycle — today only the archive-open failure,
/// which the controller reports through the same `errorMessage` while deliberately leaving `phase`
/// alone (parking `phase` in `.error` mid-recording would no-op `stop()`'s guard).
public struct Notice: Equatable, Sendable {
    public enum Category: Equatable, Sendable {
        /// `openArchive()` could not reveal the archive root.
        case archiveOpenFailed
    }

    public var category: Category
    /// The controller's `errorMessage`, verbatim.
    public var displayMessage: String

    public init(category: Category, displayMessage: String) {
        self.category = category
        self.displayMessage = displayMessage
    }
}

/// The recovery banner. Genuinely independent of `ControlFailure`/`Notice`: it maps from the
/// controller's **separate** `recoveredBanner`, so it can never be crowded out by an error.
public struct RecoveryNotice: Equatable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

/// The typed state of the recorder — what `ControlAPI` exposes in place of the controller's untyped
/// bag of published fields.
///
/// **Orthogonal by construction:** an error is *not* an operation. The controller conflates them
/// (`phase == .error` sits where `.idle` belongs, and a fatal stall parks `.error` while the assembly
/// still runs), and untangling that is most of this type's value: `operation` says what the recorder
/// is doing, `lifecycleFailure` says what went wrong, and the two are read independently.
@available(macOS 15.0, *)
public struct ControlState: Equatable, Sendable {
    /// What the recorder is doing. There is no `.error` case on purpose — see `lifecycleFailure`.
    public enum Operation: Equatable, Sendable {
        /// Nothing in flight. A start is allowed.
        case idle
        /// A start is in flight. Capture may already be writing segments.
        case starting
        /// Recording. `elapsedSeconds` is seconds only — a façade has no business shipping a
        /// formatted string.
        case recording(elapsedSeconds: Int)
        /// Capture has stopped; the segments are being assembled.
        case saving
    }

    public var operation: Operation
    /// The recording lifecycle failed. Orthogonal to `operation`: a fatal stall carries this **while**
    /// `operation == .saving`, and keeps carrying it once the assembly settles the operation to `.idle`.
    public var lifecycleFailure: ControlFailure?
    /// A message unrelated to the lifecycle (see `Notice`).
    ///
    /// ⚠️ `notice` and `lifecycleFailure` are two views of the controller's **one** `errorMessage`,
    /// so at most one of them can be non-nil in any snapshot. That is the controller's loss faithfully
    /// reproduced, not a modelling choice: when `openArchive()` overwrites a lifecycle failure, the
    /// earlier message is gone from the controller too.
    public var notice: Notice?
    /// The recovery banner, if any — independent of both fields above.
    public var recoveryNotice: RecoveryNotice?
    public var title: String
    public var suggestedTitle: String
    public var settings: RecordingSettings
    public var recordings: [MeetingStore.Recording]

    public init(operation: Operation = .idle,
                lifecycleFailure: ControlFailure? = nil,
                notice: Notice? = nil,
                recoveryNotice: RecoveryNotice? = nil,
                title: String = "",
                suggestedTitle: String = "",
                settings: RecordingSettings = .default,
                recordings: [MeetingStore.Recording] = []) {
        self.operation = operation
        self.lifecycleFailure = lifecycleFailure
        self.notice = notice
        self.recoveryNotice = recoveryNotice
        self.title = title
        self.suggestedTitle = suggestedTitle
        self.settings = settings
        self.recordings = recordings
    }

    /// Work that must not be cut short by quitting — the controller's `hasWorkInFlight`, restated over
    /// `operation` alone. A settled failure is not work in flight, which is exactly why `.error` is not
    /// an operation.
    public var hasWorkInFlight: Bool { operation != .idle }

    /// Whether `start(title:)` would do anything — the controller's own guard, restated.
    public var canStart: Bool { operation == .idle }

    /// Whether `stop()` would do anything — the controller stops only from `phase == .recording`.
    public var canStop: Bool {
        if case .recording = operation { return true }
        return false
    }
}
