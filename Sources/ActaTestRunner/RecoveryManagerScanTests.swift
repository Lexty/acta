import Testing
import Foundation
import ActaKit
import ActaRuntime

// The scan itself, as opposed to what it decides about a folder it found (`RecoveryOutcomeTests`)
// or how often it retries one (`RecoveryManagerRetryTests`): the question here is only whether the
// pass could look at the archive at all, and whether it says so.

/// An archive the pass cannot read at all, against the one it merely has nothing to do over. These
/// are opposite answers that used to be the same empty `Outcome`: the pass reported "nothing to
/// recover" — exit `0`, no banner — for a root on an unmounted volume or one the app can no longer
/// open, vouching for interrupted meetings it never saw.
///
/// The distinction is existence, not readability: a root that is simply not there yet is an ordinary
/// first launch, and reporting *that* would put a banner in front of every new user.
///
/// The unreadable root is provoked with a **file** standing where the archive should be, rather than
/// a `chmod 000` directory: `contentsOfDirectory` refuses it and `fileExists` confirms it, which is
/// the shape the code branches on, and it says so on every machine — permission bits do not, since
/// they mean nothing to root (see `anArchiveBehindALostPermissionIsUnscannable`).
@Test
func recoveryDistinguishesAnUnreadableArchiveFromOneWithNothingToDo() throws {
    try withRecordingDirectory { root in
        // Readable and empty: nothing has been recorded, so there is nothing to say.
        #expect(RecoveryManager(archiveRoot: root).recoverInterruptedSessions().isEmpty)

        // Never created: the first launch of a fresh install. Also nothing to say, and in particular
        // not `unscannable` — a banner here would greet every new user.
        let absent = root.appendingPathComponent("no-such-archive", isDirectory: true)
        let overAbsent = RecoveryManager(archiveRoot: absent).recoverInterruptedSessions()
        #expect(overAbsent.isEmpty)
        #expect(!overAbsent.unscannable)

        // There, and unscannable: the pass cannot enumerate it, whatever the reason.
        let notADirectory = root.appendingPathComponent("archive", isDirectory: false)
        try Data("not a directory".utf8).write(to: notADirectory)
        let outcome = RecoveryManager(archiveRoot: notADirectory).recoverInterruptedSessions()
        #expect(outcome.unscannable)
        // Not silent: this is what stops it reading as an archive with nothing to recover.
        #expect(!outcome.isEmpty)
    }
}

/// The field case the branch was actually written for: the archive is there and the app has lost the
/// right to read it — a permission revoked, a volume that came back mounted differently.
///
/// Split out and **skipped visibly** as root rather than folded into the test above, because root
/// ignores permission bits: `contentsOfDirectory` would succeed on a `0o000` directory, the pass
/// would correctly report an empty archive, and the assertion would fail for a reason that is not a
/// defect. A silent `return` would report that as a pass and hide that nothing ran.
@Test(.enabled(if: geteuid() != 0, "root ignores the permission bits this test provokes"))
func anArchiveBehindALostPermissionIsUnscannable() throws {
    try withRecordingDirectory { root in
        let locked = root.appendingPathComponent("locked-archive", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        // Restored before the enclosing temp root is removed — a directory nothing can open is a
        // directory nothing can clean up either.
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: locked.path) }

        let outcome = RecoveryManager(archiveRoot: locked).recoverInterruptedSessions()
        #expect(outcome.unscannable)
        #expect(!outcome.isEmpty)
    }
}
