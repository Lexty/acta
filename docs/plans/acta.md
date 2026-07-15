# Plan: Acta — запись и осмысление онлайн-встреч (macOS)

## Overview

Реализовать минималистичное macOS menu-bar приложение **Acta** строго по спецификации
`SPEC.md` в корне репозитория: запись онлайн-встреч (системный звук + микрофон одним
`SCStream`), локальная транскрипция (WhisperKit `large-v3-turbo`, fallback — CLI `mlx_whisper`),
саммари через локальный `claude -p`, хранилище — Markdown-архив `~/Acta/` с YAML front-matter.

**Читать `SPEC.md` перед каждой задачей** — там зафиксированы все решения, точные координаты
API/пакетов, рецепт сборки без Xcode и критерии приёмки. При неоднозначности выбирать вариант,
минимизирующий зависимости и сохраняющий приватность.

Среда: Apple M3, macOS 26.2, Swift 6.3.3, только CLT (полного Xcode нет), собирать через SwiftPM.
Установлены и проверены: `ffmpeg`, `mlx_whisper` (large-v3-turbo), `claude` CLI.

## Validation Commands
- `swift build -c release`
- `bash Scripts/bundle.sh`

### Task 1: Скелет пакета и сборка без Xcode
- [ ] `Package.swift`: executable target `Acta`, зависимость `https://github.com/argmaxinc/WhisperKit` (product `WhisperKit`), platform macOS 14+
- [ ] `Sources/Acta/ActaApp.swift`: `@main`, пустой `MenuBarExtra` с иконкой
- [ ] `Resources/Info.plist` (`LSUIElement=true`, `CFBundleIdentifier=dev.personal.acta`, `NSMicrophoneUsageDescription`, `LSMinimumSystemVersion=14.0`) и `Resources/Acta.entitlements` (минимальные, без сэндбокса)
- [ ] `Scripts/bundle.sh`: `swift build -c release` → сборка `Acta.app/Contents/{MacOS,Resources}` + Info.plist + `codesign --force --sign - --identifier dev.personal.acta --entitlements`; `Scripts/run.sh`
- [ ] Приёмка: `bash Scripts/bundle.sh` собирает `Acta.app` без ошибок; `open Acta.app` показывает иконку в меню-баре

### Task 2: Разрешения и запись двух дорожек
- [ ] `Permissions.swift`: проверка/запрос Screen Recording (`CGPreflightScreenCaptureAccess`) и Microphone
- [ ] `AudioRecorder.swift`: один `SCStream` (`capturesAudio=true`, `captureMicrophone=true`, `excludesCurrentProcessAudio=true`, минимальный видео-конфиг), два `AVAssetWriter` → `system.wav`, `mic.wav`
- [ ] Микс-даун в `mixed-16k.wav` (mono, 16 kHz) через `ffmpeg`
- [ ] Приёмка: запись 30–60 с даёт непустые `system.wav` и `mic.wav`; `ffprobe` показывает `mixed-16k.wav` 16 kHz mono длительностью > 0

### Task 3: Хранилище и пайплайн
- [ ] `MeetingStore.swift`: папка `~/Acta/YYYY-MM-DD_HHMM__<slug>/`, `meeting.md` с YAML front-matter (`title,date,source,participants,duration,tags`)
- [ ] `Pipeline.swift`: оркестрация stop → mix → transcribe → summarize со статусами и обработкой ошибок
- [ ] Приёмка: папка встречи создаётся; `meeting.md` парсится как YAML (проверить `python3`/`yq`)

### Task 4: Транскрипция
- [ ] `Transcriber.swift`: протокол `Transcriber` + `WhisperKitTranscriber` (модель `openai_whisper-large-v3-v20240930_turbo`) + `CLITranscriber` (fallback на `mlx_whisper`)
- [ ] `transcript.md` с текстом и сегментами/таймкодами
- [ ] Приёмка: `transcript.md` непустой и содержит осмысленный текст на тестовой записи (при трении с WhisperKit в ad-hoc бандле — переключиться на `CLITranscriber`, не блокироваться)

### Task 5: Саммари через локальный Claude Code
- [ ] `Resources/summary-prompt.md`: шаблон (TL;DR, ключевые темы, решения, action items `- [ ] что — кто — срок?`, открытые вопросы, теги; язык — по языку транскрипта)
- [ ] `Summarizer.swift`: запуск `claude -p "<prompt>"` с `cwd` = папка встречи, чтение саммари из stdout, сохранение в `summary.md`
- [ ] Сборка `meeting.md` (ссылки на transcript/summary) и `~/Acta/CLAUDE.md` (описание архива как рабочего контекста)
- [ ] Приёмка: `summary.md` содержит непустые секции TL;DR, булеты, action items

### Task 6: Menu-bar UX
- [ ] Старт/стоп, таймер записи, индикатор обработки (idle/recording/processing)
- [ ] Список последних встреч с действиями «открыть папку / показать саммари»
- [ ] Локальная нотификация о готовности саммари
- [ ] Приёмка: полный цикл (старт → запись → стоп → transcript+summary) проходится только из меню-бара мышью

### Task 7: Настройки
- [ ] `Settings.swift`: путь архива, выбор модели, выбор бэкенда транскрипции, путь к промпту саммари
- [ ] `SourceDetector.swift` (nice-to-have): авто-подсказка заголовка по запущенным приложениям (Slack/Teams/zoom.us/браузер) через `NSWorkspace`
- [ ] Приёмка: смена пути архива в настройках подхватывается новой записью
