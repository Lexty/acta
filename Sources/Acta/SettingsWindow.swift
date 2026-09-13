import ActaKit
import ActaRuntime
import AppKit
import SwiftUI

/// Acta's Settings window.
///
/// ⚠️ **Why persistent configuration left the menu.** The panel is 300 pt wide and opens under the menu
/// bar; a disclosure inside it can hold three controls, and the reminders need six plus a list of
/// applications. A list is not a control — it needs rows and a way to remove them — and two expandable
/// sections in one popover can already run off the bottom of a laptop screen. So configuration lives
/// here, and the panel keeps only what is needed *at the moment of acting*.
///
/// ⚠️ **What deliberately did not move.** Which microphone a recording will use, the temporary choice and
/// its undo, and the enforcement status with its immediate Pause / Resume / Turn off stay in the panel.
/// That last one is an obligation, not a preference: Acta is changing a system-wide setting other
/// applications depend on, and the answer to that must not require opening a window.
@available(macOS 15.0, *)
struct ActaSettingsView: View {
    @StateObject private var model = ControlViewModel()
    /// ⚠️ **Shared, not owned by this view, and not observed.** The menu's Settings row has to reach the
    /// same presenter: asking for Settings when the window is already open raises no `onAppear` at all,
    /// so a presenter scoped to the view could never be told about that request. It publishes nothing —
    /// it is a way to reach one window, not view state — so it is referenced, not wrapped.
    private var presenter: SettingsWindowPresenter { .shared }

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            MicrophoneSettings(model: model)
                .tabItem { Label("Microphone", systemImage: "mic") }
            ReminderSettings(model: model)
                .tabItem { Label("Reminders", systemImage: "bell") }
        }
        .frame(width: 470)
        // ⚠️ **The window has to be fetched from the view it hosts**, not looked up by name in
        // `NSApp.windows`: the Settings scene's window identifier is SwiftUI's own and not something
        // this app may rely on. `view.window` is the same window whichever way it was opened, which is
        // what keeps ⌘, and the menu row fixed by one piece of code.
        .background(SettingsWindowHost(presenter: presenter))
        .task { await model.subscribe() }
        .onAppear {
            model.refresh()
            model.refreshMicrophone()
            // ⚠️ **An appearance is one kind of request, and not the only kind.** It covers ⌘, and the
            // first open; a request for a window that is already up raises no appearance, which is why
            // the menu row calls `settingsRequested()` itself.
            presenter.settingsRequested()
        }
    }
}

/// Where the Settings window opens for an app that has **no Dock icon**.
///
/// ⚠️ **The defect: settings opened behind a full-screen app.** Acta is `LSUIElement`, so clicking a row
/// in the menu bar never makes it the active application — and a window of an inactive accessory app is
/// ordered into the Space it was born in, which is the desktop. With a full-screen terminal in front,
/// the window was placed *behind* it: the only way to reach settings was to unstack every window and go
/// looking. ⌘, hid the same defect, because a key equivalent can only arrive at an app that is already
/// frontmost.
///
/// ⚠️ **Two behaviours, and the window needs both.** `activate()` makes Acta frontmost so the window is
/// ordered in front of the applications it is layered against; `.moveToActiveSpace` decides *where* —
/// without it, activating switches the user out of their full-screen Space to wherever the window happens
/// to live, which answers the complaint by doing something worse. `.fullScreenAuxiliary` is what lets a
/// window be shown alongside a full-screen one at all. ⚠️ **Which of them is doing the work has not been
/// established**: the window was measured raising correctly both with that bit and, after macOS dropped
/// it, without. Separating them needs a controlled comparison, so this prose claims no more than the
/// header does about each flag.
///
/// ⚠️ **Deliberately not the reminder panel's treatment.** That is a `.statusBar`-level non-activating
/// panel on `.canJoinAllSpaces`, because it must appear over a meeting without stealing the keystroke
/// the user is typing into it. Settings is the opposite: it is asked for, it takes focus, and it belongs
/// to one Space at a time — a settings window that followed the user onto every Space would be a
/// window they cannot get rid of.
///
/// ## Three things that were wrong in the first version of this, each found by measurement
///
/// - **A request for Settings is not an appearance of the view.** Asking for a window that is already
///   open raises no `onAppear`, so nothing ran and the window stayed where it was — the user's original
///   complaint, reached by a different route. Raising is therefore driven from `settingsRequested()`,
///   which the menu row calls on every click, and from the appearance, which covers ⌘, and the first
///   open.
/// - **The configuration does not survive a close.** Measured in the app: the mask set at adoption held
///   for at least half a second and was gone within two, and the reopened window came back without
///   `fullScreenAuxiliary` and never regained it. So it is written on **every** raise, not once.
/// - **`formUnion` produced a mask `NSWindow.h` forbids.** The group is replaced rather than joined; the
///   arithmetic and its tests are in `WindowCollectionPolicy`.
///
/// ⚠️ **Still not covered, and it needs a person.** Whether ⌘, reaches an already-open window that is on
/// another Space: the key equivalent goes through SwiftUI's own menu item, which this cannot intercept
/// without replacing it, and the menu row is the path the reported incident used.
@available(macOS 15.0, *)
@MainActor
final class SettingsWindowPresenter {
    /// ⚠️ **One presenter for the whole application**, because the two things that ask for Settings live
    /// in different view trees — the menu row and the settings view itself — and both must reach the
    /// same window.
    static let shared = SettingsWindowPresenter()

