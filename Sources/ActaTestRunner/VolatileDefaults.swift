import Foundation

/// A `UserDefaults` that never reaches the disk — what a test hands `SettingsStore` when it needs
/// real settings state and nothing that outlives the process.
///
/// **`UserDefaults(suiteName:)` cannot be cleaned up reliably, which is why this exists.** A suite is
/// always a *persistent* domain: naming one mints `~/Library/Preferences/<name>.plist`, and
/// `cfprefsd` — not this process — decides when that file is written. So a `removePersistentDomain`
/// plus a `removeItem` at teardown is not a cleanup, it is a race against a daemon that has not
/// flushed yet, and it loses often. A unique suite per run then means a file per run in the
/// developer's home, forever: that is not a hypothetical — this branch's harness left 90 of them
/// behind, and the in-process controller suites some 2600, each one a teardown that believed it had
/// tidied up.
///
/// A process that never names a persistent domain cannot leak one, and none of these tests need one:
/// settings written by a test are read back by the same process, and the harness's two processes
/// agree on the archive through `--root`, not through defaults.
///
/// `super.init(suiteName: nil)` is the standard domain, and the overrides below are what stop this
/// from ever touching it: `SettingsStore` reads and writes a single key through `data(forKey:)` and
/// `set(_:forKey:)`, so intercepting the accessors covers its whole surface — no write is forwarded,
/// and nothing lands in the developer's real settings.
final class VolatileDefaults: UserDefaults, @unchecked Sendable {
    /// Locked because `SettingsStore` is a value type a test may share across the queues a recording
    /// runs on, and `UserDefaults` itself is thread-safe — a fake that is not would be a fake that
    /// crashes where the real thing works.
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    /// `nil` rather than a name: a *named* suite is the persistent domain this type exists to avoid.
    static func make() -> VolatileDefaults { VolatileDefaults(suiteName: nil)! }

    override func data(forKey defaultName: String) -> Data? {
        lock.withLock { storage[defaultName] as? Data }
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { storage[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { storage[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        lock.withLock { storage[defaultName] = nil }
    }
}
