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

## A second reproducer, measured 2026-09-11 (Task 9)

Task 9's live identity probe reproduces item 1 on demand, which the original run could not.

The probe's live tests call `AVCaptureDevice.DiscoverySession` — the first use of AVFoundation's
**capture** stack anywhere in this binary. Measured:

- the **first** `DiscoverySession` in a process costs **221 ms**; every later one **0.04 ms**. It is a
  one-time initialization, not a per-call cost.
- Paying it *inside* the parallel suite: the full gate goes from **7.6 s to 67 s**, and
  `aRecordingBackedByAFakeSourceCrossesASegmentBoundaryAndAssembles` fails with `segmentCount == 0` —
  `SegmentWriter.finish` exhausting its 30-second `pendingWrites` wait, exactly as in the original
  finding.
- Paying it **once, before the suite starts** (`MicrophoneIdentityProbe.warmUp()`, called from
  `main.swift`): **7.8 s**, all tests mandatory, and the in-suite discoveries are free.
- Stubbing AVFoundation while keeping every CoreAudio HAL read the probe makes: **7.2 s**. So the HAL
  half is not implicated.

⚠️ **The mechanism is still not established, and is deliberately not named here.** What is measured is
the four numbers above. A plausible story — that capture-stack initialization needs servicing the main
thread while a `@MainActor` test holds it — is a *story*; writing it down as the cause would be the
same mistake this file was created to record. What it adds to item 1 is a cheap, deterministic
reproducer: 220 ms of blocking work on the cooperative pool is enough to push concurrent segment
finalisation past a 30-second timeout, which is a very large amplification and the thing worth
explaining.

`MicrophoneIdentityProbe.isWarm` exists so deleting the warm-up fails a test rather than silently
restoring a 60-second flaky gate.

## A third reproducer, and the first usable sample, measured 2026-09-12

The owner-release stop offer added a suite of eleven tests, each starting a real recording from a prompt
and stopping it. On its own, together with the socket suites, and together with the reminder suites it
passes. In the full gate it failed **every run it was part of** (ten completed, plus one sampled and stopped): 16–17 issues, the socket suites and
`aRecordingBackedByAFakeSourceCrossesASegmentBoundaryAndAssembles` timing out at **62 s**, and dozens of
unrelated tests — pure ones included — reporting ~62 s durations.

What was measured, in order:

- **A `sample` of the runner during the stall shows all 13 cooperative-pool threads in
  `SegmentWriter.finish` → `DispatchGroup.wait(wallTimeout:)`**, called from `AudioRecorder.stop()` inside
  its serialized lifecycle, while two dozen `com.apple.coremedia.mediaprocessor.audiocompression` threads
  exist. This is the first sample with usable thread states, and it answers item 3 as far as it goes:
  the pool is exhausted by writers synchronously waiting for their own finalisation. It does **not** show
  what the finalisations themselves are waiting for.
- **It is the suite's recordings, not its presence.** With the recording start turned into an early
  return: 940 tests, green, 23.8 s.
- **It is overlap in time, not the amount of audio.** Freezing the test clock after `.recording` (so
  nothing more is written) and serializing the suite with the reminder coordinator's: still 17 issues. An
  8-second sleep before each recording start: 942 tests, green, 110 s.
- **Serializing the two meter suites that still stopped recordings in parallel** ("Activity meter in the
  pipeline", "Activity meter gate") restored the gate: 942 tests, 28 s, three runs out of three. Their
  unserialized state is the only change between the last failing run and the first green one.

So the suite sits at an edge: roughly a pool's width of writers finishing at once. Serializing suites
moves the gate back from it; it does not move the edge, and item 1 is still the question. A test-only
mitigation keeps being the answer because the production app has one recording, and a synchronous wait
on the cooperative pool is only reachable at this width in a parallel test run — which is an argument
about today's app, not a guarantee about the code.
