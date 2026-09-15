---
name: swiftpm-macos-app-bundle
description: Build a SwiftUI menu-bar app with SwiftPM without Xcode (.app bundle + codesign with a local certificate + TCC). Use for Package.swift, Scripts/bundle.sh, Info.plist, entitlements.
---

# SwiftUI menu-bar app via SwiftPM without Xcode

> This machine has Command Line Tools only (NO full Xcode). The SwiftUI app is built with SwiftPM and
> bundled into an `.app` by hand. Below is the proven recipe and the gotchas.

## Verified environment facts
- Swift 6.3.3, target `arm64-apple-macosx26`. `swift build`, `swift test`, `swiftc` all work.
- `MenuBarExtra` (a SwiftUI scene) is available; `@main`/`App` work from a SwiftPM executable target.
- The `.app` is assembled manually; TCC (Screen Recording, Microphone) requires a **signed bundle with
  a stable identity**.

## Package.swift (sketch)
```swift
// executable target Acta + testTarget ActaTests
// no external dependencies (there is no transcription)
// platforms: [.macOS(.v14)]
```

## `Scripts/bundle.sh` recipe
1. `swift build -c release` → `.build/release/Acta`.
2. Assemble the bundle:
   `Acta.app/Contents/MacOS/Acta`, `Acta.app/Contents/Resources/*`, `Acta.app/Contents/Info.plist`.
3. **Info.plist** (required keys):
   - `CFBundleExecutable = Acta`
   - `CFBundleIdentifier = dev.personal.acta`  ← FIXED (otherwise TCC grants are lost)
   - `LSUIElement = true`  ← no Dock icon (menu-bar app)
   - `NSMicrophoneUsageDescription = <human-readable text>`
   - `LSMinimumSystemVersion = 14.0`
4. **Sign with a local self-signed certificate, not ad-hoc:**
   ```
   codesign --force --sign "Acta Local Signing" --identifier dev.personal.acta \
     --entitlements Resources/Acta.entitlements Acta.app
   ```
   ⚠️ **`--sign -` is the trap this step exists to avoid.** An ad-hoc signature pins the designated
   requirement to the binary's cdhash, which changes on every build, so macOS revokes the TCC grant
   every single time. A certificate makes the requirement `identifier + certificate leaf`, which a
   rebuild does not move. `Scripts/setup-signing.sh` creates that certificate non-interactively in a
   dedicated keychain; `Scripts/bundle.sh` calls it on first use.
5. Run: `open Acta.app`.

## Gotchas (common mistakes)
- **TCC grants are lost after a rebuild:** if the *designated requirement* changes, macOS treats it
  as a different app and Screen Recording must be granted again. Keeping `CFBundleIdentifier` and
  `--identifier` constant is necessary and not sufficient — with an ad-hoc signature the requirement
  also carries the cdhash, so it changes anyway. That is why the certificate exists; if it still misbehaves — revoke and re-grant access in System Settings →
  Privacy & Security → Screen Recording.
- **Do not sandbox** (personal app): ScreenCaptureKit and arbitrary archive paths are simpler without
  App Sandbox. Keep entitlements minimal.
- **Resources:** put `Resources/` files (Info.plist, entitlements) into the bundle; read them at
  runtime from `Bundle.main`.
- **Testing under CLT-only:** there is no `xctest` host utility, so `swift test` only COMPILES the
  bundle — a failing test still exits 0. Real execution goes through an executable runner
  (`ActaTestRunner`, see `Scripts/test.sh`). Never treat `swift test` as a gate here.
- **Build check:** `bash Scripts/bundle.sh` must build `Acta.app` without errors — it is one of the
  Validation Commands.

## References
- MenuBarExtra: https://developer.apple.com/documentation/swiftui/menubarextra
- LSUIElement: https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement
- codesign, and why not ad-hoc: `man codesign`, plus `Scripts/setup-signing.sh`
