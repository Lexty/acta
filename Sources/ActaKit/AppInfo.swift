import Foundation

/// Общие константы приложения. Держим `bundleID` в одном месте: он должен совпадать с
/// `CFBundleIdentifier` в `Resources/Info.plist` и `--identifier` в `Scripts/bundle.sh`,
/// иначе macOS считает пересобранный бандл «другим» приложением и сбрасывает TCC-права
/// (Screen Recording, Microphone).
public enum AppInfo {
    /// Человекочитаемое имя.
    public static let name = "Acta"

    /// Фиксированный bundle identifier (ради стабильности TCC).
    public static let bundleID = "dev.personal.acta"

    /// Короткая версия.
    public static let version = "0.1.0"
}
