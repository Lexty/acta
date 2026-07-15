import SwiftUI
import ActaKit

/// Точка входа. Menu-bar приложение (`LSUIElement=true`, без иконки в доке).
/// Захват (`SCStream` + микрофон) требует macOS 15, поэтому рабочий UI доступен с неё; на более
/// старых системах показываем понятную заглушку вместо «немого» меню.
@main
struct ActaApp: App {
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
    @StateObject private var controller = RecordingController()

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
            HStack {
                Button("Открыть архив") { controller.openInFinder(MeetingStore.defaultArchiveRoot()) }
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
            TextField("Название встречи", text: $controller.title)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isRecording)
        }
    }

    private var controls: some View {
        HStack {
            if controller.isRecording {
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
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .idle: return .secondary
        case .recording: return .red
        case .error: return .red
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: return "Готов к записи"
        case .recording: return "Идёт запись"
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
