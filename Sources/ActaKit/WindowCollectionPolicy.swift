import Foundation

/// How the Settings window's `NSWindow.collectionBehavior` must be rewritten, as arithmetic.
///
/// ⚠️ **This exists because `formUnion` is the wrong operation on that mask.** `NSWindow.h` divides
/// collection behaviour into groups and says of several of them "you may specify **at most one**" — and
/// the SwiftUI Settings window already arrives carrying one member of the full-screen group. Adding a
/// second by union leaves two set at once, which the header forbids and for which nothing defines a
/// winner. Measured on macOS 26.6.2: the window is handed over as
/// `auxiliary + fullScreenNone` (`131584`), and a union with `[.moveToActiveSpace, .fullScreenAuxiliary]`
/// produces `131842` — `fullScreenNone` *and* `fullScreenAuxiliary` together.
///
/// ⚠️ **Raw bits, and no `import AppKit`.** `ActaKit` is pure logic, and the policy is pure: it is a
/// function from one mask to another. The cost is that these constants are a *copy* of AppKit's, which
/// could drift from the SDK — so `WindowCollectionPolicyTests` pins every one of them against
/// `NSWindow.CollectionBehavior`'s own value. Do not add a constant here without adding it there.
///
/// ⚠️ **What this does not decide.** Whether the window is *drawn* over another application's
/// full-screen Space is the window server's business and no mask asserts it. Two behaviours were
/// measured to raise it — with `fullScreenAuxiliary` present and, after macOS dropped that bit, without
/// it — so this policy says which mask is *valid*, not which bit is the one that works. Attributing the
/// behaviour to a single flag needs a controlled comparison nobody has run.
public enum WindowCollectionPolicy {
    // MARK: - AppKit's bits, copied and pinned by test

    /// `NSWindowCollectionBehaviorCanJoinAllSpaces` — follows the user onto every Space.
    public static let canJoinAllSpaces: UInt = 1 << 0
    /// `NSWindowCollectionBehaviorMoveToActiveSpace` — comes to the Space the user is on, when the
    /// application is activated, instead of switching the user to the window.
    public static let moveToActiveSpace: UInt = 1 << 1
    /// `NSWindowCollectionBehaviorFullScreenPrimary` — this window *becomes* the full-screen window.
    public static let fullScreenPrimary: UInt = 1 << 7
    /// `NSWindowCollectionBehaviorFullScreenAuxiliary` — may be shown alongside a full-screen window.
    public static let fullScreenAuxiliary: UInt = 1 << 8
    /// `NSWindowCollectionBehaviorFullScreenNone` — may not be full-screen, and is not shown alongside
    /// one. This is the bit SwiftUI's Settings window carries, and the one the union collided with.
    public static let fullScreenNone: UInt = 1 << 9

    /// The full-screen group: at most one of these may be set.
    public static let fullScreenGroup: UInt = fullScreenPrimary | fullScreenAuxiliary | fullScreenNone
    /// The Space-membership group this policy decides between.
    public static let spacesGroup: UInt = canJoinAllSpaces | moveToActiveSpace

    // MARK: - The policy

    /// Rewrite one mask so the Settings window can be raised where the user is.
    ///
    /// Both groups are **replaced, never joined**: every member is cleared before the chosen one is set,
    /// so the result is valid whatever the window arrived with. Bits outside these two groups — the
    /// `auxiliary` marking SwiftUI applies to a Settings window, exposé and cycling behaviour, tiling —
    /// are left exactly as they were, because this policy has no opinion about them and a mask is not a
    /// place to express one by accident.
    ///
    /// ⚠️ **`canJoinAllSpaces` is cleared, deliberately.** A Settings window that followed the user onto
    /// every Space is a window they cannot get rid of; the reminder panel wants that and this does not.
    public static func settingsWindow(from current: UInt) -> UInt {
        (current & ~(fullScreenGroup | spacesGroup)) | fullScreenAuxiliary | moveToActiveSpace
    }

    /// Whether a mask sets more than one member of a group that permits at most one.
    ///
    /// ⚠️ **For tests and diagnostics, not for a branch in production code.** Production always writes
    /// `settingsWindow(from:)`, whose result cannot be conflicted; this is how a test says so.
    public static func hasConflictingFullScreenBits(_ mask: UInt) -> Bool {
        (mask & fullScreenGroup).nonzeroBitCount > 1
    }
}
