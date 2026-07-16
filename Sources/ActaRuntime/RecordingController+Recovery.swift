import ActaKit
import Foundation

/// The recovery seam: what a recovery pass decided, and how to wait for it.
///
/// In its own file for the reason `RecordingController+Types.swift` gives — the controller is at the
/// file-length limit — but it moves for a second reason too. Unlike that file, this one *does* touch
/// the controller's state: it reads `recoveryTask`, which is what made that property `internal`
/// rather than `private`. That is the whole cost of the seam, and it is confined to here.
@available(macOS 15.0, *)
extension RecordingController {
    /// What the recovery pass `onLaunch()` starts did — the answer `awaitRecovery()` returns.
    ///
    /// It exists because the marker on disk cannot answer this. A pass that is still running and one
    /// that finished but could not assemble both leave `session.json` at `recording`, so anything
    /// polling the file can only bound the ambiguity with a timeout, never resolve it — and a
    /// process-level harness has to tell "recovery worked" from "recovery gave up" to have proved
    /// anything at all.
    public enum RecoveryOutcome: Equatable, Sendable {
        /// The pass found no interrupted recording to act on.
        case nothingToRecover
        /// Every interrupted recording it found assembled whole.
        case recovered(count: Int)
        /// It found interrupted recordings whose audio did not all reach a track — closed short
        /// (`partial`), closed with nothing (`unassembled`), or left for a later launch
        /// (`retrying`). One outcome for the three because they are one answer: the pass ran and the
        /// audio is still in the segments.
        case incomplete(partial: Int, unassembled: Int, retrying: Int)

        /// A pass's three lists read as one verdict. Any folder still holding audio outside a track
        /// — terminal or not — makes the pass incomplete: `recovered` may only be claimed when
        /// nothing was left behind.
        public init(_ outcome: RecoveryManager.Outcome) {
            guard outcome.partial.isEmpty, outcome.unassembled.isEmpty, outcome.retrying.isEmpty else {
                self = .incomplete(partial: outcome.partial.count,
                                   unassembled: outcome.unassembled.count,
                                   retrying: outcome.retrying.count)
                return
            }
            self = outcome.recovered.isEmpty ? .nothingToRecover
                                             : .recovered(count: outcome.recovered.count)
        }
    }

    /// Wait for the pass `onLaunch()` started and report what it did; `nil` when no pass ran, because
    /// `onLaunch()` was never called — which is not "the pass found nothing", hence the optional.
    ///
    /// `onLaunch()` starts recovery in a task and returns at once, which is right for a menu bar —
    /// nothing there waits — but it leaves no way to ask how the pass went. A separate process
    /// recovering a crashed archive needs exactly that, and cannot read it off the disk.
    public func awaitRecovery() async -> RecoveryOutcome? { await recoveryTask?.value }
}
