---
name: swiftpm-macos-app-bundle
description: Сборка SwiftUI menu-bar приложения через SwiftPM без Xcode (.app бандл + ad-hoc codesign + TCC). Использовать для Package.swift, Scripts/bundle.sh, Info.plist, entitlements.
---

# SwiftUI menu-bar app через SwiftPM без Xcode

> На машине только Command Line Tools (полного Xcode НЕТ). SwiftUI-приложение собирается
> через SwiftPM + ручная упаковка в `.app`. Ниже — проверенный рецепт и гатчи.

## Проверенные факты среды
- Swift 6.3.3, таргет `arm64-apple-macosx26`. `swift build`, `swift test`, `swiftc` работают.
- `MenuBarExtra` (SwiftUI scene) доступен, `@main`/`App` работают из executable-таргета SwiftPM.
- `.app` собирается вручную; TCC (Screen Recording, Microphone) требует **подписанный бандл со
  стабильной идентичностью**.

## Package.swift (скелет)
```swift
// executable target Acta + testTarget ActaTests
// dependency: .package(url: "https://github.com/argmaxinc/WhisperKit", from: "...")
// platforms: [.macOS(.v14)]
```

## Рецепт `Scripts/bundle.sh`
1. `swift build -c release` → `.build/release/Acta`.
2. Собрать бандл:
   `Acta.app/Contents/MacOS/Acta`, `Acta.app/Contents/Resources/*`, `Acta.app/Contents/Info.plist`.
3. **Info.plist** (обязательные ключи):
   - `CFBundleExecutable = Acta`
   - `CFBundleIdentifier = dev.personal.acta`  ← ФИКСИРОВАННЫЙ (иначе слетает TCC)
   - `LSUIElement = true`  ← без иконки в доке (menu-bar)
   - `NSMicrophoneUsageDescription = <человекочитаемый текст>`
   - `LSMinimumSystemVersion = 14.0`
4. **Ad-hoc подпись со стабильной идентичностью:**
   ```
   codesign --force --sign - --identifier dev.personal.acta \
     --entitlements Resources/Acta.entitlements Acta.app
   ```
5. Запуск: `open Acta.app`.

## Гатчи (частые ошибки)
- **TCC слетает после пересборки:** если меняется идентичность бандла, macOS считает это «другим»
  приложением и Screen Recording приходится выдавать заново. Держать `CFBundleIdentifier` и
  `--identifier` постоянными; при проблемах — снять и заново выдать доступ в System Settings →
  Privacy & Security → Screen Recording.
- **Не сэндбоксить** (личное приложение): ScreenCaptureKit + произвольные пути архива проще без
  App Sandbox. Entitlements минимальные.
- **Ресурсы:** файлы из `Resources/` (Info.plist, summary-prompt.md, entitlements) класть в бандл;
  в рантайме читать из `Bundle.main`.
- **Проверка сборки:** `bash Scripts/bundle.sh` должен собрать `Acta.app` без ошибок — это одна из
  Validation Commands.

## Ссылки
- MenuBarExtra: https://developer.apple.com/documentation/swiftui/menubarextra
- LSUIElement: https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement
- codesign / ad-hoc: `man codesign`
