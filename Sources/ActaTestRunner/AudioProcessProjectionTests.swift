import ActaKit
import ActaRuntime
import Foundation
import Testing

/// `AudioProcessProjection` — turning raw HAL readings into a snapshot.
///
/// ⚠️ **This suite exists because a live machine cannot be asked to fail a property read**, and every
/// interesting defect in this layer lives on a failure path. Tests that inject an already-polished
/// `AudioProcessSnapshot` cannot reach any of it: they start after the mistake would have been made.
@Suite("Audio process projection")
struct AudioProcessProjectionTests {
    // MARK: - Fake

    /// Scripted property reads, one entry per object id.
    final class FakeProperties: AudioProcessPropertyReading, @unchecked Sendable {
        struct Process {
            var pid: AudioPropertyReading<Int32>
            var bundleID: AudioPropertyReading<String>
            var isRunningInput: AudioPropertyReading<Bool>
            var hasInputDevices: AudioPropertyReading<Bool> = .value(true)
        }

        var list: AudioProcessListReading = .list([])
        var processes: [UInt32: Process] = [:]

        func processObjectIDs() -> AudioProcessListReading { list }
        func processID(of object: UInt32) -> AudioPropertyReading<Int32> {
            processes[object]?.pid ?? .unreadable
        }
        func bundleID(of object: UInt32) -> AudioPropertyReading<String> {
            processes[object]?.bundleID ?? .unreadable
        }
        func isRunningInput(of object: UInt32) -> AudioPropertyReading<Bool> {
            processes[object]?.isRunningInput ?? .unreadable
        }
        func hasInputDevices(of object: UInt32) -> AudioPropertyReading<Bool> {
            processes[object]?.hasInputDevices ?? .unreadable
        }
    }

    private static let slack = "com.tinyspeck.slackmacgap"

    private static func projection(_ fake: FakeProperties) -> AudioProcessProjection {
        AudioProcessProjection(reader: fake)
    }

    // MARK: - The enumeration

    @Test("a failed enumeration is an unreadable snapshot, never an empty one")
    func aFailedListIsNotAnEmptyMachine() {
        let fake = FakeProperties()
        fake.list = .unreadable
        let snapshot = Self.projection(fake).readSnapshot()
        #expect(snapshot.isComplete == false)
        #expect(snapshot.processes.isEmpty)
        // ⚠️ The distinction the rule depends on: an empty *complete* snapshot means the machine is
        // idle, and an unreadable one means nothing was observed. Conflating them ends live episodes.
        #expect(snapshot == .unreadable)
    }

    @Test("an empty list really does mean an idle machine")
    func anEmptyListIsComplete() {
        let fake = FakeProperties()
        fake.list = .list([])
        let snapshot = Self.projection(fake).readSnapshot()
        #expect(snapshot.isComplete)
        #expect(snapshot.processes.isEmpty)
    }

    // MARK: - Identity

    @Test("a process whose pid cannot be read is dropped and costs the snapshot its completeness")
    func anUnidentifiableProcessDegradesTheSnapshot() {
        // ⚠️ Never keyed under a fabricated pid: every unidentifiable process would coalesce under one
        // false identity, while the real key vanishes from the list and re-arms later.
        let fake = FakeProperties()
        fake.list = .list([1, 2])
        fake.processes[1] = .init(pid: .value(501), bundleID: .value(Self.slack),
                                  isRunningInput: .value(true))
        fake.processes[2] = .init(pid: .unreadable, bundleID: .value("com.other"),
                                  isRunningInput: .value(true))
        let snapshot = Self.projection(fake).readSnapshot()
        #expect(snapshot.processes.count == 1)
        #expect(snapshot.processes.first?.pid == 501)
        #expect(snapshot.isComplete == false)
    }

    @Test("a bundle identifier that could not be read keeps the identity it had")
    func identitySurvivesATransientMetadataFailure() {
        // ⚠️ Codex's trace: the same pid, offered once as `com.tinyspeck.slackmacgap`, then read back
        // with a failing bundle query. Keying it under its pid mints a second episode for one call —
        // and, while the read keeps failing, walks straight past the user's exclusion list.
        let fake = FakeProperties()
        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(123), bundleID: .value(Self.slack),
                                  isRunningInput: .value(true))
        let projection = Self.projection(fake)
        #expect(projection.readSnapshot().processes.first?.bundleID == Self.slack)

