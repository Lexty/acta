import ActaKit
import Foundation
import Testing

/// `AudioProcessReadings` — the one fold of a process snapshot both microphone rules read through.
///
/// ⚠️ **This suite exists because of where drift would live, not because the fold is hard.** Two rules
/// now ask the same question of the same snapshot: the start reminder, which wants to know that an
/// application *began* holding the input, and the ownership rule, which wants to know that one
/// particular application *let it go*. A second copy of any of the four decisions below would let the
/// first keep working while the second answered a subtly different question about the same machine.
@Suite("Audio process readings")
struct AudioProcessReadingsTests {
    private static func process(_ pid: Int32, _ bundleID: String?,
                                _ isRunningInput: Bool?) -> AudioProcessObservation {
        AudioProcessObservation(pid: pid, bundleID: bundleID, displayName: nil,
                                processName: nil, isRunningInput: isRunningInput)
    }

    private static func snapshot(_ processes: [AudioProcessObservation],
                                 complete: Bool = true) -> AudioProcessSnapshot {
        AudioProcessSnapshot(processes: processes, isComplete: complete)
    }

    private static let slack = "com.tinyspeck.slackmacgap.helper"

    // MARK: - Coalescing by identity

    /// ⚠️ **The measured shape, not a hypothetical one.** A Slack huddle is held by one helper while the
    /// application's other processes are not holding anything; an Electron application or a browser runs
    /// several. One holder, one answer.
    @Test("several processes of one bundle are one key")
    func processesOfOneBundleCoalesce() {
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(501, Self.slack, false),
                           Self.process(502, Self.slack, true),
                           Self.process(503, Self.slack, false)]),
            dropping: .init())
        #expect(readings == [.bundle(Self.slack): .held])
    }

    @Test("a process with no bundle identifier keeps its pid as its identity")
    func aProcessWithoutABundleIsKeyedByPid() {
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(777, nil, true)]), dropping: .init())
        #expect(readings == [.process(777): .held])
    }

    // MARK: - Held wins

    /// ⚠️ **Both directions, because `stronger` is order-dependent if it is wrong.** A dictionary gives
    /// no order guarantee, so a fold that only handled "held arrives second" would pass half the time
    /// and be a flake nobody could reproduce.
    @Test("held wins over an unreadable sibling of the same key, in either order")
    func heldWinsOverAnUnreadableSibling() {
        let heldFirst = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(501, Self.slack, true),
                           Self.process(502, Self.slack, nil)]), dropping: .init())
        #expect(heldFirst == [.bundle(Self.slack): .held])

        let unreadableFirst = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(502, Self.slack, nil),
                           Self.process(501, Self.slack, true)]), dropping: .init())
        #expect(unreadableFirst == [.bundle(Self.slack): .held],
                "an unreadable sibling hid a process that was observed holding the input")
    }

    @Test("an unreadable sibling beats an idle one")
    func unreadableWinsOverReleased() {
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(501, Self.slack, false),
                           Self.process(502, Self.slack, nil)]), dropping: .init())
        #expect(readings == [.bundle(Self.slack): .unreadable],
                "a key was called idle while one of its processes could not be read")
    }

    @Test("a key is released only when every process of it was seen idle")
    func releasedNeedsEveryProcess() {
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(501, Self.slack, false),
                           Self.process(502, Self.slack, false)]), dropping: .init())
        #expect(readings == [.bundle(Self.slack): .released])
    }

    // MARK: - What an incomplete enumeration may say

    /// ⚠️ **The rule the negative control names.** The process that actually held the input is exactly
    /// the one that can be missing from a partial list, so a visible idle sibling proves nothing: it is
    /// evidence about the process we *did* see, not about the application. Called released here, this
    /// is what would let the ownership rule run a countdown and stop a recording during a live call.
    @Test("a partial list with a visible idle sibling is unreadable, never released")
    func aPartialListCannotSayAnythingStopped() {
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(501, Self.slack, false)], complete: false),
            dropping: .init())
        #expect(readings == [.bundle(Self.slack): .unreadable],
                "an incomplete enumeration was allowed to say an application had stopped")
    }

    /// Positive evidence survives an incomplete list: a process seen holding is holding, whatever else
    /// the enumeration missed.
    @Test("a partial list may still say that something is holding")
    func aPartialListMayStillSayHeld() {
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(501, Self.slack, true),
                           Self.process(502, "com.apple.Music", false)], complete: false),
            dropping: .init())
        #expect(readings[.bundle(Self.slack)] == .held)
        #expect(readings[.bundle("com.apple.Music")] == .unreadable)
    }

    /// ⚠️ **The other half, and the one that makes the rule above a rule rather than a refusal.** In a
    /// *complete* list, an application observed idle is idle — otherwise nothing could ever be released
    /// and the ownership rule could never fire at all.
    @Test("confirmed absence in a complete list is a release")
    func aCompleteListCanSayAnythingStopped() {
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(501, Self.slack, false)]), dropping: .init())
        #expect(readings == [.bundle(Self.slack): .released])
    }

    /// A key that is not in the snapshot at all has no reading — the absence is the caller's to
    /// interpret, and the two rules interpret it differently.
    @Test("a key absent from the snapshot produces no reading")
    func anAbsentKeyProducesNoReading() {
        let readings = AudioProcessReadings.reduce(Self.snapshot([]), dropping: .init())
        #expect(readings.isEmpty)
    }

    // MARK: - Acta's own capture

    /// ⚠️ **Measured: Acta's own capture is reported as `com.apple.replayd`**, not under Acta's bundle
    /// identifier — so this drop is about the identifiers the caller supplies, whatever they are. The
    /// set is plural because the dev and stable builds coexist on this machine by design.
    @Test("own processes are dropped during the fold, by bundle and by pid alike")
    func ownProcessesAreDropped() {
        let own = AudioProcessReadings.Own(bundleIDs: ["com.acta.dev", "com.acta"], pids: [99])
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(10, "com.acta.dev", true),
                           Self.process(11, "com.acta", true),
                           Self.process(99, nil, true),
                           Self.process(12, Self.slack, true)]),
            dropping: own)
        #expect(readings == [.bundle(Self.slack): .held],
                "Acta's own capture reached the fold")
    }

    /// ⚠️ **Dropped, not read as idle.** Filtering afterwards would be the same thing for `held`, and the
    /// opposite for this case: an own process seen idle would otherwise coalesce into its key and be
    /// able to *contradict* a foreign process of the same key.
    @Test("an own process cannot make its key look idle")
    func anOwnProcessCannotContributeIdleness() {
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(10, "com.acta.dev", false),
                           Self.process(11, "com.acta.dev", nil)]),
            dropping: .init(bundleIDs: ["com.acta.dev"]))
        #expect(readings.isEmpty)
    }
}
