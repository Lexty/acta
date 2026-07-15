// swift-tools-version:6.0
import PackageDescription
import Foundation

// Acta — menu-bar приложение только для записи онлайн-встреч.
// Без внешних зависимостей (транскрипции нет → WhisperKit не нужен).
//
// Раскладка таргетов (важно для тестируемости в окружении ТОЛЬКО с Command Line Tools):
//   • ActaKit        — библиотека с чистой логикой (её тестируем; растёт в Task 2–7).
//   • Acta           — executable, @main + SwiftUI menu-bar; тонкий, зависит от ActaKit.
//   • ActaTestRunner — executable со swift-testing @Test-функциями + точкой входа
//                      (`Testing.__swiftPMEntryPoint`). Это НАСТОЯЩИЙ прогон тестов
//                      (`swift run ActaTestRunner` / `bash Scripts/test.sh`).
//   • ActaTests      — testTarget-заготовка, чтобы `swift test` проходил (см. ниже).
//
// Почему так: при CLT-only (полного Xcode нет) `swift test` СОБИРАЕТ тестовый бандл, но НЕ
// исполняет его — в системе нет хост-утилиты `xctest`, поэтому падающий тест всё равно даёт
// exit 0. Чтобы тесты реально выполнялись (и падали при ошибке), их запускает executable-раннер
// через публичную точку входа swift-testing. testTarget оставлен как «заготовка» ради команды
// `swift test` из плана; реальный прогон — `bash Scripts/test.sh`.

func developerDir() -> String {
    if let dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !dir.isEmpty {
        return dir
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    proc.arguments = ["-p"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty {
            return str
        }
    } catch {
        // ignore — вернём дефолт ниже
    }
    return "/Library/Developer/CommandLineTools"
}

// Флаги, дающие swift-testing (Testing.framework, lib_TestingInterop.dylib, макро-плагин
// TestingMacros) в CLT-раскладке. При полном Xcode пути другие и SwiftPM находит всё сам —
// тогда флаги не добавляем.
func swiftTestingSettings() -> (swift: [SwiftSetting], linker: [LinkerSetting]) {
    let dev = developerDir()
    let frameworks = "\(dev)/Library/Developer/Frameworks"
    let libDir = "\(dev)/Library/Developer/usr/lib"
    let pluginDir = "\(dev)/usr/lib/swift/host/plugins/testing"

    guard FileManager.default.fileExists(atPath: "\(frameworks)/Testing.framework") else {
        return ([], [])
    }

    let swift: [SwiftSetting] = [
        .unsafeFlags(["-F", frameworks, "-plugin-path", pluginDir])
    ]
    let linker: [LinkerSetting] = [
        .unsafeFlags([
            "-F", frameworks,
            "-L", libDir,
            "-Xlinker", "-rpath", "-Xlinker", frameworks,
            "-Xlinker", "-rpath", "-Xlinker", libDir
        ])
    ]
    return (swift, linker)
}

let testing = swiftTestingSettings()

let package = Package(
    name: "Acta",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "ActaKit",
            path: "Sources/ActaKit"
        ),
        .executableTarget(
            name: "Acta",
            dependencies: ["ActaKit"],
            path: "Sources/Acta"
        ),
        .executableTarget(
            name: "ActaTestRunner",
            dependencies: ["ActaKit"],
            path: "Sources/ActaTestRunner",
            swiftSettings: testing.swift,
            linkerSettings: testing.linker
        ),
        .testTarget(
            name: "ActaTests",
            dependencies: ["ActaKit"],
            path: "Tests/ActaTests"
        )
    ]
)
