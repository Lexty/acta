---
name: screencapturekit-audio
description: Capture system audio AND microphone with a single SCStream on macOS 15+/26 (ScreenCaptureKit). Use when working on AudioRecorder / meeting audio capture.
---

# ScreenCaptureKit: system audio + microphone in one stream

> The source of truth is Apple's official docs (links below). Below are verified facts and gotchas;
> check API details against the docs — versions change.

## Verified facts (macOS 15+/26)

- A single `SCStream` can deliver **both system audio and the microphone** at the same time.
  - `SCStreamConfiguration.capturesAudio = true` — system audio (the other participants).
  - `SCStreamConfiguration.captureMicrophone = true` — microphone (your own voice). Added in macOS 15.
  - `SCStreamConfiguration.excludesCurrentProcessAudio = true` — do not record the app's own audio.
- Buffers arrive in the delegate with **different types**: `SCStreamOutputType.audio` (system) and
  `.microphone` (microphone), with **different `CMFormatDescription`s**.
- **Gotcha 1:** you cannot write both streams into one `AVAssetWriterInput` — differing
  formats/sample rates corrupt the container. You need **two separate writers** → `system.wav` and `mic.wav`.
- **Gotcha 2:** even for audio-only you must provide an `SCContentFilter` for a display. Video is not
  needed — set a minimal video config and **ignore `.screen` frames** in the delegate.
- **Gotcha 3:** Screen Recording is a TCC permission requested at runtime when the stream starts.
  Check the status via `CGPreflightScreenCaptureAccess()`, request via `CGRequestScreenCaptureAccess()`.
  The microphone requires `NSMicrophoneUsageDescription` in Info.plist.
- **Gotcha 4 — `stopCapture()` does not appear to release the microphone (macOS 26).** Observed live:
  the mic indicator stays on and Control Center keeps attributing the mic to the app **after the
  process exits** (only `sudo killall coreaudiod` clears it), so no reference in the dead process can
  be the owner. The configuration is the API-level state that says whether the mic is captured, so the
  **current mitigation** — a plausible workaround, not a contractual guarantee, and unverified until
  the live matrix in the plan is run — is to disable the mic on the **still-live** stream and **await**
  it *before* stopping, releasing the stream only after both:
  ```swift
  try await stream.updateConfiguration(makeConfiguration(captureMicrophone: false))
  try await stream.stopCapture()
  ```
  Each call needs its **own** `do`/`catch`: one combined `do` lets an update failure skip the stop.
  This applies to the failed-`start()` cleanup too (a partially-started stream may already own the
  tap), and to any stream dropped by `didStopWithError` — dropping the reference releases nothing, so
  such a stream must be set aside and torn down, or the watchdog leaks a tap per restart.
- **Gotcha 5 — `updateConfiguration` replaces, it does not merge.** The mic-off configuration must be
  the *complete* configuration with one field flipped; a bare `SCStreamConfiguration()` with only
  `captureMicrophone = false` silently drops the sample rate, the channel count and `capturesAudio`.

## Configuration sketch (verify against the docs)

```swift
let config = SCStreamConfiguration()
config.capturesAudio = true
config.captureMicrophone = true
config.excludesCurrentProcessAudio = true
config.sampleRate = 48_000
config.channelCount = 2
// minimal video; .screen frames are ignored
config.width = 2; config.height = 2
```

In `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)`, route by `of type`:
`.audio` → system writer, `.microphone` → mic writer, `.screen` → ignore.

## Two tracks, always — no mix in the pipeline

`system.wav` and `mic.wav` are **both always produced** and are the source of truth: separate tracks
give "me vs. them" attribution for free, and for transcription two files beat one mixed file.

A mix (`combined.wav`) is **derived data** and is deliberately **not** part of the recording
pipeline — it costs a full extra copy, collapses the attribution, and was historically the most
fragile branch of assembly. It is not produced at all — an on-demand "Export mix" action is backlog,
not shipped code. Until it lands, the single case where a mix helps — listening back to a whole
meeting — is served by running `ffmpeg` by hand:
```
ffmpeg -i system.wav -i mic.wav -filter_complex amix=inputs=2:duration=longest combined.wav
```

**Important:** do not record into a single file — write **segments** instead; see the
`crash-safe-recording` skill (streaming writes, recovery after a crash). The final `system.wav` and
`mic.wav` are assembled from segments on a clean stop or during recovery.

## References
- captureMicrophone: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone
- capturesAudio: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio
- Audio+mic guide: https://creavit.studio/blog/screencapturekit-audio-recording-mac-guide
- ScreenCaptureKit overview: https://developer.apple.com/documentation/screencapturekit/