        fake.processes[1]?.bundleID = .unreadable
        let second = projection.readSnapshot()
        #expect(second.processes.first?.bundleID == Self.slack)
        // The identity is remembered, so the snapshot is still a complete picture.
        #expect(second.isComplete)
    }

    @Test("an unreadable identifier we never knew degrades the snapshot instead of inventing a key")
    func anUnknownUnreadableIdentityDegradesInstead() {
        let fake = FakeProperties()
        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(123), bundleID: .unreadable,
                                  isRunningInput: .value(true))
        let snapshot = Self.projection(fake).readSnapshot()
        #expect(snapshot.processes.first?.bundleID == nil)
        #expect(snapshot.isComplete == false)
    }

    @Test("a process that really has no bundle identifier is an ordinary complete reading")
    func anAbsentIdentifierIsNotAFailure() {
        let fake = FakeProperties()
        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(123), bundleID: .absent, isRunningInput: .value(true))
        let snapshot = Self.projection(fake).readSnapshot()
        #expect(snapshot.processes.first?.bundleID == nil)
        #expect(snapshot.isComplete)
    }

    @Test("a recycled pid does not inherit the identity of the process that used to own it")
    func aRecycledPIDStartsClean() {
        let fake = FakeProperties()
        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(123), bundleID: .value(Self.slack),
                                  isRunningInput: .value(true))
        let projection = Self.projection(fake)
        #expect(projection.readSnapshot().processes.first?.bundleID == Self.slack)

        // The process exits: a complete enumeration no longer mentions it, which is what clears the
        // remembered identity.
        fake.list = .list([])
        _ = projection.readSnapshot()

        // Another process is handed the same pid and genuinely has no bundle identifier.
        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(123), bundleID: .unreadable,
                                  isRunningInput: .value(true))
        let third = projection.readSnapshot()
        #expect(third.processes.first?.bundleID == nil)
        #expect(third.isComplete == false)
    }

    @Test("a real absent identifier clears a remembered one rather than keeping it alive")
    func anAbsentReadingForgetsTheRememberedIdentity() {
        let fake = FakeProperties()
        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(123), bundleID: .value(Self.slack),
                                  isRunningInput: .value(true))
        let projection = Self.projection(fake)
        _ = projection.readSnapshot()
        fake.processes[1]?.bundleID = .absent
        #expect(projection.readSnapshot().processes.first?.bundleID == nil)
        // And it stays forgotten: a later failure has nothing stale to resurrect.
        fake.processes[1]?.bundleID = .unreadable
        #expect(projection.readSnapshot().processes.first?.bundleID == nil)
    }

    // MARK: - Input state

    @Test("an unreadable input property is unknown, never idle")
    func anUnreadableInputPropertyIsUnknown() {
        let fake = FakeProperties()
        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(123), bundleID: .value(Self.slack),
                                  isRunningInput: .unreadable)
        #expect(Self.projection(fake).readSnapshot().processes.first?.isRunningInput == nil)
    }

    @Test("running IO without an input-scoped device does not count as microphone activity")
    func inputScopeNarrowsTheClaim() {
        // ⚠️ `IsRunningInput` says the process runs IO with an active input stream; the input-scope
        // device list is what keeps that from meaning "any audio at all".
        let fake = FakeProperties()
        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(123), bundleID: .value(Self.slack),
                                  isRunningInput: .value(true), hasInputDevices: .value(false))
        #expect(Self.projection(fake).readSnapshot().processes.first?.isRunningInput == false)
    }

    @Test("an unreadable device scope leaves the answer unknown rather than assuming either way")
    func anUnreadableDeviceScopeIsUnknown() {
        let fake = FakeProperties()
        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(123), bundleID: .value(Self.slack),
                                  isRunningInput: .value(true), hasInputDevices: .unreadable)
        #expect(Self.projection(fake).readSnapshot().processes.first?.isRunningInput == nil)
    }

    @Test("a process positively not running input is positively idle")
    func idleIsIdle() {
        let fake = FakeProperties()
        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(123), bundleID: .value(Self.slack),
                                  isRunningInput: .value(false))
        let snapshot = Self.projection(fake).readSnapshot()
        #expect(snapshot.processes.first?.isRunningInput == false)
        #expect(snapshot.isComplete)
    }
}

/// The one piece of the HAL adapter that can be decided rather than raced.
@Suite("Audio process list trimming")
struct AudioProcessListTrimmingTests {
    private let stride = MemoryLayout<UInt32>.size

    @Test("a list that shrank between the two reads is trimmed to what came back")
    func aShrunkListDropsItsTrailingZeroes() {
        // Allocated for four, the HAL returned two: the last two slots are untouched zeroes, and
        // object id 0 fails every property read.
        let ids: [UInt32] = [11, 12, 0, 0]
        let trimmed = CoreAudioProcessProperties.trimmed(ids, returnedBytes: UInt32(2 * stride),
                                                         stride: stride)
        #expect(trimmed == [11, 12])
    }

