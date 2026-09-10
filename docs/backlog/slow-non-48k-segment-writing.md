# Writing a non-48 kHz source is pathologically slow

**Found:** 2026-09-10, while building the format-switch acceptance test for Task 5 of
`docs/plans/2026-09-09-microphone-priority.md`.

**Why this is not a test-tuning note.** The AirPods on this machine were **measured at 24 000 Hz**
(`docs/plans/2026-09-09-microphone-priority.md`, "Measured facts"). So the format this slow path is
slow for is the format of the exact device that started this whole feature.

## The measurement

`CaptureMicrophoneTests.aFormatSwitchKeepsEverySegmentValid`, one case, 48 kHz stereo → 24 kHz stereo,
**one** 48 000-frame buffer delivered on each side of the switch:

| suite | wall clock |
|---|---|
| whole suite with the test removed | **4.25 s** |
| whole suite with this one case | **63.3 s** |

So a single 24 kHz buffer costs roughly a minute. Reducing the audio helped not at all: three buffers
per side and one buffer per side both cost the same ~59 s, and the four-case matrix (adding mono and
48 kHz variants) also cost ~63 s in total. **Cost is flat in the amount of audio**, which is what rules
out "sample-rate conversion is expensive" and points at a stall — a retry, a timeout, or a
per-buffer converter setup that blocks — rather than throughput.

The same test with **no** format change is instant, so nothing in the test's own shape accounts for it.

## What is not known

- Which layer stalls. `SegmentWriter`'s conversion, `AVAudioConverter`, or `ExtAudioFile` were not
  instrumented; the measurement above is end-to-end.
- Whether a **real** 24 kHz microphone hits it. The buffers here come from `FakeCaptureSource`, which
  synthesises them through `AVAudioFormat`; a real `SCStream` microphone buffer may differ in a way
  that matters. ⚠️ **Do not report this as a confirmed production defect until that is checked** — a
  peer review already attributed one format failure to Acta that turned out to be its own sandbox, and
  the same discipline applies here.

## Why it was not chased now

Task 5's checklist item is the *correctness* of a format switch — every segment valid, the post-switch
audio actually written — and that now has a test which passes. The slowness is a separate defect that
surfaced while writing it. Chasing it would have meant instrumenting the writer mid-task.

## What to do

1. Record a real 24 kHz device (the AirPods) with a TCC-authorised build and time the segment writes.
   If it is slow there too, this is a shipping defect: an hour-long meeting on a Bluetooth headset.
2. If it reproduces, instrument `SegmentWriter`'s conversion path and find the stall.
3. Once it is fixed, widen `aFormatSwitchKeepsEverySegmentValid` back to the full matrix — mono and
   48 kHz variants — which is currently one case only because of this cost.
