# Acta — спецификация для реализации

> **Статус:** спецификация для автономной реализации (исполнитель — ralphex).
> Документ самодостаточный: все решения зафиксированы, критерии приёмки проверяемы.
> Если возникает неоднозначность — выбирать вариант, минимизирующий зависимости и
> сохраняющий приватность (данные встреч остаются локально, кроме шага саммари).

## 1. Что это и зачем

Личное минималистичное **macOS menu-bar** приложение: одной кнопкой записывает онлайн-встречи
(Slack, Teams, Google Meet и **любой** источник звука), затем **локально** транскрибирует и
через **локальный Claude Code** генерирует структурированное саммари. Результат — **Markdown-архив**,
служащий дополнительным рабочим контекстом: к нему возвращаются, ищут «что/где/когда договорились»,
и его же читает Claude Code пользователя.

**Definition of Done (v1):** из меню-бара стартуется запись; звук собеседников и микрофон
пишутся раздельно; по «стоп» автоматически создаётся папка встречи с `transcript.md`,
`summary.md` и `meeting.md` (front-matter); всё собирается и запускается без полного Xcode.

## 2. Среда (факт на момент написания)

- Apple M3, 16 GB, **macOS 26.2** (таргет `arm64-apple-macosx26`).
- **Swift 6.3.3** (`/usr/bin/swift`, `swiftc`), только **Command Line Tools**, полного Xcode **нет**.
- Установлено и проверено: `ffmpeg` (8.1.2), `mlx_whisper` (модель large-v3-turbo в кэше HF),
  `claude` CLI **v2.1.210** (есть `-p/--print`).
- Дом проекта: `/Users/<user>/dev/personal/acta` (эта папка; «acta» = протоколы).

## 3. Зафиксированные решения

| Аспект | Решение | Почему |
|---|---|---|
| Тип приложения | SwiftUI `MenuBarExtra`, `LSUIElement=true` | минимализм, всегда под рукой, без дока |
| Сборка | **SwiftPM** (`swift build`) + скрипт упаковки в `.app` + ad-hoc `codesign` | полного Xcode нет; всё скриптуемо |
| Захват звука | **один `SCStream`** (ScreenCaptureKit): системный звук + микрофон | универсально для любого приложения-источника |
| Транскрипция | **WhisperKit** on-device (`large-v3-turbo`), fallback → CLI `mlx_whisper` | приватно, быстро на ANE/Metal; fallback уже проверен |
| Саммари | **`claude -p`** (локальный Claude Code) | выбор пользователя; качество + его доверенный контур |
| Хранилище | **Markdown-архив** `~/Acta/` с YAML front-matter + `CLAUDE.md` | «контекст к работе», agent-friendly, грепается |

## 4. Технические координаты

- **ScreenCaptureKit** (один стрим, обе дорожки раздельно):
  - `SCStreamConfiguration`: `capturesAudio = true`, `captureMicrophone = true`,
    `excludesCurrentProcessAudio = true`; видео-конфиг минимальный (кадры `.screen` игнорируем).
  - Выходы делегата приходят с типами `SCStreamOutputType.audio` (системный звук) и
    `.microphone` (микрофон) — **разные `CMFormatDescription`** → **два отдельных writer'а**.
  - Требуется `SCContentFilter` на дисплей даже для audio-only.
  - Docs: <https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone>
- **Запись в файлы:** два `AVAssetWriter`/`AVAudioFile` → `system.wav`, `mic.wav` (48 kHz).
  Микс-даун в `mixed-16k.wav` (mono, 16 kHz) для транскрипции — через `ffmpeg`
  (`ffmpeg -i system.wav -i mic.wav -filter_complex amix=inputs=2:duration=longest -ar 16000 -ac 1 mixed-16k.wav`).
- **WhisperKit:** SwiftPM-пакет `https://github.com/argmaxinc/WhisperKit` (репозиторий также
  известен как `argmax-oss-swift`, MIT, macOS 14+), product `WhisperKit`, модель
  `openai_whisper-large-v3-v20240930_turbo`; авто-загрузка модели при первом запуске (~1 ГБ).
  Возвращать текст + сегменты с таймкодами.
