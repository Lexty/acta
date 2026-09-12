import ActaKit
import ActaRuntime
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
        .task { await model.subscribe() }
        .onAppear { model.refresh(); model.refreshMicrophone() }
    }
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

            Section {
                Toggle("Offer to stop when the app that started the recording releases the microphone",
                       isOn: model.offersStopOnReleaseBinding)
                // ⚠️ **Three things this copy has to be honest about**, and each of them was a decision
                // rather than a wording choice. It does not claim the call ended — Acta saw an
                // application let the input go, which is not the same fact. It is the one place Acta
                // acts without a click, so the countdown is named. And it applies only to recordings
                // Acta itself offered to start, because only those carry a known application; the user
                // would otherwise reasonably expect it on a recording they started from the menu. An app
                // the system names only by a process id is never bound, and the copy says so.
                Text("Only for recordings Acta offered to start for an app it could identify — those "
                     + "know which app the call belonged to. Acta asks first and waits; if you do not "
                     + "answer, it stops the "
                     + "recording when the countdown ends. Separate from the quiet reminder above.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("When the app lets the microphone go")
            }
        }
        .formStyle(.grouped)
    }
}
