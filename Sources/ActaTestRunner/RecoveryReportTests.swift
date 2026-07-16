import Testing
import ActaKit

// The wording of a recovery pass. One distinction carries the whole file: "recovered" must mean the
// audio is in a track. A folder that gave up is terminal — no launch will retry it — so if the
// notification calls it recovered, the audio left in its segments is never found.

/// Nothing happened → nothing is said. A notification over an untouched archive trains the user to
/// dismiss the one that matters.
@Test
func recoveryReportSaysNothingWhenThePassChangedNothing() {
    #expect(RecoveryReport.message(recovered: 0, partial: 0, unassembled: 0, retrying: 0, lost: 0) == nil)
}

@Test
func recoveryReportAnnouncesRecoveredFolders() throws {
    let one = try #require(RecoveryReport.message(recovered: 1, partial: 0, unassembled: 0, retrying: 0, lost: 0))
    #expect(one.title == "Recordings recovered")
    #expect(one.body == "Recovered 1 interrupted recording.")

    let many = try #require(RecoveryReport.message(recovered: 3, partial: 0, unassembled: 0, retrying: 0, lost: 0))
    #expect(many.body.contains("3"))
}

/// The quiet loss: a folder that closed over one assembled track while the other track's audio stayed
/// in the segments. It plays, so nothing looks wrong — which is exactly why the message must not fold
/// it into the recovered count and let "Recovered 1 interrupted recording" be the last word on it.
@Test
func recoveryReportDoesNotCallAPartiallyRecoveredFolderRecovered() throws {
    let message = try #require(RecoveryReport.message(recovered: 0, partial: 1, unassembled: 0, retrying: 0, lost: 0))

    #expect(message.title == "Recordings partially recovered")
    #expect(message.body.contains("in part"))
    // It has to point at the audio that is missing from the track the user can play.
    #expect(message.body.contains("segments"))
    #expect(message.body.contains("info.md"))
}

/// The case the whole split exists for: audio survives only as segments, and the message must not
/// call that a recovery — nor stay silent, since the marker is terminal and nothing will retry it.
@Test
func recoveryReportDoesNotCallAnUnassembledFolderRecovered() throws {
    let message = try #require(RecoveryReport.message(recovered: 0, partial: 0, unassembled: 1, retrying: 0, lost: 0))

    #expect(message.title == "Recordings could not be assembled")
    #expect(!message.body.contains("Recovered"))
    // It has to point at the audio: the folder holds no track to lead the user there.
    #expect(message.body.contains("segments"))
    #expect(message.body.contains("info.md"))
}

/// A mixed pass must report every part of itself — folding a failure into the recovered count would
/// hide it behind good news.
@Test
func recoveryReportReportsEveryOutcomeOfAMixedPass() throws {
    let message = try #require(RecoveryReport.message(recovered: 2, partial: 1, unassembled: 1, retrying: 0, lost: 0))

    #expect(message.body.contains("2"))
    #expect(message.body.contains("in part"))
    #expect(message.body.contains("could not be assembled"))
    // Something was genuinely recovered, so the title leads with that.
    #expect(message.title == "Recordings recovered")
}

/// The loss that must never be reported by saying nothing. A pass whose only outcome is `lost` used
/// to produce no message at all — identical to a pass over an archive with nothing to recover, which
/// is the opposite answer. The folder is closed and terminal: this is the only time the user is ever
/// told the meeting is gone.
@Test
func recoveryReportAnnouncesALostRecordingRatherThanSayingNothing() throws {
    let message = try #require(RecoveryReport.message(recovered: 0, partial: 0, unassembled: 0,
                                                      retrying: 0, lost: 1))

    #expect(message.title == "Recordings lost")
    #expect(message.body.contains("lost"))
    // Nothing survived, so the message must not send the user looking for audio that is not there.
    #expect(!message.body.contains("segments"))
    #expect(!message.body.contains("Recovered"))
}

/// The actionable one: the audio is intact and a later launch will retry it, and the usual cause is
/// a missing `ffmpeg`. Silence here leaves a recoverable meeting sitting unassembled behind a fix the
/// user could apply in one command.
@Test
func recoveryReportPointsADeferredRecoveryAtFfmpeg() throws {
    let message = try #require(RecoveryReport.message(recovered: 0, partial: 0, unassembled: 0,
                                                      retrying: 1, lost: 0))

    // Not terminal, so it must not be worded as a give-up.
    #expect(message.title == "Recovery will retry")
    #expect(!message.body.contains("could not be assembled"))
    #expect(message.body.contains("brew install ffmpeg"))
    #expect(message.body.contains("next launch"))
}

/// A pass that saved one meeting and lost another leads with the good news — the title is the best
/// outcome reached — but the body carries both. Folding the loss away entirely is the failure mode.
@Test
func recoveryReportCarriesALossThroughAMixedPass() throws {
    let message = try #require(RecoveryReport.message(recovered: 1, partial: 0, unassembled: 0,
                                                      retrying: 1, lost: 1))

    #expect(message.title == "Recordings recovered")
    #expect(message.body.contains("Recovered 1 interrupted recording."))
    #expect(message.body.contains("lost"))
    #expect(message.body.contains("brew install ffmpeg"))
}
