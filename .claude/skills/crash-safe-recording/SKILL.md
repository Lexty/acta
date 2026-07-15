---
name: crash-safe-recording
description: Crash-safe streaming audio recording on macOS — segmentation, recovery after restart, startup self-diagnosis. Use for AudioRecorder/SegmentWriter/RecoveryManager/SelfCheck.
---

# Crash-safe streaming recording

> Requirement: the recording is streamed to disk, survives a restart/crash, and the app diagnoses
> itself if recording did not start. Below is the proven approach and the main gotchas.

## The main gotcha
`AVAssetWriter` produces a **valid file only after `finishWriting()`**. On `kill -9`/restart an
unfinalised file is usually **corrupt** (header/index not written). So you must not write the whole
meeting into one unfinalised file — you would lose everything.

## Solution: segmentation
- Write **short segments of ~10–15 s** (`SegmentWriter`): each segment is a separate `AVAssetWriter`
  that is **finalised** when the interval elapses and becomes a valid file.
  Files: `system/0000.wav`, `system/0001.wav`, …, and likewise for `mic/`.
- A hard failure then loses **at most the last, unfinalised segment**.
- Flush often; never keep the whole recording in memory.
- (Alternative, if the container misbehaves: write **raw PCM** per segment — a raw append is
  crash-safe by itself — and build the WAV on finalisation/recovery.)

## Session marker
`session.json` in the recording folder: `status` (`recording`/`done`/`recovered`), `started_at`,
config, segment count. Keep it up to date. A clean stop → `done` + assembly. Finding `recording` at
launch means the recording was interrupted abnormally.

## Recovery on launch (`RecoveryManager`)
At app startup scan the archive; for every folder with `status=recording`:
1. Take the valid segments in order (a corrupt/unfinished last one — **repair it from the actual file
   size if it holds data; drop it only if it does not**. Never fail the whole recovery over it).
2. Assemble via `ffmpeg` concat → `system.wav` and `mic.wav` (both, always — no mix on this path).
3. Set `status=recovered`, notify the user.
Keep the segment-selection logic a **pure function** and cover it with unit tests.

## Startup self-diagnosis (`SelfCheck`) + watchdog
- Within ~2 s of starting, verify **data is actually flowing** (current segment growing / buffers
  arriving). If not — determine the cause and **heal**:
  - no Screen Recording (`CGPreflightScreenCaptureAccess`==false) → request/guide;
  - `SCStream` did not come up / delegate error → restart (2–3 attempts);
  - no audio device → clear error.
- **Never** show "recording" when nothing is being written.
- **Watchdog** while recording: buffers stall for N s → flag, restart the stream while keeping the
  already written segments; if that fails → error in the UI.
- Diagnose tracks **separately**: a live track must not mask a dead one (that is half the meeting).
  A silent source (no buffers at all) is not a breakage — silence is indistinguishable from a dead
  device; only log it.

## ffmpeg
- Concatenate segments: `ffmpeg -f concat -safe 0 -i list.txt -c copy system.wav`
- Mixing is **not** part of the pipeline (see `screencapturekit-audio`): both tracks are always kept
  separate, and a mix is only produced on demand by the "Export mix" action.
- Keep command-argument construction in pure functions and cover it with unit tests.
