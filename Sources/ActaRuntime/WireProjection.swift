import ActaControlProtocol
import ActaKit
import Foundation

// The **pure projection** from the runtime's typed state into the wire types.
//
// It lives here, in `ActaRuntime`, because it is the one place where both sides are visible:
// `ControlState`/`MeetingStore.Recording`/`RecordingSettings` are runtime types (and inherit the
// macOS 15 availability `RecordingController.Phase` carries), while the wire types come from the
// dependency-free `ActaControlProtocol`.
//
// ⚠️ A projection, NOT a `Codable` conformance on the runtime types. Conforming `ControlState` to
// `Codable` would weld the wire schema to the runtime representation: renaming a runtime field would
// silently rename a wire key, and the wire schema could never be frozen independently. These
// initialisers are the seam that keeps the two free to move apart — they are pure functions, so every
// case is driven from literals in `WireProjectionTests`.

// MARK: - Settings

extension WireSettings {
    /// Project the runtime settings onto the wire.
    public init(_ settings: RecordingSettings) {
        self.init(archivePath: settings.archivePath,
                  segmentSeconds: settings.segmentSeconds,
                  deleteSegmentsAfterAssembly: settings.deleteSegmentsAfterAssembly,
                  microphonePriority: settings.microphonePriority,
                  managesSystemDefaultInput: settings.managesSystemDefaultInput,
                  captureMicrophoneChoice: CaptureChoice(settings.captureMicrophoneChoice))
    }
}

extension RecordingSettings {
    /// The inverse: a `settings_set` command's payload becomes runtime settings.
    ///
    /// It does **not** normalise: `saveSettings()` is what clamps and persists, exactly as it does for
    /// the menu's bindings. A `settings_set` that writes an out-of-range segment length is the same
    /// intermediate state the UI's slider passes through, and `settings_save` resolves it the same way.
    public init(_ wire: WireSettings) {
        self.init(archivePath: wire.archivePath,
                  segmentSeconds: wire.segmentSeconds,
                  deleteSegmentsAfterAssembly: wire.deleteSegmentsAfterAssembly,
                  microphonePriority: wire.microphonePriority,
                  managesSystemDefaultInput: wire.managesSystemDefaultInput,
                  captureMicrophoneChoice: wire.captureMicrophoneChoice.runtimeValue)
    }
}

/// ⚠️ **A projection, not a `Codable` conformance on the runtime enum.** Conforming
/// `CaptureMicrophoneChoice` to the wire's encoding would let a rename in `ActaKit` silently rename a
/// wire value — the same rule that keeps `ControlState` off the wire directly.
extension WireSettings.CaptureChoice {
    init(_ choice: CaptureMicrophoneChoice) {
        switch choice {
        case .followPriority: self = .followPriority
        case .systemDefault: self = .systemDefault
        }
    }

    var runtimeValue: CaptureMicrophoneChoice {
        switch self {
        case .followPriority: return .followPriority
        case .systemDefault: return .systemDefault
        }
    }
}

// MARK: - Recordings

extension RecordingSummary {
    /// Project one archive entry onto the wire.
    ///
    /// ⚠️ **Survives a missing manifest.** `MeetingStore.Recording.manifest` is optional — a folder
    /// whose `session.json` is absent or unreadable is still a real recording the agent may want to
    /// reveal. The identity fields (`id`, `directory_name`, `path`) come from the URL alone and are
    /// therefore always present; `status` degrades to `.unknown`; every manifest-derived field is
    /// omitted rather than guessed.
    public init(_ recording: MeetingStore.Recording) {
        let name = recording.directory.lastPathComponent
        let manifest = recording.manifest
        self.init(id: RecordingID.make(directoryName: name),
                  directoryName: name,
                  path: recording.directory.path,
                  status: manifest.map { RecordingSummary.status(of: $0.status) } ?? .unknown,
                  startedAt: manifest?.startedAt,
                  segmentSeconds: manifest?.segmentSeconds,
                  segmentCount: manifest?.segmentCount,
                  assemblyAttempts: manifest?.assemblyAttempts)
    }

    /// The manifest's status onto the wire's. Spelled out rather than bridged through the raw value:
    /// the two enums are allowed to diverge, and a new manifest case must fail to compile here rather
    /// than reach a client as a string it has never seen.
    private static func status(of status: SessionManifest.Status) -> Status {
        switch status {
        case .recording: return .recording
        case .done: return .done
        case .recovered: return .recovered
        }
    }
}

