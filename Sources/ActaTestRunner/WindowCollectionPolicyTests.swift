import ActaKit
import AppKit
import Foundation
import Testing

/// `WindowCollectionPolicy` — the Settings window's collection behaviour, as arithmetic.
///
/// ⚠️ **The PR this came from said window placement "cannot be covered by a test".** That is true of the
/// drawing and of Spaces, and not true of the mask: deciding which bits to write is a pure function, and
/// the defect these tests exist for was entirely in that function. What stays human is whether the window
/// then appears where the user is.
///
/// ⚠️ **The masks below are measured, not invented.** `131584` is what macOS 26.6.2 handed the Settings
/// window before anything touched it, and `131842` is what the original `formUnion` produced — the
/// conflict. They are written as literals so a reader can match them against the log that found this.
@Suite("Settings window collection behaviour")
struct WindowCollectionPolicyTests {
    /// What SwiftUI's Settings window arrives with: `auxiliary + fullScreenNone`.
    private static let asHandedOver: UInt = 131_584
    /// What the original union produced: the above, plus `fullScreenAuxiliary + moveToActiveSpace`.
    private static let theUnionsResult: UInt = 131_842

    // MARK: - The copy of AppKit's bits

    /// ⚠️ **The one thing `ActaKit` cannot check for itself.** The policy is pure arithmetic and does not
    /// import AppKit, so its constants are a copy. This is the test that makes the copy safe: if Apple
    /// ever renumbers a bit, or one of these was transcribed wrong in the first place, it fails here
    /// rather than silently writing a mask that means something else.
    @Test("every copied bit equals AppKit's own value")
    func theCopiedBitsMatchAppKit() {
        #expect(WindowCollectionPolicy.canJoinAllSpaces
                == NSWindow.CollectionBehavior.canJoinAllSpaces.rawValue)
        #expect(WindowCollectionPolicy.moveToActiveSpace
                == NSWindow.CollectionBehavior.moveToActiveSpace.rawValue)
        #expect(WindowCollectionPolicy.fullScreenPrimary
                == NSWindow.CollectionBehavior.fullScreenPrimary.rawValue)
        #expect(WindowCollectionPolicy.fullScreenAuxiliary
                == NSWindow.CollectionBehavior.fullScreenAuxiliary.rawValue)
        #expect(WindowCollectionPolicy.fullScreenNone
                == NSWindow.CollectionBehavior.fullScreenNone.rawValue)
    }

    /// The fixtures are only worth anything if they are the masks that were actually observed.
    @Test("the recorded masks decode to what the log said they were")
    func theRecordedMasksAreWhatWasObserved() {
        let handed = NSWindow.CollectionBehavior(rawValue: Self.asHandedOver)
        #expect(handed.contains(.auxiliary))
        #expect(handed.contains(.fullScreenNone))
        #expect(!handed.contains(.fullScreenAuxiliary))
        #expect(!handed.contains(.moveToActiveSpace))

        let union = NSWindow.CollectionBehavior(rawValue: Self.theUnionsResult)
        #expect(union.contains(.fullScreenNone))
        #expect(union.contains(.fullScreenAuxiliary))
        #expect(union.contains(.moveToActiveSpace))
    }

    // MARK: - The defect

    /// ⚠️ **The regression this whole file exists for.** `formUnion` cannot clear a bit, so the mask the
    /// window arrives with decides whether the result is legal — and on this machine it is not.
    @Test("the original union left two members of the full-screen group set")
    func theUnionProducedAConflict() {
        let union = Self.asHandedOver
            | WindowCollectionPolicy.fullScreenAuxiliary
            | WindowCollectionPolicy.moveToActiveSpace
        #expect(union == Self.theUnionsResult, "the arithmetic no longer reproduces the observed mask")
        #expect(WindowCollectionPolicy.hasConflictingFullScreenBits(union),
                "the fixture stopped demonstrating the conflict it was written for")
    }

    @Test("the policy replaces the full-screen group instead of joining it")
    func thePolicyReplacesTheFullScreenGroup() {
        let result = WindowCollectionPolicy.settingsWindow(from: Self.asHandedOver)
        #expect(!WindowCollectionPolicy.hasConflictingFullScreenBits(result))
        let behaviour = NSWindow.CollectionBehavior(rawValue: result)
        #expect(behaviour.contains(.fullScreenAuxiliary))
        #expect(!behaviour.contains(.fullScreenNone))
        #expect(!behaviour.contains(.fullScreenPrimary))
        #expect(behaviour.contains(.moveToActiveSpace))
        #expect(!behaviour.contains(.canJoinAllSpaces))
    }

    /// ⚠️ **Every starting mask, not the one that was observed.** The window is handed over by SwiftUI
    /// and nothing promises the bits it carries will stay the same across a macOS release; a policy that
    /// only normalises the mask we happened to see is a policy that breaks silently on the next one.
    @Test("no mask at all can survive the policy still conflicted")
    func noStartingMaskSurvivesConflicted() {
        let group = [0 as UInt,
                     WindowCollectionPolicy.fullScreenPrimary,
                     WindowCollectionPolicy.fullScreenAuxiliary,
                     WindowCollectionPolicy.fullScreenNone]
        let spaces = [0 as UInt,
                      WindowCollectionPolicy.canJoinAllSpaces,
                      WindowCollectionPolicy.moveToActiveSpace]
        // Every combination of the two groups this policy decides, including the illegal ones a window
        // should never arrive with — the policy must not depend on having been handed a legal mask.
        for full in group {
            for otherFull in group {
                for space in spaces {
                    let start = full | otherFull | space
                    let result = WindowCollectionPolicy.settingsWindow(from: start)
                    #expect(!WindowCollectionPolicy.hasConflictingFullScreenBits(result),
                            Comment(rawValue: "starting from \(start) produced \(result)"))
                    #expect(result & WindowCollectionPolicy.spacesGroup
                            == WindowCollectionPolicy.moveToActiveSpace,
                            Comment(rawValue: "starting from \(start) produced \(result)"))
                }
            }
        }
    }

    /// ⚠️ **The bits this policy has no opinion about must come through untouched.** `auxiliary` is the
    /// marking Apple's own header recommends for a Settings window, and clearing it — which a policy
    /// written as "assign the mask I want" would do — would quietly change how the window is treated.
    @Test("bits outside the two decided groups are preserved exactly")
    func unrelatedBitsArePreserved() {
        let unrelated = NSWindow.CollectionBehavior.auxiliary.rawValue
            | NSWindow.CollectionBehavior.ignoresCycle.rawValue
            | NSWindow.CollectionBehavior.fullScreenDisallowsTiling.rawValue
            | NSWindow.CollectionBehavior.stationary.rawValue
        let result = WindowCollectionPolicy.settingsWindow(from: unrelated | Self.asHandedOver)
        #expect(result & unrelated == unrelated, "a bit the policy does not decide was cleared")
    }

    /// Applying it twice is applying it once: the second raise of the same window must not depend on
    /// what the first one left behind.
    @Test("the policy is idempotent")
    func thePolicyIsIdempotent() {
        let once = WindowCollectionPolicy.settingsWindow(from: Self.asHandedOver)
        #expect(WindowCollectionPolicy.settingsWindow(from: once) == once)
    }
}
