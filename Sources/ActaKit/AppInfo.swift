import Foundation

/// Shared app constants. `bundleID` lives in one place: it must match `CFBundleIdentifier` in
/// `Resources/Info.plist` and `--identifier` in `Scripts/bundle.sh`, otherwise macOS treats a
/// rebuilt bundle as a *different* app and resets its TCC permissions (Screen Recording,
/// Microphone).
public enum AppInfo {
    /// Human-readable name.
    public static let name = "Acta"

    /// Fixed bundle identifier (for TCC stability).
    public static let bundleID = "dev.personal.acta"

    /// Short version.
    public static let version = "0.1.0"
}
