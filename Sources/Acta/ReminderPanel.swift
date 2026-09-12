import ActaKit
import ActaRuntime
import AppKit
import SwiftUI

/// The reminder panel: Acta's own floating prompt, not a system notification.
///
/// ⚠️ **Why this exists at all, measured rather than assumed.** A `UNUserNotificationCenter` banner does
/// not show its action buttons: they appear on hover, in both the Temporary and Persistent alert styles,
/// verified on this machine with a notification carrying a registered two-action category. The whole
/// point of this feature is one press without hunting, so the system surface cannot deliver it. The app
/// also cannot choose the alert style — `UNNotificationSettings.alertStyle` is read-only — and cannot
/// mark a notification time-sensitive without an entitlement it does not have.
///
/// ⚠️ **It is therefore an in-app reminder, and must be described as one.** It is not a notification, it
/// does not respect Focus, and nothing here should claim it is invisible during screen sharing.
///
/// ⚠️ **No default key equivalent, deliberately.** The panel appears while the user is typing into a
/// meeting; a Return or Space that answered it would be answered by accident.
@available(macOS 15.0, *)
@MainActor
final class ReminderPanelController {
    private var panel: NSPanel?
    private var dismissal: Timer?
    private var clickMonitor: Any?
    private weak var coordinator: ReminderCoordinator?

    /// How long each prompt stays up. **Expiry is always the safe outcome**: an expired offer to record
    /// records nothing, and an expired offer to stop keeps recording.
    private static func lifetime(of prompt: ReminderPrompt) -> TimeInterval {
        switch prompt {
        case .offerToRecord: return 20
        case .offerToStop: return 30    // a heavier decision deserves longer
        // ⚠️ Long enough to outlive a slow start: capture can take a couple of seconds to confirm, and a
        // panel that vanished first would leave the click looking like it did nothing.
        case .startingRecording: return 12
        case .startedRecording: return 3
        }
    }

    func present(_ prompt: ReminderPrompt, coordinator: ReminderCoordinator) {
        self.coordinator = coordinator
        let content = ReminderPanelView(prompt: prompt, coordinator: coordinator)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: hosting.fittingSize.height)

        let existing = panel ?? makePanel()
        panel = existing
        existing.contentView = hosting
        existing.setContentSize(hosting.fittingSize)
        position(existing)
        existing.orderFrontRegardless()

        arm(lifetime: Self.lifetime(of: prompt), for: prompt)
        watchForClicksOutside(for: prompt)
    }

    func dismiss() {
        dismissal?.invalidate()
        dismissal = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        panel?.orderOut(nil)
    }

    // MARK: - The window

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        // Above a full-screen conference window, which is the likeliest thing in front of it.
        panel.level = .statusBar
        // ⚠️ Joins the current Space rather than switching to its own: a prompt that yanks the user out
        // of their meeting to answer a question about the meeting is worse than no prompt.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    /// Top right of the display the pointer is on, under the menu bar.
    ///
    /// ⚠️ **The display is chosen once, when the prompt appears, and not revisited.** A panel that
    /// follows the mouse between screens is a panel you cannot click.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: frame.maxX - size.width - 12,
                             y: frame.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    /// ⚠️ **Scoped to the prompt it was armed for.** These callbacks hop through a `Task`, so an expiry
    /// enqueued for prompt A can land after prompt B has replaced it; dismissing "whatever is showing"
    /// would take B off the screen a fraction of a second after it appeared.
    private func arm(lifetime: TimeInterval, for prompt: ReminderPrompt) {
        dismissal?.invalidate()
        dismissal = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
            Task { @MainActor in
                // ⚠️ Expiry dismisses. It never answers.
                self?.coordinator?.dismiss(prompt)
            }
        }
    }

    private func watchForClicksOutside(for prompt: ReminderPrompt) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in self?.coordinator?.dismiss(prompt) }
        }
    }
}

// MARK: - The content

@available(macOS 15.0, *)
private struct ReminderPanelView: View {
    let prompt: ReminderPrompt
    let coordinator: ReminderCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch prompt {
            case .offerToRecord(let episodeID, let application, let bundleID, let title, let mic):
                offerToRecord(episodeID: episodeID, application: application, bundleID: bundleID,
                              title: title, microphone: mic)
            case .offerToStop(let recordingID, let title, let elapsed):
                offerToStop(recordingID: recordingID, title: title, elapsed: elapsed)
            case .startingRecording(let title):
                started(title: title, confirmed: false)
            case .startedRecording(let title):
                started(title: title, confirmed: true)
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Offer to record

    @ViewBuilder
    private func offerToRecord(episodeID: UInt64, application: String?, bundleID: String?,
                               title: String, microphone: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            tile(systemImage: application == nil ? "questionmark.circle" : "mic",
                 tint: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                // ⚠️ **An observation, never a conclusion.** The HAL says a process runs audio input; it
                // does not say a meeting started. And the name is shown only when the system gave one
                // for a regular application — a browser helper's own name describes a meeting worse
                // than saying nothing.
                Text(application.map { "Microphone activity in \($0)" }
                        ?? "Microphone activity detected")
                    .font(.headline)
                Text(application == nil
                     ? "Another app is using the microphone."
                     : "Record this call?")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Text("Will save as “\(title)”").font(.caption).foregroundStyle(.secondary)
            Text(microphone).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.leading, 32).padding(.top, 8)
        .lineLimit(1)

        Button { coordinator.acceptStart(episodeID: episodeID) } label: {
            Label("Start Recording", systemImage: "record.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.top, 10)

        HStack {
            Button("Not now") { coordinator.declineStart(episodeID: episodeID) }
                .buttonStyle(.plain).font(.caption)
            Spacer()
            if let bundleID {
                Button(application.map { "Never for \($0)" } ?? "Never for this app") {
                    coordinator.excludeApplication(bundleID: bundleID, episodeID: episodeID)
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Offer to stop

    @ViewBuilder
    private func offerToStop(recordingID: UInt64, title: String, elapsed: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            tile(systemImage: "speaker.slash", tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                // ⚠️ "Little audio activity", not "silence": what is measured is energy, not speech.
                Text("Little audio activity").font(.headline)
                Text("Neither the microphone nor the system has been active.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("Recording \(MeetingInfo.formatDuration(seconds: elapsed))")
                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.leading, 32).padding(.top, 8)

        Button { coordinator.acceptStop(recordingID: recordingID) } label: {
            Label("Stop & Save", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .padding(.top, 10)

        HStack {
            Button("Keep Recording") { coordinator.keepRecording() }
                .buttonStyle(.plain).font(.caption)
            Spacer()
            Button("Remind me in 30 min") { coordinator.snooze(recordingID: recordingID) }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    /// ⚠️ **"Starting…" until capture confirms.** Acta's oldest rule is that it never reports recording
    /// while data is not being written, and a start is asynchronous: it can still fail on a permission, a
    /// device, or the self-check that exists to catch exactly this.
    @ViewBuilder
    private func started(title: String, confirmed: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            tile(systemImage: confirmed ? "record.circle" : "clock", tint: confirmed ? .red : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(confirmed ? "Recording" : "Starting…").font(.headline)
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func tile(systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 13))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
    }
}