/// The `id` → recording lookup, the **other half** of `RecordingID`'s one home.
///
/// `openInFinder(id:)` resolves through here: the id is base64url-decoded back to a directory name and
/// matched against the *current* recordings. An id that does not decode, or decodes to a name no
/// current recording carries, yields `nil` — the dispatcher's cue to answer `unknown_recording`.
///
/// ⚠️ **Never a caller-supplied path.** `RecordingSummary.path` exists because this is a local-archive
/// agent interface and an agent needs to find the files — but a command that acted on a path the client
/// sent would let any path in the file system be revealed. The only thing a client may name is an id it
/// was given, and the only thing an id can name is a folder already in the archive listing.
public enum ControlRecordingLookup {
    public static func recording(forID id: String,
                                 in recordings: [MeetingStore.Recording]) -> MeetingStore.Recording? {
        guard let name = RecordingID.directoryName(fromID: id) else { return nil }
        return recordings.first { $0.directory.lastPathComponent == name }
    }
}

// MARK: - State

@available(macOS 15.0, *)
extension WireControlState.Operation {
    fileprivate init(_ operation: ControlState.Operation) {
        switch operation {
        case .idle: self.init(kind: .idle)
        case .starting: self.init(kind: .starting)
        // The only case carrying `elapsed_seconds`, which is why the field is optional on the wire
        // rather than a zero that would read as "recording, 0s" in every other state.
        case .recording(let elapsed): self.init(kind: .recording, elapsedSeconds: elapsed)
        case .saving: self.init(kind: .saving)
        }
    }
}

extension WireControlState.Message {
    fileprivate init(_ failure: ControlFailure) {
        self.init(code: WireControlState.Message.code(of: failure.category),
                  message: failure.displayMessage)
    }

    fileprivate init(_ notice: Notice) {
        switch notice.category {
        case .archiveOpenFailed:
            self.init(code: WireMessageCode.archiveOpenFailed, message: notice.displayMessage)
        case .microphoneSwitched:
            self.init(code: WireMessageCode.microphoneSwitched, message: notice.displayMessage)
        case .microphoneSwitchFailed:
            self.init(code: WireMessageCode.microphoneSwitchFailed, message: notice.displayMessage)
        }
    }

    fileprivate init(_ notice: RecoveryNotice) {
        self.init(code: WireMessageCode.recoveryCompleted, message: notice.message)
    }

    /// The classification onto a stable code. Exhaustive by construction — a new category fails to
    /// compile here rather than degrading to a code a client cannot branch on.
    private static func code(of category: ControlFailure.Category) -> String {
        switch category {
        case .startup(let failure):
            switch failure {
            case .noScreenRecordingPermission: return WireMessageCode.startupNoScreenRecordingPermission
            case .noMicrophonePermission: return WireMessageCode.startupNoMicrophonePermission
            case .streamNotStarted: return WireMessageCode.startupStreamNotStarted
            case .diskWriteFailed: return WireMessageCode.startupDiskWriteFailed
            case .noData: return WireMessageCode.startupNoData
            case .microphoneUnavailable: return WireMessageCode.startupMicrophoneUnavailable
            case .recordingAlreadyStopped: return WireMessageCode.startupRecordingAlreadyStopped
            case .preferredMicrophoneAbsent: return WireMessageCode.startupPreferredMicrophoneAbsent
            case .noMicrophoneOnThisMac: return WireMessageCode.startupNoMicrophoneOnThisMac
            case .microphoneUnreadable: return WireMessageCode.startupMicrophoneUnreadable
            }
        case .startFailed:
            return WireMessageCode.startFailed
        case .assemblyFailed(let ffmpegMissing):
            return ffmpegMissing ? WireMessageCode.assemblyFailedFFmpegMissing
                                 : WireMessageCode.assemblyFailed
        case .unknown:
            return WireMessageCode.unknownFailure
        }
    }
}

@available(macOS 15.0, *)
extension WireControlState {
    /// Project the typed state onto the wire.
    ///
    /// `can_start`/`can_stop` are carried rather than left for the client to re-derive from
    /// `operation`: they are the *controller's own guards* restated by `ControlState`, and a client
    /// recomputing them would be a second copy of a rule that has already moved once.
    public init(state: ControlState) {
        self.init(operation: Operation(state.operation),
                  lifecycleFailure: state.lifecycleFailure.map(Message.init),
                  notice: state.notice.map(Message.init),
                  recoveryNotice: state.recoveryNotice.map(Message.init),
                  title: state.title,
                  suggestedTitle: state.suggestedTitle,
                  settings: WireSettings(state.settings),
                  recordings: state.recordings.map(RecordingSummary.init),
                  canStart: state.canStart,
                  canStop: state.canStop)
    }
}
