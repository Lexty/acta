import SwiftUI
import ActaKit

/// Точка входа. Menu-bar приложение (`LSUIElement=true`, без иконки в доке).
/// Захват (`SCStream` + микрофон) требует macOS 15, поэтому рабочий UI доступен с неё; на более
/// старых системах показываем понятную заглушку вместо «немого» меню.
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

/// Нужен ровно ради одного: дать точку входа «приложение запустилось». Восстановление прерванных
/// записей обязано идти на старте (SPEC §7), а меню-бар с `menuBarExtraStyle(.window)` создаёт свой
/// контент только по клику пользователя — до первого открытия меню никакой SwiftUI-хук не сработает.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 15.0, *) {
            RecordingController.shared.onLaunch()
        }
    }

    /// Не дать выходу оборвать активную запись. Без этого «Выход» во время записи ничем не
    /// отличается от `kill -9`: текущий сегмент остаётся нефинализированным, маркер — `recording`,
    /// и до `segmentSeconds` звука теряется. Восстановление на такое рассчитано, но оно про крах,
    /// а не про штатное действие пользователя — здесь запись надо честно дописать и склеить.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard #available(macOS 15.0, *) else { return .terminateNow }
        // AppKit зовёт этот метод на главном потоке, где и живёт контроллер.
        return MainActor.assumeIsolated {
            let controller = RecordingController.shared
            guard controller.isBusy else { return .terminateNow }
            Task {
                await controller.stopAndWait()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}

/// Заглушка для macOS < 15 (захват микрофона одним `SCStream` появился в 15).
struct UnsupportedContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppInfo.name).font(.headline)
            Text("Требуется macOS 15 или новее.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Выход") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }
}

/// Содержимое меню-бара: старт/стоп, таймер, индикатор состояния, поле заголовка, список записей
/// и заметный показ ошибок самодиагностики (Task 6).
@available(macOS 15.0, *)
struct MenuContent: View {
    // Общий с `AppDelegate` экземпляр (он запускает восстановление на старте), поэтому `Observed`,
    // а не `StateObject`: временем жизни владеет не вью.
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
            if controller.phase == .error, !controller.errorMessage.isEmpty {
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
                Button("Открыть архив") { controller.openInFinder(controller.archiveRoot) }
                Spacer()
                Button("Выход") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { controller.onAppear() }
    }

    // MARK: - Секции

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
            Text("Заголовок").font(.caption).foregroundStyle(.secondary)
            TextField(controller.suggestedTitle.isEmpty ? "Название встречи"
                                                        : controller.suggestedTitle,
                      text: $controller.title)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isBusy)
        }
    }

    private var controls: some View {
        HStack {
            if controller.phase == .saving {
                Button {} label: {
                    Label("Сохранение…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(true)
            } else if controller.isRecording {
                Button {
                    controller.stop()
                } label: {
                    Label("Остановить", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
            } else {
                Button {
                    controller.start()
                } label: {
                    Label("Начать запись", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .tint(.accentColor)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Последние записи").font(.caption).foregroundStyle(.secondary)
            if controller.recordings.isEmpty {
                Text("Пока нет записей").font(.caption).foregroundStyle(.tertiary)
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
            .help("Открыть папку в Finder")
        }
    }

    // MARK: - Настройки

    private var settingsSection: some View {
        DisclosureGroup(isExpanded: $settingsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Папка архива").font(.caption2).foregroundStyle(.secondary)
                    TextField("~/Acta", text: $controller.settings.archivePath)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Сохранять дорожки").font(.caption2).foregroundStyle(.secondary)
                    Toggle("Системный звук (system.wav)", isOn: $controller.settings.saveSystemTrack)
                    Toggle("Микрофон (mic.wav)", isOn: $controller.settings.saveMicTrack)
                    Toggle("Микс (combined.wav)", isOn: $controller.settings.saveCombinedTrack)
                }
                .toggleStyle(.checkbox)
                .font(.caption)

                Stepper(value: $controller.settings.segmentSeconds,
                        in: RecordingSettings.minSegmentSeconds...RecordingSettings.maxSegmentSeconds,
                        step: 5) {
                    Text("Длина сегмента: \(controller.settings.segmentSeconds) с").font(.caption)
                }

                Toggle("Удалять сегменты после склейки",
                       isOn: $controller.settings.deleteSegmentsAfterAssembly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.top, 6)
            .disabled(controller.isBusy)
            .onChange(of: controller.settings) { controller.saveSettings() }
        } label: {
            Label("Настройки", systemImage: "gearshape").font(.caption)
        }
    }

    // MARK: - Баннер

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

    // MARK: - Отображение состояния

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
        case .idle: return "Готов к записи"
        case .recording: return "Идёт запись"
        case .saving: return "Сохранение…"
        case .error: return "Ошибка"
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
        case .done: return "сохранена"
        case .recovered: return "восстановлена"
        case .recording: return "не завершена"
        case nil: return "—"
        }
    }
}
