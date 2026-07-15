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

## Combined file

Besides the separate tracks, build a combined `combined.wav` (a mix of the two) via `ffmpeg`:
```
ffmpeg -i system.wav -i mic.wav -filter_complex amix=inputs=2:duration=longest combined.wav
```
Keep the raw `system.wav`/`mic.wav` — separate tracks enable future "me vs. them" attribution.

**Important:** do not record into a single file — write **segments** instead; see the
`crash-safe-recording` skill (streaming writes, recovery after a crash). The final
`system/mic/combined.wav` are assembled from segments on a clean stop or during recovery.

## References
- captureMicrophone: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone
- capturesAudio: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio
- Audio+mic guide: https://creavit.studio/blog/screencapturekit-audio-recording-mac-guide
- ScreenCaptureKit overview: https://developer.apple.com/documentation/screencapturekit/
