import SwiftUI
import ActaKit
import ActaRuntime

/// Entry point. A menu-bar app (`LSUIElement=true`, no Dock icon).
/// Capture (`SCStream` + microphone) requires macOS 15, so the working UI is available from that
/// version on; on older systems we show a clear placeholder instead of a "mute" menu.
@main
struct ActaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            if #available(macOS 15.0, *) {
                MenuContent()
            } else {
                UnsupportedContent()
            }
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    /// What shows in the menu bar. The dev build adds a visible "DEV" tag next to the waveform so two
    /// flavors running at once are never confused; stable keeps the bare icon it always had.
    @ViewBuilder
    private var menuBarLabel: some View {
        if BuildFlavor.current == .dev {
            Label("DEV", systemImage: "waveform")
        } else {
            Image(systemName: "waveform")
        }
    }
}

/// Needed for exactly one thing: to provide an "app has launched" entry point. Recovery of
/// interrupted recordings must run at startup (SPEC §7), and a menu bar with
/// `menuBarExtraStyle(.window)` builds its content only when the user clicks — no SwiftUI hook
/// fires before the menu is opened for the first time.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 15.0, *) {
            ControlAPI.shared.recover()
            // ⚠️ **Here, and not from a view.** `MenuBarExtra(.window)` builds its content on the first
            // click, so anything that waits for the menu has already missed every device change since
            // launch — and feature (B)'s promise is that the default input stays on your list while
            // Acta is *running*, not while its menu happens to be open.
            ControlAPI.shared.microphone.start()
            // The persisted list and the enable flag, applied once at launch. Without this the settings
            // are stored and inert until someone happens to open the menu and save.
            ControlAPI.shared.microphone.applySettings(ControlAPI.shared.settings)
        }
    }

    /// Prevent quitting from cutting off an active recording. Without this, "Quit" during a
    /// recording is no different from `kill -9`: the current segment stays unfinalised, the marker
    /// stays `recording`, and up to `segmentSeconds` of audio is lost. Recovery does handle that,
    /// but it exists for crashes, not for a deliberate user action — here the recording must be
    /// honestly finished and assembled.
    /// ⚠️ **Always `.terminateLater` now, and the ordering inside is the whole point.** Quitting has
    /// three things to finish and they are not interchangeable:
    ///
    /// 1. **Stop writing the system default first.** It is the only part of shutdown that changes state
    ///    other applications depend on, and it must not still be correcting the default while the user
    ///    is quitting.
    /// 2. **Then let a recording finish honestly** — the original reason this method exists. Read-only
    ///    monitoring stays up across this step: `stopAndWait()` waits for capture and self-check work,
    ///    not merely for the assembler, and a recording's own device observation is independent of the
    ///    manager's.
    /// 3. **Then release the manager's consumers**, awaited, so nothing reads or writes through the
    ///    directory afterwards.
    ///
    /// The idle branch used to return `.terminateNow` immediately, which meant the microphone shutdown
    /// it had just started never ran at all.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard #available(macOS 15.0, *) else { return .terminateNow }
        // AppKit calls this method on the main thread, which is where the façade lives.
        return MainActor.assumeIsolated {
            Task {
                await ControlAPI.shared.microphone.stopEnforcement()
                if ControlAPI.shared.state.hasWorkInFlight {
                    await ControlAPI.shared.stopAndWait()
                }
                await ControlAPI.shared.microphone.shutdown()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}

/// The chooser's measured content height, so a bounded scroll view can size to it.
private struct ChooserHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Placeholder for macOS < 15 (microphone capture through a single `SCStream` arrived in 15).
struct UnsupportedContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(BuildFlavor.current.appDisplayName).font(.headline)
            Text("macOS 15 or later is required.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }
}

/// Menu-bar contents: start/stop, timer, status indicator, title field, list of recordings and
/// prominent display of self-diagnosis errors (Task 6).
@available(macOS 15.0, *)
struct MenuContent: View {
    // The view owns the adapter, so `@StateObject`: it subscribes to `ControlAPI.shared.states()` and
    // renders the `ControlState` it delivers. No view here touches the recording controller or the
    // pipeline — every read is on `state`, every action is a `ControlAPI` command.
    @StateObject private var model = ControlViewModel()
    @State private var settingsExpanded = false
    /// ⚠️ Collapsed by default. The chooser is six rows plus a picker plus the management
    /// controls, and shown unconditionally it pushed the menu off the bottom of the screen —
    /// on a laptop, with only six devices attached. What a user needs at a glance is which
    /// microphone will be used, not the whole apparatus for deciding it.
    @State private var microphoneExpanded = false
    /// The chooser's own content height, so the bounded scroll view does not claim space it is not
    /// using. Seeded at the bound rather than at zero: a first frame of height zero collapses the
    /// section to nothing for one pass, which reads as the disclosure having failed to open.
    @State private var chooserHeight: CGFloat = MenuContent.chooserMaxHeight
    /// How tall the chooser may get before it scrolls.
    ///
    /// ⚠️ A judgement, not a measurement, and scoped to what it can actually promise: it bounds **this
    /// section's** growth with the device count. It is not proof that the whole menu fits — the other
    /// sections, an expanded Settings above all, take height of their own, and nothing here has
    /// measured a rendered popover.
    static let chooserMaxHeight: CGFloat = 320

    /// The current typed state — the single thing every view below reads.
    private var state: ControlState { model.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            if let recovery = state.recoveryNotice {
                banner(recovery.message, systemImage: "arrow.clockwise.circle.fill",
                       tint: .orange) { model.dismissRecoveryNotice() }
            }
            if let errorText = errorBannerText {
                banner(errorText, systemImage: "exclamationmark.triangle.fill",
                       tint: .red, dismiss: nil)
            }

            titleField
            controls

            Divider()
            microphoneSection

            Divider()
            recordingsList

            Divider()
            settingsSection

            Divider()
            HStack {
                Button("Open Archive") { model.openArchive() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { model.refresh(); model.refreshMicrophone() }
        // Auto-cancelled when the menu closes, so repeated opens do not accumulate subscriptions.
        .task { await model.subscribe() }
    }

    // MARK: - Sections

    /// The single red banner: the controller has one `errorMessage`, so at most one of a lifecycle
    /// failure or a notice is present — both carry it verbatim.
    private var errorBannerText: String? {
        state.lifecycleFailure?.displayMessage ?? state.notice?.displayMessage
    }

    /// Whether editing the title and settings is blocked — today's `isBusy`, restated over `operation`.
    private var isBusy: Bool { state.operation != .idle }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(BuildFlavor.current.appDisplayName).font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if BuildFlavor.current == .dev {
                    // Which build is this? With two apps installed it is worth knowing at a glance.
                    Text(BuildFlavor.revision).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if case .recording(let elapsedSeconds) = state.operation {
                // Ticks because each `elapsedSeconds` tick is a distinct `ControlState` the stream emits.
                Text(MeetingInfo.formatDuration(seconds: elapsedSeconds))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Title").font(.caption).foregroundStyle(.secondary)
            TextField(state.suggestedTitle.isEmpty ? "Meeting title" : state.suggestedTitle,
                      text: model.titleBinding)
                .textFieldStyle(.roundedBorder)
                .disabled(isBusy)
        }
    }

    private var controls: some View {
        HStack {
            switch state.operation {
            case .starting:
                // Capture is already writing segments here, while the operation is `.starting`.
                // Showing an enabled "Start Recording" would be a dead click on a live recording.
                Button {} label: {
                    Label("Starting…", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .disabled(true)
            case .saving:
                Button {} label: {
                    Label("Saving…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(true)
            case .recording:
                Button {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
            case .idle:
                Button {
                    model.start()
                } label: {
                    Label("Start Recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .tint(.accentColor)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: - Microphone

    /// The chooser, and the three states it must never collapse.
    ///
    /// ⚠️ **With feature (B) off this section reads as Acta's recording input and nothing else.** The
    /// two promises are separate — one is which microphone Acta records from, the other is which
    /// microphone the Mac prefers — and a user who never turns the second one on must not be shown a
    /// control that implies Acta is touching their system settings.
    @ViewBuilder
    private var microphoneSection: some View {
        let mic = model.microphone
        VStack(alignment: .leading, spacing: 6) {
            // ⚠️ **Outside the disclosure on purpose.** "I could not read the audio devices" must not be
            // something the user has to open a section to discover.
            if let failure = mic.inventoryFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            DisclosureGroup(isExpanded: $microphoneExpanded) {
                // ⚠️ **Bounded, because collapsing only fixed the height the user starts with.** The
                // expanded body is the whole chooser — six rows here, plus a picker, plus feature (B)'s
                // controls — and unbounded it reproduces the layout that ran off the screen the moment
                // anyone opens it to do the thing it is for. What the bound buys is that this section
                // stops growing with the device count; it is not a claim that the whole menu fits.
                // ⚠️ **Measured, not simply capped.** A `ScrollView` is greedy along its scroll axis:
                // `.frame(maxHeight:)` alone makes it take the whole bound even when the content is half
                // that, so a Mac with two microphones would show the list above a large empty gap. The
                // height is the content's own, clamped — so short content sizes naturally and only long
                // content scrolls.
                ScrollView {
                    microphoneChooser(mic)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: ChooserHeightKey.self,
                                                   value: proxy.size.height)
                        })
                }
                .frame(height: min(chooserHeight, Self.chooserMaxHeight))
                .onPreferenceChange(ChooserHeightKey.self) { chooserHeight = $0 }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Microphone").font(.headline)
                    // The one fact worth showing without opening anything.
                    Text(mic.captureSummary).font(.caption).foregroundStyle(.secondary)
                    // ⚠️ Feature (B) changes every other app's input, so *that it is on* stays visible
                    // even when its controls are folded away. Only the controls collapse, never the
                    // statement of what Acta is doing to the machine.
                    // ⚠️ The **actual** status, not "enabled" rendered as success. A suspended or
                    // refused enforcement is a feature that has stopped doing what it promised, and
                    // saying so belongs in the line that does not collapse.
                    if let summary = mic.managementSummary {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(mic.managementNeedsAttention ? .orange : .secondary)
                    }
                }
            }

            // ⚠️ **A state that needs acting on must not require opening a section to act on.** When
            // enforcement has stopped or been refused, the two decisions that answer it stay reachable
            // with the chooser still collapsed.
            if mic.managementNeedsAttention, !microphoneExpanded {
                HStack(spacing: 8) {
                    Button("Pause") { model.pauseMicrophoneManagement() }
                    Button("Turn off") { model.setManagingSystemInput(false) }
                }
                .font(.caption)
            }
        }
    }

    /// Everything behind the disclosure: the list, how it is ranked, and feature (B).
    @ViewBuilder
    private func microphoneChooser(_ mic: ControlAPI.MicrophoneStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            microphoneStates(mic)

            // ⚠️ **The list was unexplained and therefore invisible.** With no entries every device sat
            // under "Available" behind an unlabelled circle, the ranking arrows appear only once
            // something is *already* ranked, and the only explanation was a hover tooltip — so the way
            // to make the first entry had to be guessed. Manual acceptance found this immediately;
            // nothing in the suite could, because rendering is the one thing it does not see.
            // ⚠️ **This sentence used to contradict the picker three lines below it.** It said
            // recordings use the highest microphone on the list — which is false when the user has
            // asked for the Mac's input, and false again while a *Use now* is in force. An instruction
            // that teaches the feature must not be the thing that misdescribes it.
            Text(mic.listExplanation).font(.caption2).foregroundStyle(.secondary)

            // ⚠️ **Priority order first, including entries whose device is absent.** Iterating the
            // device list rendered rows in enumeration order while the arrows moved a different list —
            // so the numbers and the rows disagreed — and a preferred microphone that was unplugged
            // vanished from the menu while staying in the persistent list, which left the user unable
            // to see or remove a preference without reconnecting the device.
            if !mic.priority.isEmpty {
                Text("Your list").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(mic.priority.enumerated()), id: \.element) { index, uid in
                microphoneRow(device(uid, in: mic), rank: index, in: mic)
            }
            let unranked = mic.devices.filter { !mic.priority.contains($0.uid) }
            if !unranked.isEmpty {
                Text(mic.priority.isEmpty ? "Available" : "Not on your list")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(unranked, id: \.uid) { device in
                    microphoneRow(device, rank: nil, in: mic)
                }
            }
            if mic.devices.isEmpty, mic.priority.isEmpty {
                // ⚠️ An incomplete read is never rendered as a settled claim about the hardware.
                Text(mic.isComplete ? "No microphones found."
                                    : "The audio devices could not be read.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ⚠️ **The explicit capture policy had no control at all**, so a persisted setting could
            // only be changed outside the shipped chooser.
            Picker("Recordings use", selection: Binding(
                get: { mic.captureChoice },
                set: { model.setCaptureChoice($0) }
            )) {
                Text("my list").tag(CaptureMicrophoneChoice.followPriority)
                Text("the Mac's input at the time").tag(CaptureMicrophoneChoice.systemDefault)
            }
            .font(.caption)

            Text("Changes apply the next time capture starts — a new recording, or one this recording "
                 + "restarts by itself. If Acta manages the Mac's input, that changes right away.")
                .font(.caption2).foregroundStyle(.secondary)

            if mic.override != nil {
                Button("Resume automatic selection") { model.resumeAutomaticMicrophoneSelection() }
                    .font(.caption)
            }

            Divider()
            managementControls(mic)
        }
        .padding(.top, 4)
    }

    private func microphoneStates(_ mic: ControlAPI.MicrophoneStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let recording = mic.recordingFrom {
                stateLine("Recording from", recording.name, systemImage: "record.circle")
            } else {
                stateLine("Recording from", "not recording", systemImage: "record.circle")
            }
            if mic.managingSystemInput {
                stateLine("Preferred", name(of: mic.preferred, in: mic) ?? "none available",
                          systemImage: "star")
                stateLine("Mac's input", systemDefaultText(mic), systemImage: "desktopcomputer")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func stateLine(_ label: String, _ value: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).frame(width: 12)
            Text("\(label): ").foregroundStyle(.secondary)
            Text(value).foregroundStyle(.primary)
        }
    }

    private func systemDefaultText(_ mic: ControlAPI.MicrophoneStatus) -> String {
        switch mic.systemDefault {
        case .unread: return "not read"
        case .noDefault: return "none"
        case .device(let uid): return name(of: uid, in: mic) ?? uid
        }
    }

    private func name(of uid: String?, in mic: ControlAPI.MicrophoneStatus) -> String? {
        guard let uid else { return nil }
        return mic.devices.first { $0.uid == uid }?.name ?? uid
    }

    /// One device: whether it is on the list, where it sits, and *Use now*.
    ///
    /// ⚠️ **Two distinct actions, never one click that does both** (plan decision 2). Borrowing a
    /// headset for one call is not a preference change, so *Use now* is temporary and the arrows edit
    /// the persistent list.
    /// A device on the list whose hardware is absent, so a preference can still be seen and removed.
    private func device(_ uid: String, in mic: ControlAPI.MicrophoneStatus) -> AudioInputDevice {
        mic.devices.first { $0.uid == uid }
            ?? AudioInputDevice(uid: uid, name: uid, transport: .other(0), inputChannels: 0,
                                canBeSystemDefault: .unknown, isAlive: .unknown,
                                isRunningSomewhere: false)
    }

    @ViewBuilder
    private func microphoneRow(_ device: AudioInputDevice, rank: Int?,
                               in mic: ControlAPI.MicrophoneStatus) -> some View {
        let present = mic.devices.contains { $0.uid == device.uid }
        HStack(spacing: 6) {
            if let rank { Text("\(rank + 1).").font(.caption2).foregroundStyle(.secondary) }
            // ⚠️ **A checkbox carrying the device's own name**, because the unlabelled circle that
            // stood here read as a radio button — one-of-many — when the control is in fact "on my
            // list", and several microphones may be on it. The action was explained only in a hover
            // tooltip, which a menu-bar popover effectively does not have.
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: Binding(get: { rank != nil },
                                     set: { _ in model.togglePreferred(device.uid) })) {
                    Text(device.name).font(.callout)
                }
                .toggleStyle(.checkbox)
                // ⚠️ **"using now" is a claim about what is in force, not about what is stored.** Shown
                // for any stored override, one row could say "using now" and "unavailable" at once —
                // while the selection had correctly fallen back to the list.
                // ⚠️ Three facts, three labels. Only a recording that came up on this device may be
                // described in the present tense, and only a complete observation may call it absent.
                if device.uid == mic.override {
                    switch mic.overrideStanding {
                    case .recording:
                        Text("using now").font(.caption2).foregroundStyle(.orange)
                    case .nextSelection:
                        Text("chosen for the next capture start").font(.caption2).foregroundStyle(.orange)
                    case .unavailable:
                        Text("chosen, but not available").font(.caption2).foregroundStyle(.secondary)
                    case .unknown:
                        Text("chosen — availability unknown").font(.caption2).foregroundStyle(.secondary)
                    case .none:
                        EmptyView()
                    }
                }
                // ⚠️ **One click can legitimately land on only one of the two promises**, and the menu
                // has to say which. Capture does not filter on `canBeSystemDefault` and the system
                // default does, so a device Acta can record from may be one the OS refuses as the Mac's
                // input: the recording follows, the Mac's input does not.
                if mic.managingSystemInput, device.isCaptureCandidate, !device.isSystemDefaultCandidate {
                    Text("recording only — the Mac's input will not follow")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !present {
                    Text(mic.isComplete ? "not connected" : "not readable")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !device.isCaptureCandidate {
                    Text("unavailable").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()

            if rank != nil {
                Button { model.moveMicrophone(device.uid, up: true) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain).disabled(rank == 0)
                Button { model.moveMicrophone(device.uid, up: false) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain).disabled(rank == mic.priority.count - 1)
            }
            Button("Use now") { model.useMicrophoneNow(device.uid) }
                .font(.caption)
                .disabled(!present || model.pendingSelection == device.uid)
        }
    }

    /// Feature (B): opt-in, always says so, and Pause is always reachable.
    @ViewBuilder
    private func managementControls(_ mic: ControlAPI.MicrophoneStatus) -> some View {
        Toggle("Keep the Mac's input on my list", isOn: Binding(
            get: { mic.managingSystemInput },
            set: { model.setManagingSystemInput($0) }
        ))
        .font(.callout)

        if mic.managingSystemInput {
            // ⚠️ Stated whenever it is on: the user must always be able to see that something is
            // changing a system setting on their behalf, and reach the off switch for it.
            Text("Acta is managing the Mac's input.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(enforcementText(mic.enforcement)).font(.caption)
                Spacer()
                // ⚠️ Pause suspends **global enforcement only**. Acta's own recording selection keeps
                // working while paused — different promises, and they must not share a switch.
                if case .paused = mic.enforcement {
                    Button("Resume") { model.resumeMicrophoneManagement() }.font(.caption)
                } else {
                    Button("Pause") { model.pauseMicrophoneManagement() }.font(.caption)
                }
            }
        } else {
            Text("Acta is not changing your Mac's input.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// ⚠️ **Waiting, paused, suspended and refused are four sentences, not one.** Collapsing any pair
    /// is the failure this whole feature exists to avoid: a status that reads as ordinary waiting while
    /// something is actually wrong.
    private func enforcementText(_ status: MicrophoneEnforcementStatus) -> String {
        switch status {
        case .disabled: return ""
        case .enforcing: return "Holding your preferred microphone."
        case .waitingForPreferredDevice: return "Waiting for a preferred microphone."
        case .noEligibleDevice: return "No microphone this Mac can use as its input."
        case .writesRefused: return "The system refused to switch to your microphone."
        case .uncertain: return "Holding — the audio devices could not all be read."
        case .paused: return "Paused. Your recordings still use your list."
        case .suspended(let cause):
            switch cause {
            case .repeatedReversals(let n): return "Stopped after something changed the input back \(n) times."
            case .repeatedConvergenceFailures(let n): return "Stopped after \(n) failed attempts."
            }
        case .degraded: return "Could not read the audio devices."
        }
    }

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Recordings").font(.caption).foregroundStyle(.secondary)
            if state.recordings.isEmpty {
                Text("No recordings yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(state.recordings.prefix(5), id: \.directory) { recording in
                    recordingRow(recording)
                }
            }
        }
    }

    private func recordingRow(_ recording: MeetingStore.Recording) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color(for: recording.manifest?.status)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(recording.directory.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusLabel(recording.manifest?.status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.openInFinder(recording.directory)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open folder in Finder")
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        DisclosureGroup(isExpanded: $settingsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Archive folder").font(.caption2).foregroundStyle(.secondary)
                    // The bindings merge each field into the authoritative settings and save on change,
                    // so no `.onChange` is needed here.
                    TextField("~/Acta", text: model.archivePathBinding)
                        .textFieldStyle(.roundedBorder)
                }

                Stepper(value: model.segmentSecondsBinding,
                        in: RecordingSettings.minSegmentSeconds...RecordingSettings.maxSegmentSeconds,
                        step: 5) {
                    Text("Segment length: \(state.settings.segmentSeconds) s").font(.caption)
                }

                Toggle("Delete segments after assembly", isOn: model.deleteSegmentsBinding)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.top, 6)
            .disabled(isBusy)
        } label: {
            Label("Settings", systemImage: "gearshape").font(.caption)
        }
    }

    // MARK: - Banner

    private func banner(_ text: String, systemImage: String, tint: Color,
                        dismiss: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Status presentation

    /// The status header is derived from `ControlState`, reproducing today's phase-driven header: a
    /// lifecycle failure reads as "Error" (a fatal stall shows it while the operation is still
    /// `.saving`, exactly as `phase == .error` did); otherwise the operation drives it, and
    /// `.starting` keeps the idle header just as the controller kept `phase == .idle` during a start.
    private var statusIcon: String {
        if state.lifecycleFailure != nil { return "exclamationmark.triangle.fill" }
        switch state.operation {
        case .idle, .starting: return "waveform"
        case .recording: return "record.circle.fill"
        case .saving: return "square.and.arrow.down"
        }
    }

    private var statusColor: Color {
        if state.lifecycleFailure != nil { return .red }
        switch state.operation {
        case .idle, .starting, .saving: return .secondary
        case .recording: return .red
        }
    }

    private var statusText: String {
        if state.lifecycleFailure != nil { return "Error" }
        switch state.operation {
        case .idle, .starting: return "Ready to record"
        case .recording: return "Recording"
        case .saving: return "Saving…"
        }
    }

    private func color(for status: SessionManifest.Status?) -> Color {
        switch status {
        case .done: return .green
        case .recovered: return .orange
        case .recording: return .red
        case nil: return .gray
        }
    }

    private func statusLabel(_ status: SessionManifest.Status?) -> String {
        switch status {
        case .done: return "saved"
        case .recovered: return "recovered"
        case .recording: return "unfinished"
        case nil: return "—"
        }
    }
}
