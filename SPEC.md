# Acta — спецификация для реализации

> **Статус:** спецификация для автономной реализации (исполнитель — ralphex).
> Документ самодостаточный: решения зафиксированы, критерии приёмки проверяемы.
> При неоднозначности выбирать вариант, минимизирующий зависимости и повышающий надёжность записи.

## 1. Что это и зачем

Личное минималистичное **macOS menu-bar** приложение, которое **только записывает** онлайн-встречи
(Slack, Teams, Google Meet и **любой** источник звука): системный звук (собеседники) + микрофон.
Транскрипция и саммари **вне scope** — делаются отдельно (у пользователя локально настроен `mlx_whisper`).

**Три обязательных свойства записи:**
1. **Потоковая запись на диск** — инкрементально по ходу встречи, без буферизации всей записи в памяти.
2. **Отказоустойчивость** — при рестарте/краше уже записанное валидно и восстанавливается.
3. **Самодиагностика** — если запись не началась/встала из-за ошибки, это ловится сразу и лечится.

**Definition of Done (v1):** из меню-бара стартуется/останавливается запись; системный звук и
микрофон пишутся раздельно потоком сегментами; при `kill -9`/рестарте уже записанные сегменты
сохраняются и на следующем запуске автоматически финализируются; при неудачном старте приложение
диагностирует причину и лечит/сообщает; всё собирается без полного Xcode.

## 2. Среда (факт)

- Apple M3, 16 GB, **macOS 26.2** (таргет `arm64-apple-macosx26`).
- **Swift 6.3.3**, только **Command Line Tools**, полного Xcode **нет** → сборка через SwiftPM.
- Установлено: `ffmpeg` (склейка/микс дорожек), `swiftlint` (через обёртку `Scripts/lint.sh`).
- Дом проекта: `/Users/<user>/dev/personal/acta`.

## 3. Зафиксированные решения

| Аспект | Решение | Почему |
|---|---|---|
| Тип приложения | SwiftUI `MenuBarExtra`, `LSUIElement=true` | минимализм, без дока |
| Сборка | **SwiftPM** + скрипт упаковки в `.app` + ad-hoc `codesign` | полного Xcode нет |
| Зависимости | **без внешних** (WhisperKit не нужен — транскрипции нет) | проще, надёжнее |
| Захват звука | **один `SCStream`**: системный звук + микрофон | универсально для любого источника |
| Запись на диск | **потоково, сегментами ~10–15 с** (каждый сегмент — валидный файл) | крэш теряет ≤ длину сегмента |
| Отказоустойчивость | `session.json` + восстановление на старте (склейка сегментов) | переживает рестарт/краш |
| Самодиагностика | проверка «данные текут» на старте + watchdog + авто-лечение | не «немой» recording без данных |
| Хранилище | папка на запись: аудио + `session.json` + `info.md` (front-matter) | «возвращаться к записям», agent-friendly |

## 4. Технические координаты

- **ScreenCaptureKit** (см. скилл `screencapturekit-audio`): один `SCStream`,
  `capturesAudio=true`, `captureMicrophone=true`, `excludesCurrentProcessAudio=true`,
  минимальный видео-конфиг; буферы `.audio`/`.microphone` → раздельные writer'ы.
- **Крэш-безопасная запись** (см. скилл `crash-safe-recording`): писать **короткими сегментами**,
  каждый финализируется как валидный файл; частый flush; никакой буферизации всей записи в памяти.
  Гатча: незакрытый `AVAssetWriter`-файл после жёсткого краша обычно битый → отсюда сегментирование.
- **Склейка/микс** через `ffmpeg`:
  - конкатенация сегментов дорожки → `system.wav`, `mic.wav`;
  - объединённый `combined.wav` (микс двух) `amix=inputs=2:duration=longest`.
- **Разрешения (TCC):** Microphone (`NSMicrophoneUsageDescription`), Screen Recording
  (рантайм; статус `CGPreflightScreenCaptureAccess()`, запрос `CGRequestScreenCaptureAccess()`).

## 5. Структура проекта

```
acta/
  Package.swift                     # executable Acta + testTarget ActaTests; БЕЗ внешних зависимостей
  Sources/Acta/
    ActaApp.swift                   # @main, MenuBarExtra, состояние idle/recording/error/recovered
    AudioRecorder.swift             # SCStream, раздельные дорожки, потоковая сегментная запись, flush
    SegmentWriter.swift             # ротация сегментов (~10–15 с), финализация каждого
    RecoveryManager.swift           # на старте: найти session.json status=recording → склеить сегменты
    SelfCheck.swift                 # проверка «данные текут» на старте + watchdog + авто-лечение
    Permissions.swift               # Screen Recording + Microphone
    MeetingStore.swift              # папки, session.json, info.md (front-matter), список записей
    Settings.swift                  # путь архива, дорожки, длина сегмента, удалять ли сегменты
    SourceDetector.swift            # (nice-to-have) авто-заголовок по запущенным приложениям
  Resources/{Info.plist, Acta.entitlements}
  Scripts/{bundle.sh, run.sh, lint.sh}
  CLAUDE.md, SPEC.md, .swiftlint.yml
```

