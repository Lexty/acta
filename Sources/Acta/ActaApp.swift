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
        .onAppear { model.refresh() }
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
