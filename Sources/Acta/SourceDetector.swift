import ActaKit
import AppKit

/// A thin wrapper over `NSWorkspace`: collect the names of running applications and hand them to the
/// pure logic in `MeetingSource.detect`. This only accesses the system process list; matching names
/// against known sources lives in `ActaKit` (covered by tests).
enum SourceDetector {
    /// Names of running regular applications (`.regular`) — those visible in the Dock/app switcher.
    static func runningAppNames() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
    }

    /// The recognised meeting source among the running applications, or `nil`.
    static func detectedSource() -> String? {
        MeetingSource.detect(fromRunningApps: runningAppNames())
    }
}
