import SwiftUI
import ActaKit

/// Точка входа. Menu-bar приложение (`LSUIElement=true`, без иконки в доке).
/// На этой стадии — пустой каркас `MenuBarExtra`; логика записи добавляется в следующих задачах.
@main
struct ActaApp: App {
    var body: some Scene {
        MenuBarExtra(AppInfo.name, systemImage: "waveform") {
            MenuContent()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Содержимое меню-бара. Пока заглушка — старт/стоп/список добавятся в Task 6.
struct MenuContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppInfo.name)
                .font(.headline)
            Text("Запись онлайн-встреч")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Выход") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}
