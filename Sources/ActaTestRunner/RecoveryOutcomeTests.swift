import ActaRuntime
import Foundation
import Testing

// `RecoveryOutcome(_:)` — the pure mapping from a pass's five lists to the one verdict a harness
// process reports as an exit code.
//
// It is tested here and not through the harness because the harness cannot reach it: a staged crash
// only ever produces `.nothingToRecover` or `.recovered`, so every rule about what makes a pass
// *incomplete* would ride along unasserted. The mapping is a decision, and a decision written once
// in the runtime and never named in a test is a decision nothing is holding in place.

@available(macOS 15.0, *)
private func outcome(recovered: Int = 0, partial: Int = 0, unassembled: Int = 0,
                     retrying: Int = 0, lost: Int = 0) -> RecoveryManager.Outcome {
    func urls(_ count: Int, _ label: String) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/tmp/\(label)-\($0)", isDirectory: true) }
    }
    return RecoveryManager.Outcome(recovered: urls(recovered, "recovered"),
                                   partial: urls(partial, "partial"),
                                   unassembled: urls(unassembled, "unassembled"),
                                   retrying: urls(retrying, "retrying"),
                                   lost: urls(lost, "lost"))
}

/// A pass that did nothing and a pass that could do nothing are opposite answers, and the exit code
/// the recoverer reports is the only place the difference is visible.
@Test("A pass over an archive with nothing to recover reports nothing to recover")
@available(macOS 15.0, *)
func anEmptyPassIsNothingToRecover() {
    #expect(RecordingController.RecoveryOutcome(outcome()) == .nothingToRecover)
}

@Test("A pass that assembled every interrupted folder reports them recovered")
@available(macOS 15.0, *)
func aWhollySuccessfulPassIsRecovered() {
    #expect(RecordingController.RecoveryOutcome(outcome(recovered: 2)) == .recovered(count: 2))
}

/// The rule the verdict exists for: `recovered` may only be claimed when *nothing* was left behind.
/// Each list on its own must be enough to withhold it — a pass that recovered one folder and lost
/// another's audio is not a success with a footnote.
@Test("Any folder still holding audio outside a track makes the pass incomplete")
@available(macOS 15.0, *)
func anyFolderLeftBehindIsIncomplete() {
    #expect(RecordingController.RecoveryOutcome(outcome(partial: 1))
            == .incomplete(partial: 1, unassembled: 0, retrying: 0, lost: 0))
    #expect(RecordingController.RecoveryOutcome(outcome(unassembled: 1))
            == .incomplete(partial: 0, unassembled: 1, retrying: 0, lost: 0))
    #expect(RecordingController.RecoveryOutcome(outcome(recovered: 1, partial: 2, unassembled: 3))
            == .incomplete(partial: 2, unassembled: 3, retrying: 0, lost: 0))
}

/// The list with no audio behind it, and the one whose absence read as success. A folder the crash
/// left with no salvageable segment is closed and gone — nothing to retry, nothing in the segments —
/// so nothing about the *archive* distinguishes it from a folder that never needed recovering. The
/// verdict has to, or a lost meeting exits zero.
@Test("A meeting closed with nothing to salvage is a loss, not nothing to recover")
@available(macOS 15.0, *)
func aLostFolderIsNotAnEmptyPass() {
    #expect(RecordingController.RecoveryOutcome(outcome(lost: 1))
            == .incomplete(partial: 0, unassembled: 0, retrying: 0, lost: 1))
    #expect(RecordingController.RecoveryOutcome(outcome(recovered: 2, lost: 1))
            == .incomplete(partial: 0, unassembled: 0, retrying: 0, lost: 1))
    #expect(!outcome(lost: 1).isEmpty)
}

/// `retrying` counts, and this is the assertion that makes the list worth having. A deferred folder
/// is not terminal — its marker still says `recording` — but its audio is still only in the segments,
/// so a pass that deferred one has not recovered anything, however many others it assembled. Drop
/// `retrying` from the guard and this is what stops being true.
@Test("A deferred folder withholds success even from a pass that recovered others")
@available(macOS 15.0, *)
func aDeferredFolderIsIncompleteNotRecovered() {
    #expect(RecordingController.RecoveryOutcome(outcome(retrying: 1))
            == .incomplete(partial: 0, unassembled: 0, retrying: 1, lost: 0))
    #expect(RecordingController.RecoveryOutcome(outcome(recovered: 3, retrying: 1))
            == .incomplete(partial: 0, unassembled: 0, retrying: 1, lost: 0))
}
