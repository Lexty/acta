---
worth: yes
where: tools/acta-notes/plugin/skills/acta-notes/scripts/archive_retention.py:202
added: 2026-09-13
---
# the retention gate accepts warn, and its skill promises every check green

`verify_state` treats only a `red` check as withholding the audio; a `warn` passes unless
`--strict-verify` is given, and the docstring explains why — treating warn as red pinned 23 of 155
meetings at full size. The retention section of `SKILL.md` still tells the reader that every check
must be green before anything is compressed or deleted.

Both positions are defensible. Having both in the repository is not: the document a user reads
before letting a destructive pass run describes a stricter gate than the one that runs.

⚠️ Separately, `verify_state` called on `{"checks": [null]}` returns green with zero checks, because
non-dict entries are filtered out and an empty list is then vacuously green. A malformed
`verify.json` therefore reads as a pass in a delete gate. Absent is already handled deliberately
(old meetings predate the pipeline); malformed should not share that path.

Found by Codex during a behaviour audit before publication; both paths read here afterwards.