    @Test("a list that did not shrink is returned whole")
    func afullListSurvives() {
        let ids: [UInt32] = [11, 12, 13]
        #expect(CoreAudioProcessProperties.trimmed(ids, returnedBytes: UInt32(3 * stride),
                                                   stride: stride) == ids)
    }

    @Test("a read that returned nothing is an empty list, not the allocation")
    func nothingReturnedIsEmpty() {
        #expect(CoreAudioProcessProperties.trimmed([11, 12], returnedBytes: 0, stride: stride) == [])
    }

    @Test("a count larger than the allocation cannot read past it")
    func anOverlongCountIsClamped() {
        #expect(CoreAudioProcessProperties.trimmed([11], returnedBytes: UInt32(9 * stride),
                                                   stride: stride) == [11])
    }
}

/// The projection driving the **real** rule.
///
/// ⚠️ **Two correct-looking halves do not establish their composition**, and this is the seam where that
/// has already bitten: a snapshot that is individually reasonable — an unknown identity, marked
/// incomplete — still produced an anonymous offer downstream, past an exclusion list keyed by bundle id,
/// and a second offer for the same process once the identifier resolved.
@Suite("Audio process projection into the rule")
struct AudioProcessProjectionIntegrationTests {
    private typealias Fake = AudioProcessProjectionTests.FakeProperties
    private static let start = Date(timeIntervalSince1970: 3_000_000)
    private static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
    private static let slack = "com.tinyspeck.slackmacgap"

    /// A rule that has taken its baseline on an idle machine.
    private static func armed(_ projection: AudioProcessProjection, _ fake: Fake)
        -> MicrophoneActivityRule {
        var rule = MicrophoneActivityRule()
        fake.list = .list([])
        _ = rule.observe(projection.readSnapshot(), at: start,
                         context: MicrophoneActivityRule.Context())
        return rule
    }

    @Test("an unreadable identity never produces an anonymous offer")
    func anUnresolvedIdentityCannotQualify() {
        let fake = Fake()
        let projection = AudioProcessProjection(reader: fake)
        var rule = Self.armed(projection, fake)
        let context = MicrophoneActivityRule.Context(excludedBundleIDs: [Self.slack])

        // The process appears holding the input, but its identifier cannot be read and we have never
        // seen it before.
        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(777), bundleID: .unreadable,
                                  isRunningInput: .value(true))
        #expect(rule.observe(projection.readSnapshot(), at: Self.at(1), context: context) == .none)
        #expect(rule.observe(projection.readSnapshot(), at: Self.at(4.1), context: context) == .none)
        #expect(rule.observe(projection.readSnapshot(), at: Self.at(30), context: context) == .none)
    }

    @Test("once the identity resolves, the exclusion list is honoured")
    func aResolvedIdentityIsMatchedAgainstTheExclusions() {
        let fake = Fake()
        let projection = AudioProcessProjection(reader: fake)
        var rule = Self.armed(projection, fake)
        let context = MicrophoneActivityRule.Context(excludedBundleIDs: [Self.slack])

        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(777), bundleID: .unreadable,
                                  isRunningInput: .value(true))
        _ = rule.observe(projection.readSnapshot(), at: Self.at(1), context: context)
        _ = rule.observe(projection.readSnapshot(), at: Self.at(4.1), context: context)

        // The identifier becomes readable, and it is the excluded application. No prompt, ever — and in
        // particular not a second one under a different key.
        fake.processes[1]?.bundleID = .value(Self.slack)
        #expect(rule.observe(projection.readSnapshot(), at: Self.at(5), context: context) == .none)
        #expect(rule.observe(projection.readSnapshot(), at: Self.at(9), context: context) == .none)
        #expect(rule.observe(projection.readSnapshot(), at: Self.at(60), context: context) == .none)
    }

    @Test("an allowed application still gets exactly one offer once it resolves")
    func aResolvedAllowedApplicationIsOfferedOnce() {
        // ⚠️ The other half: withholding on unknown identity must not turn into withholding for ever.
        let fake = Fake()
        let projection = AudioProcessProjection(reader: fake)
        var rule = Self.armed(projection, fake)
        let context = MicrophoneActivityRule.Context()

        fake.list = .list([1])
        fake.processes[1] = .init(pid: .value(777), bundleID: .unreadable,
                                  isRunningInput: .value(true))
        _ = rule.observe(projection.readSnapshot(), at: Self.at(1), context: context)
        fake.processes[1]?.bundleID = .value(Self.slack)
        #expect(rule.observe(projection.readSnapshot(), at: Self.at(2), context: context) == .none)
        var offers = 0
        for second in stride(from: 3.0, through: 40.0, by: 1.0) {
            if case .offer = rule.observe(projection.readSnapshot(), at: Self.at(second),
                                          context: context) {
                offers += 1
            }
        }
        #expect(offers == 1)
    }
}
