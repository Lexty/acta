import Foundation

/// The opaque, stable encoding of a recording's identity on the wire.
///
/// The frozen encoding is **`"v1:" + base64url(UTF8(directory.lastPathComponent))`** — the URL-safe
/// base64 alphabet (`-`/`_`, no `=` padding), which is reversible and collision-free (a bijection over
/// the directory name). It is opaque to the CLI: a client never constructs one, it echoes what a
/// `RecordingSummary` gave it.
///
/// ⚠️ **One home, used by both directions.** The projection (`RecordingSummary(_:)`) mints the `id`
/// here, and the `openInFinder(id:)` lookup resolves it here — decoding the `id` back to the directory
/// name, then matching that name against the current recordings. Two copies of this arithmetic would be
/// free to drift; there is exactly one, so a minted `id` and a resolved `id` cannot disagree.
public enum RecordingID {
    /// The version tag every id carries. Bumping the encoding bumps this, so an old `id` is rejected by
    /// `directoryName(fromID:)` (unknown prefix) rather than silently mis-decoded.
    public static let prefix = "v1:"

    /// Encode a directory's `lastPathComponent` into the opaque wire id.
    public static func make(directoryName: String) -> String {
        prefix + base64URLEncode(Data(directoryName.utf8))
    }

    /// The inverse of `make(directoryName:)`: recover the directory name from a wire id, or `nil` if the
    /// id does not carry the current prefix, does not base64url-decode to valid UTF-8, or is not the
    /// **canonical** encoding of the name it decodes to. A `nil` here is the caller's cue to answer
    /// `unknown_recording` — never to trap.
    ///
    /// ⚠️ **The canonicality re-check is what makes the bijection true rather than merely claimed.**
    /// `Data(base64Encoded:)` accepts encodings whose unused trailing bits are non-zero, so `v1:QQ`,
    /// `v1:QR`, `v1:QV` and `v1:Qf` all decode to `"A"` — four ids for one directory. Re-encoding through
    /// the one encoder and demanding the id back collapses those aliases to `nil`, and it does so by
    /// *reusing* `make`, so the two halves still cannot drift.
    public static func directoryName(fromID id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        let body = String(id.dropFirst(prefix.count))
        guard let data = base64URLDecode(body),
              let name = String(data: data, encoding: .utf8),
              make(directoryName: name) == id else { return nil }
        return name
    }

    // MARK: - base64url (RFC 4648 §5), no padding

    private static func base64URLEncode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
        s = s.replacingOccurrences(of: "_", with: "/")
        // Restore the padding standard base64 requires; the encoded form stripped it.
        let remainder = s.count % 4
        if remainder != 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: s)
    }
}
