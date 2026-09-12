import Foundation

/// What one tracked thing is, when a snapshot is folded by identity.
///
/// ⚠️ **Coalescing is by bundle identifier**, so the several processes an Electron application or a
/// browser runs are one holder rather than three. A process with no bundle identifier keeps its own
/// pid as its identity, which is weaker: a pid can be reused, and nothing here promises otherwise.
public enum AudioProcessKey: Hashable, Sendable {
    case bundle(String)
    case process(Int32)

    /// The bundle identifier, when this key has one. `nil` for a pid-only holder.
    public var bundleID: String? {
        if case .bundle(let id) = self { return id }
        return nil
    }
}

/// What a snapshot said about one key.
public enum MicrophoneInputReading: Equatable, Sendable {
    /// At least one process of this key was observed holding the input.
    case held
    /// Every process of this key was observed idle, in a snapshot trustworthy enough to say so.
    case released
    /// The snapshot could not answer for this key.
    ///
    /// ⚠️ **Not a synonym for released.** Absence of evidence is the thing the two rules treat most
    /// differently from evidence of absence, and collapsing them is how a prompt gets raised — or a
    /// recording stopped — for a call that never ended.
    case unreadable
}

/// One fold of a process snapshot into one reading per key.
///
/// ⚠️ **Extracted so there is exactly one copy.** Both reviews of the owner-bound stop offer named this
/// as the place drift would actually live: key derivation, dropping Acta's own processes, held-winning
/// over released, and the rule that an incomplete enumeration cannot say anything stopped. Two rules now
/// ask the same question of a snapshot, and a second implementation of any one of those four would
/// diverge silently — the start reminder would keep working while the stop offer answered a subtly
/// different question about the same machine.
public enum AudioProcessReadings {
    /// The processes a reduction must pretend it never saw.
    ///
    /// ⚠️ **Dropped during the fold rather than filtered afterwards**, so Acta's own capture can never
    /// create, extend or re-arm anything. ⚠️ **A set of bundle identifiers, not one**: the dev and
    /// stable builds coexist on this machine by design, and each must ignore the other's capture as
    /// well as its own.
    public struct Own: Equatable, Sendable {
        public var bundleIDs: Set<String>
        public var pids: Set<Int32>

        public init(bundleIDs: Set<String> = [], pids: Set<Int32> = []) {
            self.bundleIDs = bundleIDs
            self.pids = pids
        }
    }

    /// Fold the snapshot into one reading per key.
    public static func reduce(_ snapshot: AudioProcessSnapshot,
                              dropping own: Own) -> [AudioProcessKey: MicrophoneInputReading] {
        var readings: [AudioProcessKey: MicrophoneInputReading] = [:]
        for process in snapshot.processes {
            if own.pids.contains(process.pid) { continue }
            if let bundleID = process.bundleID, own.bundleIDs.contains(bundleID) { continue }
            let key: AudioProcessKey = process.bundleID.map { .bundle($0) } ?? .process(process.pid)
            let reading: MicrophoneInputReading
            switch process.isRunningInput {
            case .some(true): reading = .held
            case .some(false): reading = .released
            case .none: reading = .unreadable
            }
            readings[key] = stronger(readings[key], reading)
        }
        // ⚠️ **A partial list cannot say that anything stopped**, and a visible idle sibling does not
        // make it able to. The process that actually held the input is exactly the one that can be
        // missing, so a key with no positively-held process in an incomplete snapshot is unreadable,
        // never released. Positive evidence still counts: a process seen holding is holding.
        if !snapshot.isComplete {
            for (key, reading) in readings where reading == .released {
                readings[key] = .unreadable
            }
        }
        return readings
    }

    /// `held` beats `unreadable` beats `released`: a key is idle only when every process of it was seen
    /// to be idle.
    public static func stronger(_ lhs: MicrophoneInputReading?,
                                _ rhs: MicrophoneInputReading) -> MicrophoneInputReading {
        guard let lhs else { return rhs }
        if lhs == .held || rhs == .held { return .held }
        if lhs == .unreadable || rhs == .unreadable { return .unreadable }
        return .released
    }
}