- **Саммари:** `claude -p "<prompt>"` с `cwd` = папка встречи; читать саммари из **stdout**
  и сохранять самим (Claude ничего не пишет на диск → без запросов разрешений).
  Промпт — из `Resources/summary-prompt.md`.
- **Разрешения (TCC):** Microphone (`NSMicrophoneUsageDescription` в Info.plist) и Screen
  Recording (запрашивается рантаймом при старте `SCStream`). Проверка статуса — `CGPreflightScreenCaptureAccess()`.

## 5. Структура проекта

```
acta/
  Package.swift                     # executable target Acta; dep: WhisperKit
  Sources/Acta/
    ActaApp.swift                   # @main, MenuBarExtra, состояние idle/recording/processing
    AudioRecorder.swift             # SCStream, два AVAssetWriter, стоп, микс-даун (ffmpeg)
    Transcriber.swift               # protocol Transcriber + WhisperKitTranscriber + CLITranscriber
    Summarizer.swift                # запуск `claude -p`, парсинг stdout
    MeetingStore.swift              # папки, YAML front-matter, meeting.md, CLAUDE.md архива
    Pipeline.swift                  # stop → mix → transcribe → summarize + статусы/ошибки
    Permissions.swift               # проверка/запрос Screen Recording + Microphone
    Settings.swift                  # путь архива, модель, выбор бэкенда, путь промпта
    SourceDetector.swift            # (nice-to-have) авто-заголовок по запущенным приложениям
  Resources/
    summary-prompt.md               # шаблон промпта саммари
    Info.plist                      # LSUIElement, NSMicrophoneUsageDescription, bundle id/version
    Acta.entitlements               # минимальные (без сэндбокса — личное использование)
  Scripts/
    bundle.sh                       # swift build -c release → Acta.app + Info.plist + ad-hoc sign
    run.sh                          # собрать и запустить
  CLAUDE.md                         # операционная памятка проекту (команды сборки/запуска/verify)
  SPEC.md                           # этот документ
```

## 6. Формат хранилища

`~/Acta/` (путь настраивается), папка на встречу:
`YYYY-MM-DD_HHMM__<slug>/` содержит:
- `system.wav`, `mic.wav` — сырые дорожки (mic — для возможной будущей диаризации/атрибуции).
- `transcript.md` — текст + сегменты с таймкодами.
- `summary.md` — вывод Claude.
- `meeting.md` — индексный файл с YAML front-matter и ссылками на остальное:
  ```yaml
  ---
  title: <заголовок>
  date: <ISO8601>
  source: <slack|teams|meet|other>
  participants: []
  duration: <sec>
  tags: []
  ---
  ```
- В корне `~/Acta/CLAUDE.md` — краткое описание, чтобы Claude Code пользователя видел архив
  как искомый рабочий контекст.

## 7. Рецепт сборки без Xcode (`Scripts/bundle.sh`)

Ключевой риск — собрать SwiftUI-приложение в `.app` без Xcode. Порядок:
1. `swift build -c release` → бинарь в `.build/release/Acta`.
2. Собрать бандл руками:
   `Acta.app/Contents/MacOS/Acta`, `Acta.app/Contents/Resources/*`, `Acta.app/Contents/Info.plist`.
3. Info.plist: `CFBundleExecutable=Acta`, `CFBundleIdentifier=dev.personal.acta` (фиксированный —
   важно для стабильности TCC), `LSUIElement=true`, `NSMicrophoneUsageDescription=<текст>`,
   `LSMinimumSystemVersion=14.0`.
4. Ad-hoc подпись со стабильной идентичностью:
   `codesign --force --sign - --entitlements Resources/Acta.entitlements --identifier dev.personal.acta Acta.app`.
5. Запуск: `open Acta.app` (или `run.sh`).

