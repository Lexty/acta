---
worth: yes
where: tools/acta-notes/plugin/skills/acta-notes/scripts/archive_retention.py:446
added: 2026-09-13
---
# a timed-out restore leaves a partial wav that the next run reports as restored

`restore_meeting` decodes `<stem>.opus` straight into its final `<stem>.wav` with `ffmpeg -y`. If the
decode times out or the process dies, the partial file stays. The next run reaches

```python
if out.exists():
    rec.update(status="skipped", reason="wav already present")
```

and reports the meeting restored, with zero encoder invocations — so a truncated recording is
indistinguishable from a complete one, in the one operation whose whole job is to bring audio back
after the original was deleted.

Found by Codex during a behaviour audit before publication, with a probe under
`/tmp/acta-behavior-audit/probe.py`; the code path was then read here and matches.

The shape of the fix is a decode to a temporary file in the same directory and a rename on success,
plus removal of the partial on any failure — the same discipline the recorder itself uses for
segments. A cheaper half-measure, refusing to skip a `.wav` whose duration does not match the encoded
source, would catch it but still leave the bad file on disk.

⚠️ Related and not the same: `decoded_duration_seconds` is the delete gate, and it reads `stdout` to
exhaustion *before* waiting with a timeout, so a stalled `ffmpeg` is not bounded by that timeout, and
`stderr` is never drained — a chatty failure can fill that pipe and deadlock. Measured: a 0.01 s
timeout took 0.76 s against a decoder sleeping 0.4 s.
