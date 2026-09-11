import Foundation

/// The **pure** validation rule for a caller-supplied wire string (a meeting title, an id) arriving
/// over the socket — the tighter, semantic bound that the framing's 64 KiB payload limit does not
/// give.
///
/// It lives in `ActaKit` for the reason every threshold a test asserts against does: `maxLength` is a
/// constant a socket client can be rejected by, and a test that hard-codes its own copy of the number
/// asserts only that it agrees with itself. The dispatcher (`ActaRuntime`) applies this rule and maps a
/// `Rejection` onto a `WireError`; the number and the character rule are here, once.
///
/// ⚠️ **Only the socket path validates.** The in-process UI never drives an adversarial 64 KiB title,
/// so the menu's dispatcher is unrestricted (see `ControlDispatcher.Confinement`); this bound exists so
/// a *socket* client cannot drive unbounded memory/disk through the app's state (a title becomes a
/// folder name) or smuggle a control character into a string the UI and the filesystem later render.
public enum ControlStringPolicy {
    /// The maximum length, in Unicode scalars, of a caller-supplied wire string. A meeting title well
    /// within one frame could still be absurdly long; this is the semantic cap.
    public static let maxLength = 256

    /// Why a string was rejected.
    public enum Rejection: Equatable, Sendable {
        /// More than `maxLength` scalars.
        case tooLong(max: Int)
        /// A C0/C1 control, `DEL`, a `NUL`, or a line/paragraph separator — none of which a title has
        /// any business carrying, and a `NUL` would truncate anything that later reaches a C string.
        case controlCharacter
    }

    /// Validate a caller-supplied string; `nil` when it is acceptable. An **empty** string is
    /// acceptable — an empty title is legitimate (the UI falls back to the suggested title).
    public static func validate(_ string: String) -> Rejection? {
        var count = 0
        for scalar in string.unicodeScalars {
            count += 1
            if count > maxLength { return .tooLong(max: maxLength) }
            if isDisallowed(scalar) { return .controlCharacter }
        }
        return nil
    }

    private static func isDisallowed(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // C0 controls (incl. NUL, TAB, LF, CR) and DEL.
        if value < 0x20 || value == 0x7F { return true }
        // C1 controls.
        if value >= 0x80 && value <= 0x9F { return true }
        // Line and paragraph separators.
        if value == 0x2028 || value == 0x2029 { return true }
        return false
    }
}
