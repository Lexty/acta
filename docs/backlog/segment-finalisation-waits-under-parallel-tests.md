# `SegmentWriter.finish` exhausts its 30-second wait under parallel tests

**Found:** 2026-09-10. **This file replaces a wrong diagnosis of mine**, which is the first thing it has
to say.

## What I claimed, and why it was wrong

I measured that adding a 48 kHz → 24 kHz format-switch test took the suite from 4 s to 63 s, saw that
the cost was flat in the amount of audio, and wrote it up as a **stall in the conversion path for
non-48-kHz sources** — noting that the AirPods on this machine measured 24 kHz, so the format that was
slow was the format of the device this whole feature is about. That was a frightening conclusion and it
was **not supported by the evidence I had**: I had a correlation between "this test changes the format"
and "the suite got slow", and I reasoned from it to a cause without measuring anything inside the
writer.

It is wrong. A peer review measured the actual mechanism:

- The 17 capture/loss tests, **including all three I had quarantined**, run in **0.439 s** on their own.
- The full 547-test gate with them enabled takes **64.2 s** and fails a pipeline assertion.
- With diagnostics added to `SegmentWriter.finish`, the time is many writers concurrently exhausting
  `pendingWrites.wait`'s **30-second timeout** — 30 s for the system track, then 30 s for the mic.
  Ordinary 48 kHz tests time out alongside the format one.

So it is **contention over segment finalisation under unrestricted test parallelism**, and it has
nothing to do with sample rate, channel count, or the AirPods.

## The fix that was applied

Marking the two I/O-heavy suites `.serialized`:

```swift
@Suite("Capture microphone", .serialized)
@Suite("Recording-owned microphone loss", .serialized)
```

Full gate, all three tests enabled: **~4.7 s**, with only the parked permission flake. Measured over
three runs here and independently by the review. The three tests are back in the mandatory gate; none
of them is optional any more.

## What is still open

1. **Why `pendingWrites.wait` can need 30 s at all.** The timeout exists to bound a finalisation that
   is not completing; a test suite hitting it in the ordinary course means either the wait is
   mis-sized, or finalisation genuinely blocks under concurrent writers. Serializing two suites hides
   the symptom in *this* suite; it says nothing about a real recording on a busy machine.
2. **What a timed-out finalisation leaves on disk.** The review notes it can leave a file that needs
   repair, which is a plausible alternative explanation for `AVAudioFile` refusing segments this suite
   produced — another thing I asserted (that the refusal was "a fact about the reader") without
   checking.
3. Sampling did not yield usable thread states, so no exact executor/AVFoundation cycle is proven.

## The "third instance" was my own misplaced brace

I recorded a section here claiming a third instance of the stall that was "not parallelism": two loss
tests costing thirty seconds each inside an already-serialized suite. **That was wrong in its premise.**
`RecordingMicrophoneLossTests`' closing brace sat *above* five of its tests, so those tests — including
both new ones — were at **file scope and never serialized at all**. The runner said so in as many
words, `2 tests in 0 suites`, and I did not read it.

Moving one brace and removing the two opt-in guards: the full suite runs in **5.3 s** with every test
mandatory, and no `pendingWrites` wait longer than a second. Measured independently by the review and
reproduced here.

So there are **no** tests behind an opt-in flag now, and my assertion that "they are already in a
serialized suite, so serializing cannot help" was an assumption about where the suite ended rather
than a measurement.

What the review *did* measure, and what stays open, is item 1 above: in a genuinely parallel full run,
multiple writers hit the 30-second `pendingWrites` timeout. That is real and unexplained. It is
**not** established that a single recording switched mid-way stalls — `finishAndAdvance` does not wait
on `pendingWrites` at all, which is another thing I asserted without reading it.

## The lesson worth keeping

A stall whose cost is flat in the amount of work is evidence of *a* stall. It is not evidence of *which*
stall, and certainly not of which subsystem. The right next step was to instrument the writer, which
takes minutes; instead I wrote a backlog entry naming a cause I had not measured, and told the user
their headset's format was implicated. Two of today's other findings have the same shape.
