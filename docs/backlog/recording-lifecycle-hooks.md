---
worth: yes
added: 2026-09-11
---
# User-configured commands on recording lifecycle events

Let the user attach their own commands to recording events, so that integrations with other programs
live in scripts they own rather than in Acta. The motivating case is personal and stays in user config:
on **recording started**, run an agent non-interactively that finds the current meeting in the calendar,
finds its huddle in Slack, and attaches the link to that recording's metadata, so nothing has to be
looked up afterwards. Acta supplies the event and its context; what happens next is the script's
business. This keeps the SPEC boundary intact — Acta records and does not transcribe — while making
"transcribe as it records" possible from outside.

## Events

- **recording started** — the folder exists and `info.md` has been written with `status: recording`.
- **recording stopped** — capture has ended; assembly may still be running.
- Later, if they earn it:
  - **segment finalized** — a closed segment WAV is on disk. The natural hook for incremental
    transcription. Rotation happens in `SegmentWriter.rotate` and, on a watchdog restart, in
    `finishAndAdvance`; both have to fire it.
  - **recording ready** — an assembled recording has appeared in the archive. ⚠️ Recovery also produces
    finished recordings (`status: recovered`), so this event must fire from the recovery path too, not
    only from `performStop`.

## What was found while filing it

- **Nothing blocks spawning.** The app is not sandboxed (`Resources/Acta.entitlements`), and
  `SegmentAssembler` already runs `ffmpeg` through `Process`.
- **The socket's `watch` stream is not a substitute for this.** An external watcher could observe start
  and stop today, but `watchEvents()` in `ControlDispatcher` buffers only the newest state and coalesces
  (its own comment says a client can see sequence 1 then 4). A trigger that must fire exactly once per
  recording, or once per segment, cannot be built on a stream that may drop states. It also needs a
  process that is always running beside the app.
- There is no calendar integration in the code yet. The `eventkit-calendar` skill describes one; if it
  lands, "current meeting" may belong in the event payload rather than in every user's script.

## Open design questions, none settled

- **Configuration** — where the commands live (settings, or a hooks file in the archive or in
  `~/Library/Application Support`) and how the dev and stable flavors keep separate ones.
- **Payload** — environment variables versus JSON on stdin: recording id, folder path, title, source,
  start time, and the segment path for a segment event.
- **Isolation** — a hook must never delay or endanger capture. Run it detached, with a timeout, and log
  its exit status and stderr somewhere findable, possibly beside the recording.
- **Write-back** — the motivating script edits the recording's metadata while Acta may also rewrite
  `info.md` (stop, recovery patching). Either give hooks their own file in the recording folder or define
  which fields Acta never overwrites.
- **TCC attribution** — a child process may be attributed to Acta for privacy permissions (calendar, for
  example). This is unmeasured; check it before promising a script calendar access.
