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
        MenuBarExtra(AppInfo.name, systemImage: "waveform") {
            if #available(macOS 15.0, *) {
                MenuContent()
            } else {
                UnsupportedContent()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Needed for exactly one thing: to provide an "app has launched" entry point. Recovery of
/// interrupted recordings must run at startup (SPEC §7), and a menu bar with
/// `menuBarExtraStyle(.window)` builds its content only when the user clicks — no SwiftUI hook
/// fires before the menu is opened for the first time.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 15.0, *) {
            RecordingController.shared.onLaunch()
        }
    }

    /// Prevent quitting from cutting off an active recording. Without this, "Quit" during a
    /// recording is no different from `kill -9`: the current segment stays unfinalised, the marker
    /// stays `recording`, and up to `segmentSeconds` of audio is lost. Recovery does handle that,
    /// but it exists for crashes, not for a deliberate user action — here the recording must be
    /// honestly finished and assembled.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard #available(macOS 15.0, *) else { return .terminateNow }
        // AppKit calls this method on the main thread, which is where the controller lives.
        return MainActor.assumeIsolated {
            let controller = RecordingController.shared
            guard controller.hasWorkInFlight else { return .terminateNow }
            Task {
                await controller.stopAndWait()
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
            Text(AppInfo.name).font(.headline)
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
    // The instance is shared with `AppDelegate` (which kicks off recovery at startup), hence
    // `Observed` rather than `StateObject`: the view does not own its lifetime.
    @ObservedObject private var controller = RecordingController.shared
    @State private var settingsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            if !controller.recoveredBanner.isEmpty {
                banner(controller.recoveredBanner, systemImage: "arrow.clockwise.circle.fill",
                       tint: .orange) { controller.dismissRecoveredBanner() }
            }
            if !controller.errorMessage.isEmpty {
                banner(controller.errorMessage, systemImage: "exclamationmark.triangle.fill",
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
                Button("Open Archive") { controller.openArchive() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { controller.onAppear() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppInfo.name).font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isRecording {
                Text(controller.elapsedString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Title").font(.caption).foregroundStyle(.secondary)
            TextField(controller.suggestedTitle.isEmpty ? "Meeting title"
                                                        : controller.suggestedTitle,
                      text: $controller.title)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isBusy)
        }
    }

    private var controls: some View {
        HStack {
            if controller.isStarting {
                // `SCStream` is already capturing into segments here, while `phase` is still `.idle`
                // (it flips only at the end of `performStart`, after the ~2 s self-check). Showing an
                // enabled "Start Recording" would be a dead click on a live recording.
                Button {} label: {
                    Label("Starting…", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .disabled(true)
            } else if controller.isSaving {
                Button {} label: {
                    Label("Saving…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(true)
            } else if controller.isRecording {
                Button {
                    controller.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
            } else {
                Button {
                    controller.start()
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
            if controller.recordings.isEmpty {
                Text("No recordings yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(controller.recordings.prefix(5), id: \.directory) { recording in
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
                controller.openInFinder(recording.directory)
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
                    TextField("~/Acta", text: $controller.settings.archivePath)
                        .textFieldStyle(.roundedBorder)
                }

                Stepper(value: $controller.settings.segmentSeconds,
                        in: RecordingSettings.minSegmentSeconds...RecordingSettings.maxSegmentSeconds,
                        step: 5) {
                    Text("Segment length: \(controller.settings.segmentSeconds) s").font(.caption)
                }

                Toggle("Delete segments after assembly",
                       isOn: $controller.settings.deleteSegmentsAfterAssembly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.top, 6)
            .disabled(controller.isBusy)
            .onChange(of: controller.settings) { controller.saveSettings() }
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

    private var statusIcon: String {
        switch controller.phase {
        case .idle: return "waveform"
        case .recording: return "record.circle.fill"
        case .saving: return "square.and.arrow.down"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .idle: return .secondary
        case .recording: return .red
        case .saving: return .secondary
        case .error: return .red
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: return "Ready to record"
        case .recording: return "Recording"
        case .saving: return "Saving…"
        case .error: return "Error"
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