## 6. Формат хранилища

`~/Acta/YYYY-MM-DD_HHMM__<slug>/`:
- Во время записи: `system/NNNN.wav`, `mic/NNNN.wav` (сегменты) + `session.json`
  (`status: recording|done|recovered`, `started_at`, конфиг, счётчик сегментов).
- После чистого стопа/восстановления: `system.wav`, `mic.wav`, `combined.wav` (склейка/микс);
  сегменты удаляются или сохраняются — по настройке.
- `info.md` — YAML front-matter: `title, date, source, duration, status`.
- В корне `~/Acta/CLAUDE.md` — описание архива как рабочего контекста (для Claude Code пользователя).

## 7. Отказоустойчивость и самодиагностика (ядро v1)

**Потоковая сегментная запись.** Данные каждой дорожки пишутся сегментами по ~10–15 с; сегмент
закрывается (финализируется) и остаётся валидным независимо от дальнейшего. Частый flush на диск.
Так жёсткий краш/рестарт теряет максимум последний незакрытый сегмент.

**Маркер сессии.** `session.json` создаётся при старте (`status=recording`) и обновляется. Чистый
стоп → `status=done` + склейка. Наличие `status=recording` на запуске = запись прервана нештатно.

**Восстановление на старте** (`RecoveryManager`). При запуске приложения просканировать архив; для
каждой папки с `status=recording`: склеить уцелевшие валидные сегменты в `system/mic/combined.wav`,
битый последний сегмент отбросить без падения, выставить `status=recovered`, уведомить.

**Самодиагностика старта** (`SelfCheck`). После старта в первые ~2 с убедиться, что данные реально
идут (растёт размер текущего сегмента / приходят буферы). Если нет — определить причину:
нет TCC-права → запрос/подсказка; `SCStream` не поднялся → рестарт (2–3 попытки); нет аудио-девайса
→ понятная ошибка. Никогда не показывать «recording», если данные не пишутся.

**Watchdog во время записи.** Если поток буферов встал на N секунд — пометить, попытаться
перезапустить стрим, сохранив уже записанные сегменты; при неудаче — ошибка в UI.

## 8. Рецепт сборки без Xcode (`Scripts/bundle.sh`) — см. скилл `swiftpm-macos-app-bundle`
1. `swift build -c release` → `.build/release/Acta`.
2. Собрать `Acta.app/Contents/{MacOS,Resources}` + `Info.plist`
   (`CFBundleIdentifier=dev.personal.acta` — фиксированный ради TCC; `LSUIElement=true`;
   `NSMicrophoneUsageDescription`; `LSMinimumSystemVersion=14.0`).
3. `codesign --force --sign - --identifier dev.personal.acta --entitlements Resources/Acta.entitlements Acta.app`.

## 9. Порядок реализации и критерии приёмки

Идти по задачам `docs/plans/acta.md`; у каждой — проверяемый критерий. Ключевые:
- Task 2: запись 60 с → несколько валидных сегментов (`ffprobe` длительность > 0 у каждого).
- Task 3: `kill -9` во время записи → перезапуск → незавершённая запись авто-финализируется,
  `combined.wav` валиден и содержит записанное до краша.
- Task 4: старт без Screen Recording → сразу внятная ошибка + путь к исправлению, а не «немой» rec.

## 10. Риски и примечания
- **ScreenCaptureKit audio-only** требует content-filter дисплея → минимальный видео-конфиг, игнор `.screen`.
- **TCC + ad-hoc подпись:** держать `CFBundleIdentifier`/`--identifier` постоянными; иначе Screen
  Recording придётся выдавать заново.
- **Формат сегментов:** выбрать контейнер, дающий валидный файл на каждый сегмент (WAV/CAF); при
  сомнении — писать raw PCM посегментно и собирать WAV на финализации/восстановлении.
- **Приватность/этика:** запись созвонов с другими может требовать согласия — зона ответственности пользователя.

## 11. Ссылки
- ScreenCaptureKit / microphone: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone
- Гайд audio+mic: https://creavit.studio/blog/screencapturekit-audio-recording-mac-guide
- MenuBarExtra: https://developer.apple.com/documentation/swiftui/menubarextra
