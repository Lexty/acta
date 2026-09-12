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
///
/// ⚠️ **It is the coordinator's presenter, and keeps its half of that contract.** It acknowledges a
/// presentation only once the panel is ordered in and its window reports itself visible, reports a
/// presentation lost when the screen locks or sleeps or the window stops being visible, and updates a
/// countdown **in place** — see `updateCountdown(_:)`. What it cannot prove is that a person saw it:
/// rendered visibility is human acceptance, not something this class or its tests establish.
@available(macOS 15.0, *)
@MainActor
final class ReminderPanelController: ReminderPresenting {
    private var panel: NSPanel?
    private var hosting: NSHostingView<ReminderPanelView>?
    private var dismissal: Timer?
    private var clickMonitor: Any?
    private weak var coordinator: ReminderCoordinator?
    /// The presentation on screen, if any.
    private var shownID: UInt64?
    /// A presentation shown but not yet visible, waiting for its window to say so.
    private var awaitingAcknowledgement: UInt64?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// What currently makes presentation impossible, by the notification that began it.
    private var suppressions: Set<Suppression> = []

    private enum Suppression {
        case systemSleep, displaySleep, sessionInactive, screenLocked
    }

    init(coordinator: ReminderCoordinator) {
        self.coordinator = coordinator
        watchForLostPresentation()
    }

    /// How long each prompt stays up. **Expiry is always the safe outcome**: an expired offer to record
    /// records nothing, and an expired offer to stop keeps recording.
    private static func lifetime(of prompt: ReminderPrompt) -> TimeInterval {
        switch prompt {
        case .offerToRecord: return 20
        case .offerToStop: return 30    // a heavier decision deserves longer
        // ⚠️ Outlasts the twenty-second countdown by the ten seconds the panel has to reach the screen. Its
        // expiry is not a decline: the coordinator ignores it while the countdown runs, and ends a countdown
        // that was never acknowledged as a lost presentation — see `ReminderCoordinator.expire(_:)`.
        case .offerToStopOnRelease: return 30
        // ⚠️ Long enough to outlive a slow start: capture can take a couple of seconds to confirm, and a
        // panel that vanished first would leave the click looking like it did nothing.
        case .startingRecording: return 12
        case .startedRecording: return 3
        // ⚠️ Long enough to read, short enough not to sit in the way. Both are answers to a press, so
        // the user is looking at the panel when they appear.
        case .checkingStart: return 12
        case .startNoLongerAvailable: return 6
        }
    }

    /// A new prompt: build, place, arm, watch. Everything `updateCountdown(_:)` must not repeat.
    func show(_ presentation: ReminderPresentation) {
        guard let coordinator else { return }
        let prompt = presentation.prompt
        let content = ReminderPanelView(presentation: presentation, coordinator: coordinator)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: hosting.fittingSize.height)
        self.hosting = hosting

        let existing = panel ?? makePanel()
        panel = existing
        existing.contentView = hosting
        existing.setContentSize(hosting.fittingSize)
        position(existing)
        existing.orderFrontRegardless()