    private weak var window: NSWindow?

    private init() {}

    /// The hosting view says it is now in `window`, or — `nil` — that it has been detached.
    ///
    /// ⚠️ **Attachment is reported, never assumed.** The first version dispatched once to the next turn
    /// of the run loop and read `view.window` there; if the view was not attached yet that was the only
    /// attempt, and the window would have kept its default behaviour with nothing to say so. Detachment
    /// is carried too, so a stale window is never raised.
    fileprivate func adopt(_ window: NSWindow?) {
        guard window !== self.window else { return }
        self.window = window
        guard window != nil else { return }
        raise()
    }

    /// Someone asked for Settings — the menu row, or the view appearing.
    ///
    /// ⚠️ **Deferred by one turn of the run loop, and that is not tidiness.** SwiftUI finishes presenting
    /// the window *after* the synchronous callback returns, and what it writes then removes
    /// `.fullScreenAuxiliary`; a mask written before that is overwritten. Measured both here and
    /// independently on a separate probe. ⚠️ This is one arrangement that was observed to hold, not a
    /// guarantee about run-loop ordering — if the window is ever seen coming up unconfigured again, this
    /// is the line to suspect.
    func settingsRequested() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.raise() }
        }
    }

    /// Put the window in front of the user, wherever the user currently is, and configure it to be
    /// allowed there.
    ///
    /// ⚠️ **Only from an act of asking for it**, and never from a view update. `ControlViewModel`
    /// publishes while a recording runs, so raising the window on every update would drag the user out of
    /// whatever they were doing, once a second, for as long as the window stayed open.
    private func raise() {
        guard let window else { return }
        // ⚠️ Written every time. See the class comment: a close throws this away.
        window.collectionBehavior = NSWindow.CollectionBehavior(
            rawValue: WindowCollectionPolicy.settingsWindow(from: window.collectionBehavior.rawValue))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// The one job of this view is to tell the presenter which `NSWindow` it is in.
@available(macOS 15.0, *)
private struct SettingsWindowHost: NSViewRepresentable {
    let presenter: SettingsWindowPresenter

    /// ⚠️ **`viewDidMoveToWindow` rather than a deferred read of `view.window`.** AppKit calls this when
    /// the view is actually attached — and again when it is detached, and again on re-attachment — so
    /// there is no turn of the run loop to guess at and no single attempt to miss.
    final class Probe: NSView {
        weak var presenter: SettingsWindowPresenter?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated { presenter?.adopt(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe(frame: .zero)
        probe.presenter = presenter
        return probe
    }

    // ⚠️ **Empty on purpose.** A view update is not a request for the window, and raising from here would
    // reclaim focus once a second for as long as a recording runs.
    func updateNSView(_ nsView: Probe, context: Context) {}
}

// MARK: - General

@available(macOS 15.0, *)
private struct GeneralSettings: View {
    @ObservedObject var model: ControlViewModel

    private var isBusy: Bool { model.state.operation != .idle }

    var body: some View {
        Form {
            Section {
                TextField("Archive folder", text: model.archivePathBinding,
                          prompt: Text("~/Acta"))
                    // ⚠️ The same restriction the menu had, carried across with the control rather than
                    // left behind: relocating the archive mid-recording would strand the segments.
                    .disabled(isBusy)
                if isBusy {
                    Text("The archive folder cannot be moved while a recording is in progress.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Archive")
            }

            Section {
                Stepper(value: model.segmentSecondsBinding,
                        in: RecordingSettings.minSegmentSeconds...RecordingSettings.maxSegmentSeconds,
                        step: 5) {
                    Text("Segment length: \(model.state.settings.segmentSeconds) s")
                }
                .disabled(isBusy)
                Toggle("Delete segments after assembly", isOn: model.deleteSegmentsBinding)
                    .disabled(isBusy)
                Text("Shorter segments lose less to a crash and make more files.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Advanced recording")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Microphone

@available(macOS 15.0, *)
private struct MicrophoneSettings: View {
    @ObservedObject var model: ControlViewModel

    var body: some View {
        let mic = model.microphone
        Form {
            Section {
                Picker("Recordings use", selection: Binding(
                    get: { mic.captureChoice },
                    set: { model.setCaptureChoice($0) })) {
                    Text("my list").tag(CaptureMicrophoneChoice.followPriority)
                    Text("the Mac's input at the time").tag(CaptureMicrophoneChoice.systemDefault)
                }
                Text(mic.listExplanation).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Capture")
            }

            Section {
                if mic.priority.isEmpty, mic.devices.isEmpty {
                    Text(mic.isComplete ? "No microphones found."
                                        : "The audio devices could not be read.")
                        .foregroundStyle(.secondary)
                }
                // ⚠️ Priority order first, including devices that are not connected: a preference the
                // user can no longer see is a preference they cannot remove.
                ForEach(Array(mic.priority.enumerated()), id: \.element) { index, uid in
                    row(uid: uid, rank: index, mic: mic)
                }
                ForEach(mic.devices.filter { !mic.priority.contains($0.uid) }, id: \.uid) { device in
                    row(uid: device.uid, rank: nil, mic: mic)
                }
            } header: {
                Text(mic.priority.isEmpty ? "Available microphones" : "Your list")
            }

            Section {
                Toggle("Keep the Mac's input on my list", isOn: Binding(
                    get: { mic.managingSystemInput },
                    set: { model.setManagingSystemInput($0) }))
                Text(mic.managingSystemInput
                     ? "Acta changes the Mac's input device, which every other application shares. "
                       + "Its current state, and Pause, stay in Acta's menu."
                     : "Off: Acta chooses its own recording input and changes nothing outside itself.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("The Mac's input")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(uid: String, rank: Int?, mic: ControlAPI.MicrophoneStatus) -> some View {
        let device = mic.devices.first { $0.uid == uid }
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { rank != nil }, set: { _ in model.togglePreferred(uid) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device?.name ?? uid)
                    if device == nil {
                        Text(mic.isComplete ? "not connected" : "not readable")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if mic.managingSystemInput, device?.isCaptureCandidate == true,
                              device?.isSystemDefaultCandidate == false {
                        Text("recording only — the Mac's input will not follow")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            if let rank {
                Button { model.moveMicrophone(uid, up: true) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless).disabled(rank == 0)
                Button { model.moveMicrophone(uid, up: false) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless).disabled(rank == mic.priority.count - 1)
            }
        }
    }
}

// MARK: - Reminders

@available(macOS 15.0, *)
private struct ReminderSettings: View {
    @ObservedObject var model: ControlViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Offer to start recording when another app uses microphone input",
                       isOn: model.offersRecordingBinding)
                // ⚠️ **Named for what it is.** Not a system notification: it does not go through
                // Notification Centre, it is not affected by Focus, and calling it one would set an
                // expectation the app cannot keep.
                Text("A reminder from Acta, shown over your other windows — not a system notification. "
                     + "Acta never starts recording on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("When another app uses the microphone")
            }

            Section {
                if model.excludedBundleIDs.isEmpty {
                    Text("Nothing excluded. Use “Never for this app” on a reminder to add one.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.excludedBundleIDs, id: \.self) { bundleID in
                        HStack {
                            Text(bundleID).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove") { model.removeExcludedBundleID(bundleID) }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
                // ⚠️ Applications, never sites, and it says so. A call in a browser tab is held by the
                // browser's audio helper, so excluding it excludes the browser — there is no per-site
                // identity for the app to promise.
                Text("Applications only — a website inside a browser cannot be told apart from the "
                     + "browser itself.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Never ask for these apps")
            }

            Section {
                Toggle("Offer to stop after low audio activity", isOn: model.offersStopBinding)
                Picker("Offer to stop after", selection: model.quietMinutesBinding) {
                    ForEach([2, 5, 10, 15, 20, 30], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .disabled(!model.offersStopBinding.wrappedValue)
                Text("Counted only while both the microphone and the system are inactive, so listening "
                     + "to someone else does not count as quiet. Asked once per recording, and Acta "
                     + "never stops on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("When a recording goes quiet")
            }
        }
        .formStyle(.grouped)
    }
}
