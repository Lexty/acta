---
name: whisperkit-transcription
description: On-device транскрипция через WhisperKit (пакет argmax-oss-swift) с fallback на CLI mlx_whisper. Использовать при реализации Transcriber.
---

# WhisperKit: on-device транскрипция

> Источник истины — README пакета и доки (ссылки внизу). Ниже — проверенные факты; точный
> API сверять по текущей версии пакета (переименовывался, менялся).

## Проверенные факты

- SwiftPM-пакет: `https://github.com/argmaxinc/WhisperKit` (репозиторий также известен как
  **`argmax-oss-swift`**, MIT). Product для импорта — `WhisperKit`. Минимум **macOS 14+**.
- Работает on-device на Apple Silicon (ANE/Metal/CoreML). Модели качаются с HuggingFace при
  первом запуске и кэшируются.
- Целевая модель — turbo-вариант large-v3: `openai_whisper-large-v3-v20240930_turbo`
  (баланс качество/скорость; ту же turbo-модель мы уже валидировали через mlx_whisper).
- Пакет также содержит **SpeakerKit** (диаризация pyannote) — на будущее для атрибуции спикеров,
  в scope v1 не входит.

## Скелет использования (сверять по докам версии)

```swift
import WhisperKit
let pipe = try await WhisperKit(model: "openai_whisper-large-v3-v20240930_turbo")
let results = try await pipe.transcribe(audioPath: mixed16kURL.path)
// results → сегменты с текстом и таймкодами; собрать transcript.md
```

## Архитектура: протокол + fallback (важно — не блокироваться)

Реализовать за протоколом `Transcriber` ДВА бэкенда:
1. `WhisperKitTranscriber` — по умолчанию.
2. `CLITranscriber` — **fallback**, уже проверен и работает на этой машине:
   ```
   mlx_whisper <mixed-16k.wav> --model mlx-community/whisper-large-v3-turbo \
     --language ru --output-format txt --output-dir <dir>
   ```
   Если WhisperKit в ad-hoc бандле даст трение с загрузкой/компиляцией CoreML-моделей —
   **переключиться на CLITranscriber и идти дальше**, не застревать.

## Гатчи
- Первый запуск качает модель (~1 ГБ) — учесть таймаут/индикатор.
- Язык встреч смешанный ru/en — оставлять авто-определение или делать настраиваемым.
- Транскрипт сохранять с сегментами/таймкодами (пригодится для навигации по записи).

## Ссылки
- WhisperKit / argmax-oss-swift: https://github.com/argmaxinc/WhisperKit
- Argmax blog: https://www.argmaxinc.com/blog/whisperkit