## 8. Порядок реализации и критерии приёмки (для loop-агента)

Идти строго по шагам; каждый шаг имеет **проверяемый критерий** — не переходить дальше, пока не выполнен.

1. **Скелет + сборка.** Пакет, пустой `MenuBarExtra`, `bundle.sh`.
   ✅ `bash Scripts/bundle.sh` завершается без ошибок; `open Acta.app` показывает иконку в меню-баре.
2. **Разрешения + запись.** `Permissions`, `AudioRecorder` (обе дорожки), стоп, микс.
   ✅ После записи 30–60 с существуют непустые `system.wav` и `mic.wav`, создан `mixed-16k.wav`
   (`ffprobe` показывает длительность > 0 и 16 kHz mono для микса).
3. **Хранилище.** `MeetingStore` + `Pipeline`: раскладка папок, `meeting.md` с корректным front-matter.
   ✅ Папка встречи создаётся; `meeting.md` парсится как YAML (проверить `python3 -c` или `yq`).
4. **Транскрипция.** `WhisperKitTranscriber` (при трении — сразу `CLITranscriber` на `mlx_whisper`).
   ✅ `transcript.md` непустой и содержит осмысленный русский/английский текст на тестовой записи.
5. **Саммари.** `Summarizer` через `claude -p`; сборка `meeting.md`, `~/Acta/CLAUDE.md`.
   ✅ `summary.md` содержит секции TL;DR, булеты, action items (непустые).
6. **Menu-bar UX.** Старт/стоп, таймер записи, индикатор обработки, список последних встреч,
   «открыть папку / показать саммари», нотификация о готовности.
   ✅ Полный цикл проходится только мышью из меню-бара.
7. **Настройки.** Путь архива, модель, бэкенд транскрипции, редактирование промпта.
   ✅ Смена пути архива подхватывается новой записью.

## 9. Шаблон промпта саммари (`Resources/summary-prompt.md`)

Промпт должен просить Claude вернуть **чистый Markdown** со структурой:
`# <title>` → `## TL;DR` (2–4 предложения) → `## Ключевые темы` → `## Решения` →
`## Action items` (в формате `- [ ] <что> — <кто> — <срок?>`) → `## Открытые вопросы` →
`## Теги`. Язык саммари — по языку транскрипта. На вход подаётся `transcript.md`.

## 10. Риски и fallback

- **ScreenCaptureKit audio-only** всё равно требует content-filter дисплея → минимальный видео-конфиг,
  игнорировать `.screen`-кадры.
- **TCC + ad-hoc подпись:** при смене идентичности бандла разрешения слетают → фиксировать
  `CFBundleIdentifier` и `--identifier` при подписи; если Screen Recording капризит — задокументировать
  в `CLAUDE.md` процедуру повторной выдачи.
- **WhisperKit в ad-hoc бандле** может дать трение с загрузкой/компиляцией CoreML-моделей →
  **fallback `CLITranscriber`**: вызывать `mlx_whisper <mixed-16k.wav> --model mlx-community/whisper-large-v3-turbo
  --language ru --output-format txt` (уже работает на машине). Реализовать оба бэкенда за протоколом
  `Transcriber` с настраиваемым выбором — не блокироваться на WhisperKit.
- **`claude -p`** использует подписку/аутентификацию Claude Code пользователя; содержимое встреч
  уходит в Anthropic через его доверенный контур — это осознанный выбор.
- **Приватность/этика:** запись созвонов с другими людьми может требовать их согласия — зона
  ответственности пользователя.

## 11. Справочные ссылки

- ScreenCaptureKit / microphone: <https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone>
- ScreenCaptureKit audio+mic гайд: <https://creavit.studio/blog/screencapturekit-audio-recording-mac-guide>
- WhisperKit (argmax-oss-swift): <https://github.com/argmaxinc/WhisperKit>
- Claude Code CLI (`-p`): <https://docs.claude.com/en/docs/claude-code/cli-reference>
