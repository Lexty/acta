import AVFoundation
import CoreGraphics

/// Проверка и запрос TCC-разрешений, нужных для записи: Screen Recording (системный звук через
/// ScreenCaptureKit) и Microphone. Обе проверки — рантайм; UI/самодиагностика (Task 4/6)
/// решают, что делать по статусу. Здесь — тонкая обёртка над системными API без побочной логики.
enum Permissions {
    /// Есть ли разрешение Screen Recording (нужно даже для audio-only захвата через SCStream).
    ///
    /// `CGPreflightScreenCaptureAccess()` не показывает системный диалог — только читает статус.
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Запросить Screen Recording. Первый вызов показывает системный диалог; возвращает текущий
    /// статус синхронно (macOS может потребовать перезапуск приложения после выдачи права).
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Есть ли разрешение на микрофон прямо сейчас.
    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Статус доступа к микрофону (для диагностики: `notDetermined`/`denied`/`restricted`).
    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Запросить доступ к микрофону (системный диалог при `notDetermined`).
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
