import Testing
import ActaKit

// The wording of a recovery pass. One distinction carries the whole file: "recovered" must mean a
// track exists. A folder that gave up with nothing assembled is terminal — no launch will retry it —
// so if the notification calls it recovered, the audio in its segments is never found.

/// Nothing happened → nothing is said. A notification over an untouched archive trains the user to
/// dismiss the one that matters.
@Test
func recoveryReportSaysNothingWhenThePassChangedNothing() {
    #expect(RecoveryReport.message(recovered: 0, unassembled: 0) == nil)
}

@Test
func recoveryReportAnnouncesRecoveredFolders() throws {
    let one = try #require(RecoveryReport.message(recovered: 1, unassembled: 0))
    #expect(one.title == "Recordings recovered")
    #expect(one.body == "Recovered 1 interrupted recording.")

    let many = try #require(RecoveryReport.message(recovered: 3, unassembled: 0))
    #expect(many.body.contains("3"))
}

/// The case the whole split exists for: audio survives only as segments, and the message must not
/// call that a recovery — nor stay silent, since the marker is terminal and nothing will retry it.
@Test
func recoveryReportDoesNotCallAnUnassembledFolderRecovered() throws {
    let message = try #require(RecoveryReport.message(recovered: 0, unassembled: 1))

    #expect(message.title == "Recordings could not be assembled")
    #expect(!message.body.contains("Recovered"))
    // It has to point at the audio: the folder holds no track to lead the user there.
    #expect(message.body.contains("segments"))
    #expect(message.body.contains("info.md"))
}

/// A mixed pass must report both halves — folding the failure into the recovered count would hide it
/// behind good news.
@Test
func recoveryReportReportsBothHalvesOfAMixedPass() throws {
    let message = try #require(RecoveryReport.message(recovered: 2, unassembled: 1))

    #expect(message.body.contains("2"))
    #expect(message.body.contains("could not be assembled"))
    // Something was genuinely recovered, so the title leads with that.
    #expect(message.title == "Recordings recovered")
}