        shownID = presentation.id
        awaitingAcknowledgement = presentation.id
        arm(lifetime: Self.lifetime(of: prompt), for: presentation.id)
        // ⚠️ **A click elsewhere is not an answer to a countdown.** It dismisses an offer that acts on
        // nothing, which is harmless; on a countdown it would be a decline, and the person the feature is for
        // — back in another app after the call — clicks somewhere within twenty seconds as a matter of
        // course. The countdown carries its two answers as buttons and needs no third.
        if presentation.secondsRemaining == nil {
            watchForClicksOutside(for: prompt)
        } else if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        acknowledgeIfVisible()
    }

    /// The same prompt, a new number.
    ///
    /// ⚠️ **Only the content changes.** `show` re-places the panel from the pointer, re-arms the dismissal
    /// timer and reinstalls the click monitor; doing that once a second would walk the panel across the
    /// screen and reset its dismissal forever. The size is left alone too — resizing a window moves its
    /// top edge, which is the edge anchored under the menu bar.
    func updateCountdown(_ presentation: ReminderPresentation) {
        guard presentation.id == shownID, let hosting, let coordinator else { return }
        hosting.rootView = ReminderPanelView(presentation: presentation, coordinator: coordinator)
    }

    func withdraw(_ presentationID: UInt64) {
        guard presentationID == shownID else { return }
        dismiss()
    }

    func dismiss() {
        shownID = nil
        awaitingAcknowledgement = nil
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
        // ⚠️ Occlusion is the window server's own answer to "can this be seen", which is the closest thing
        // to presentation this process can observe. Visible acknowledges; not visible loses it.
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                       object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        }
        observers.append((center, token))
        return panel
    }

    // MARK: - Presentation evidence

    /// ⚠️ **A lock or a sleep still in force answers "not visible" on its own**, without asking the window
    /// server: whether occlusion reports a panel ordered in under the lock shield as visible has not been
    /// measured here, and an offer raised onto a screen that is *already* locked gets no lock notification
    /// to lose it.
    private var isVisibleOnScreen: Bool {
        guard let panel, suppressions.isEmpty else { return false }
        return panel.isVisible && panel.occlusionState.contains(.visible)
    }

    private func acknowledgeIfVisible() {
        guard let pending = awaitingAcknowledgement, isVisibleOnScreen else { return }
        awaitingAcknowledgement = nil
        coordinator?.acknowledgePresentation(pending)
    }

    private func occlusionChanged() {
        guard let shownID else { return }
        if awaitingAcknowledgement != nil {
            acknowledgeIfVisible()
        } else if !isVisibleOnScreen {
            coordinator?.presentationLost(shownID)
        }
    }

    /// ⚠️ **A lock or a display sleep takes away the interval a countdown promised**, whether or not the
    /// window server reports an occlusion change for it. Each is reported as lost; the coordinator
    /// decides what that withdraws, and it withdraws nothing but a countdown.
    ///
    /// ⚠️ **And it lasts until its own end is observed.** Reporting the loss once is not enough: the
    /// release stays qualified behind the lock, so a fresh offer is raised a few seconds later onto the same
    /// locked screen. Each state is held by the notification that began it and cleared only by its own
    /// counterpart — a wake does not unlock — and while any is held nothing is acknowledged. A counterpart
    /// that never arrives leaves offers unacknowledged, which keeps recording.
    private func watchForLostPresentation() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pairs: [(NotificationCenter, Notification.Name, Notification.Name, Suppression)] = [
            (workspace, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, .systemSleep),
            (workspace, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
             .displaySleep),
            (workspace, NSWorkspace.sessionDidResignActiveNotification,
             NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive),
            (distributed, Notification.Name("com.apple.screenIsLocked"),
             Notification.Name("com.apple.screenIsUnlocked"), .screenLocked),
        ]
        for (center, began, ended, suppression) in pairs {
            let beganToken = center.addObserver(forName: began, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suppress(suppression) }
            }
            let endedToken = center.addObserver(forName: ended, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume(suppression) }
            }
            observers.append((center, beganToken))
            observers.append((center, endedToken))
        }
    }

    private func suppress(_ suppression: Suppression) {
        suppressions.insert(suppression)
        guard let shownID else { return }
        coordinator?.presentationLost(shownID)
    }

    /// A presentation still waiting is acknowledged only now, and only if the window server agrees.
    private func resume(_ suppression: Suppression) {
        suppressions.remove(suppression)
        acknowledgeIfVisible()
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

    /// ⚠️ **Scoped to the presentation it was armed for.** These callbacks hop through a `Task`, so an
    /// expiry enqueued for presentation A can land after B has replaced it; dismissing "whatever is
    /// showing" would take B off the screen a fraction of a second after it appeared. The id, not the
    /// prompt: two release offers for one recording are equal prompts.
    private func arm(lifetime: TimeInterval, for presentationID: UInt64) {
        dismissal?.invalidate()
        dismissal = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
            Task { @MainActor in
                // ⚠️ Expiry never answers. The coordinator decides what it ends, and a countdown's is not a decline.
                self?.coordinator?.expire(presentationID)
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
    let presentation: ReminderPresentation
    let coordinator: ReminderCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch presentation.prompt {
            case .offerToRecord(let episodeID, let application, let bundleID, let title, let mic):
                offerToRecord(episodeID: episodeID, application: application, bundleID: bundleID,
                              title: title, microphone: mic)
            case .offerToStop(let recordingID, let title, let elapsed):
                offerToStop(recordingID: recordingID, title: title, elapsed: elapsed)
            case .offerToStopOnRelease(let recordingID, let title, let text):
                offerToStopOnRelease(recordingID: recordingID, title: title, text: text,
                                     secondsRemaining: presentation.secondsRemaining)
            case .startingRecording(let title):
                started(title: title, confirmed: false)
            case .startedRecording(let title):
                started(title: title, confirmed: true)
            case .checkingStart(_, let title):
                checking(title: title)
            case .startNoLongerAvailable:
                noLongerAvailable()
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

    // MARK: Offer to stop on release

    /// ⚠️ **Every sentence comes from `OwnerReleaseOfferText`.** This decides layout and colour only; what
    /// the prompt says about the application, and about what happens at zero, is a tested projection.
    @ViewBuilder
    private func offerToStopOnRelease(recordingID: UInt64, title: String, text: OwnerReleaseOfferText,
                                      secondsRemaining: Int?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            tile(systemImage: "mic.slash", tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.headline).font(.headline)
                Text(text.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let secondsRemaining {
                Text(OwnerReleaseOfferText.countdown(seconds: secondsRemaining))
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.leading, 32).padding(.top, 8)

        Button { coordinator.acceptReleaseStop(recordingID: recordingID) } label: {
            Label(OwnerReleaseOfferText.stopNow, systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .padding(.top, 10)

        HStack {
            Button(OwnerReleaseOfferText.keepRecording) {
                coordinator.keepRecordingAfterRelease(recordingID: recordingID)
            }
            .buttonStyle(.plain).font(.caption)
            Spacer()
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

    /// ⚠️ **The press is acknowledged before its outcome is known.** Between the click and the answer
    /// the app awaits the microphone-settings barrier, which is not instant; this is what the user looks
    /// at meanwhile. It does **not** say "Recording" — nothing is recording yet.
    @ViewBuilder
    private func checking(title: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            tile(systemImage: "clock", tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Checking…").font(.headline)
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// ⚠️ **It names the offer, never the meeting.** Acta lost sight of an application's microphone
    /// input; that is not evidence the call ended, and saying so would be stating a fact nobody has.
    /// The second line is the way forward rather than an apology.
    @ViewBuilder
    private func noLongerAvailable() -> some View {
        HStack(alignment: .top, spacing: 8) {
            tile(systemImage: "clock.badge.xmark", tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("This offer is no longer available").font(.headline)
                Text("Open Acta to start a recording.")
                    .font(.caption).foregroundStyle(.secondary)
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
