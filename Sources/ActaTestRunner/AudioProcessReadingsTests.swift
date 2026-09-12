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

    /// ⚠️ **Both directions, because the precedence is order-dependent if it is wrong.** Codex corrected
    /// an earlier version of this comment that blamed dictionary ordering: the fold iterates
    /// `snapshot.processes`, an array, so for a fixed fixture the order is deterministic. What is not
    /// promised is the order the *HAL* enumerates processes in, and a fold that only handled "held
    /// arrives second" would depend on it.
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
    ///
    /// ⚠️ **This is an observed idle process, not an absent one.** Codex caught the earlier title
    /// claiming "confirmed absence": a key missing from the snapshot gets no reading at all, and the
    /// fold deliberately does not decide what that means. See `anAbsentKeyProducesNoReading`.
    @Test("a process observed idle in a complete list is a release")
    func aCompleteListCanSayAnythingStopped() {
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(501, Self.slack, false)]), dropping: .init())
        #expect(readings == [.bundle(Self.slack): .released])
    }

    /// ⚠️ **A key absent from the snapshot has no reading, and the fold says nothing about why.** An
    /// empty *complete* list and an empty *incomplete* one reduce to the same empty dictionary, so a
    /// consumer that wrote `readings[owner] ?? .released` would treat a failed enumeration as a call
    /// ending. Completeness has to be carried alongside the readings by every consumer — the activity
    /// rule already does, and the ownership rule must. A disappearance trace belongs in those consumer
    /// tests, not here.
    @Test("a key absent from the snapshot produces no reading, complete or not")
    func anAbsentKeyProducesNoReading() {
        #expect(AudioProcessReadings.reduce(Self.snapshot([]), dropping: .init()).isEmpty)
        #expect(AudioProcessReadings.reduce(Self.snapshot([], complete: false),
                                            dropping: .init()).isEmpty)
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

    /// ⚠️ **Dropped before the key is built, and this is the fixture that can tell the difference.**
    /// Codex corrected both the earlier rationale and the earlier fixture: an *idle* own process can
    /// never contradict a foreign sibling, because held beats unreadable beats released — and the old
    /// fixture excluded the whole bundle, so both processes were Acta's and there was no foreign
    /// sibling at all. The case that needs filtering **before** aggregation is the opposite one: Acta's
    /// own process holding, a foreign process of the same bundle idle, and only the pid excluded.
    /// Folding first leaves the key `held`; deleting the key afterwards loses the foreign reading.
    @Test("an own process holding cannot make a foreign sibling of its bundle look held")
    func ownProcessesAreDroppedBeforeTheKeyIsBuilt() {
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(99, "com.example.shared", true),     // Acta's
                           Self.process(100, "com.example.shared", false)]), // not Acta's
            dropping: .init(pids: [99]))
        #expect(readings == [.bundle("com.example.shared"): .released],
                "Acta's own capture was aggregated into a foreign application's key")
    }

    /// The same boundary in the other direction: an own process that could not be read must not make a
    /// foreign sibling unreadable.
    @Test("an own unreadable process cannot make a foreign sibling of its bundle unreadable")
    func anOwnUnreadableProcessCannotSpoilASibling() {
        let readings = AudioProcessReadings.reduce(
            Self.snapshot([Self.process(99, "com.example.shared", nil),
                           Self.process(100, "com.example.shared", false)]),
            dropping: .init(pids: [99]))
        #expect(readings == [.bundle("com.example.shared"): .released])
    }
}
