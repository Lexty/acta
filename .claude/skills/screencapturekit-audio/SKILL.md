---
name: screencapturekit-audio
description: Захват системного звука И микрофона одним SCStream на macOS 15+/26 (ScreenCaptureKit). Использовать при работе с AudioRecorder / записью звука встреч.
---

# ScreenCaptureKit: системный звук + микрофон одним стримом

> Источник истины — официальные доки Apple (ссылки внизу). Ниже — проверенные факты и
> подводные камни; API-детали сверять по докам, версии меняются.

## Ключевые проверенные факты (macOS 15+/26)

- Один `SCStream` может отдавать **и системный звук, и микрофон** одновременно.
  - `SCStreamConfiguration.capturesAudio = true` — системный звук (голоса собеседников).
  - `SCStreamConfiguration.captureMicrophone = true` — микрофон (мой голос). Добавлено в macOS 15.
  - `SCStreamConfiguration.excludesCurrentProcessAudio = true` — не писать собственный звук приложения.
- Буферы приходят в делегат с **разными типами**: `SCStreamOutputType.audio` (система) и
  `.microphone` (микрофон), с **разными `CMFormatDescription`**.
- **Гатча №1:** нельзя писать оба потока в один `AVAssetWriterInput` — из-за разных форматов/частот
  контейнер побьётся. Нужно **два отдельных writer'а** → `system.wav` и `mic.wav`.
- **Гатча №2:** даже для audio-only нужно задать `SCContentFilter` на дисплей. Видео не нужно —
  задать минимальный видео-конфиг и **игнорировать `.screen`-кадры** в делегате.
- **Гатча №3:** Screen Recording — это TCC-разрешение, спрашивается рантаймом при старте стрима.
  Проверять статус через `CGPreflightScreenCaptureAccess()`, запрос — `CGRequestScreenCaptureAccess()`.
  Микрофон требует `NSMicrophoneUsageDescription` в Info.plist.

## Скелет конфигурации (сверять по докам)

```swift
let config = SCStreamConfiguration()
config.capturesAudio = true
config.captureMicrophone = true
config.excludesCurrentProcessAudio = true
config.sampleRate = 48_000
config.channelCount = 2
// минимальный видео, кадры .screen игнорируем
config.width = 2; config.height = 2
```

Делегат `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)`: по `of type` разводить
`.audio` → system-writer, `.microphone` → mic-writer, `.screen` → игнор.

## Микс для транскрипции

Транскрипции нужен один mono 16 kHz WAV. Использовать установленный `ffmpeg`:
```
ffmpeg -i system.wav -i mic.wav -filter_complex amix=inputs=2:duration=longest -ar 16000 -ac 1 mixed-16k.wav
```
Сырые `system.wav`/`mic.wav` сохранять (пригодятся для будущей диаризации/атрибуции спикеров).

## Ссылки
- captureMicrophone: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone
- capturesAudio: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio
- Гайд audio+mic: https://creavit.studio/blog/screencapturekit-audio-recording-mac-guide
- ScreenCaptureKit обзор: https://developer.apple.com/documentation/screencapturekit/
