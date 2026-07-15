# CLAUDE.md — Acta

A minimal macOS **menu-bar** app that **only records** online meetings (Slack/Teams/Meet and any
other audio source): system audio + microphone. Transcription and summarisation are **out of
scope** (done separately, locally, via `mlx_whisper`). Full specification — **`SPEC.md`**,
plan — **`docs/plans/acta.md`**.

## Language convention (applies to everything)

**English only** across the whole project — no exceptions:

- **UI strings** shown to the user (menu bar, buttons, statuses, errors, notifications) — including
  `NSMicrophoneUsageDescription` in `Resources/Info.plist`, which macOS renders verbatim in the TCC
  dialog and which is the first string a new user ever sees.
- **Code**: identifiers, comments, log messages, error text, generated files (e.g. `~/Acta/CLAUDE.md`).
- **Docs**: `SPEC.md`, `docs/plans/*.md`, `CLAUDE.md`, `.claude/skills/**`, shell scripts, configs
  (`Resources/Info.plist`, `Resources/Acta.entitlements`, `.swiftlint.yml`, `.claude/hooks/**`).
  Check with `grep -rP '[\x{0400}-\x{04FF}]' --exclude-dir=.git --exclude-dir=.build .` — a grep
  scoped to `Sources/` alone once let a Russian TCC prompt ship.
- **Git**: commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):
  `type(scope): subject` — `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `perf`.
  Subject in imperative mood, lowercase, no trailing period. Body explains *why*, not just *what*.

The conversation with the user may be in Russian; the repository must not be.

## Three mandatory recording properties
1. **Streaming writes to disk** (incremental, segmented) — never buffer a whole recording in memory.
2. **Fault tolerance** — a restart/crash must not lose recorded audio; an interrupted recording is
   recovered automatically on the next launch.
3. **Self-diagnosis** — if recording does not start or stalls, the failure is detected and healed.

## Read before working
- `SPEC.md` — decisions, API coordinates, crash-safety approach, acceptance criteria.
- Skills in `.claude/skills/`: `screencapturekit-audio`, `crash-safe-recording`,
  `swiftpm-macos-app-bundle`. **Rely on them and on the official docs — do not invent APIs.**

## Commands
- Build: `bash Scripts/bundle.sh` (SwiftPM → `.app` + ad-hoc codesign; there is NO full Xcode)
- Compile: `swift build -c release`
- Tests: `bash Scripts/test.sh` (real run via `ActaTestRunner`; exits non-zero on the first failure).
  ⚠️ Under CLT-only, `swift test` ONLY COMPILES the bundle (no `xctest` host utility) — a failing
  test still exits 0, so it is useless as a gate.
- Lint: `bash Scripts/lint.sh` (SwiftLint wrapper; sets `DYLD_FRAMEWORK_PATH` for CLT-only —
  **raw `swiftlint` crashes without Xcode**; config in `.swiftlint.yml`)
- Run: `open Acta.app` (or `bash Scripts/run.sh`)
- Logs: `/usr/bin/log show --info --debug --predicate 'subsystem == "dev.personal.acta"'`
  (add `--last 30m` to narrow it down; the dev build logs under `dev.personal.acta-dev`, so
  `subsystem BEGINSWITH "dev.personal.acta"` catches both flavors).
  ⚠️ The **absolute path is mandatory**: in zsh `log` is a *builtin*, so a bare `log show` silently
  returns nothing — that cost an hour and produced a false "the app has no logs" conclusion.
  `.info`/`.debug` are not persisted by `os_log`, hence the flags; lifecycle events are `.notice`.

## Project structure
- `Sources/ActaKit/` — **pure logic, no I/O**: `Recovery`, `WAV`, `FFmpeg` (argument builders),
  `MeetingArchive`, `RecordingSettings`, `Diagnostics`, `SegmentLayout`, `SegmentProgress`,
  `SessionManifest`. Anything worth testing goes here. Two deliberate exceptions, both **predating
  `ActaRuntime`**, when a test could reach nothing else: `SegmentRepair` touches the FS, but it is the
  code that rescues crashed audio; `DisplayWakeLock` touches `ProcessInfo`, and "was the assertion
  really taken, and really released" is answerable only by asking the OS (`pmset -g assertions`).
  That rationale has expired — since `ActaRuntime` exists, new I/O-touching code that needs a test
  belongs there, not here. Do not cite these two as precedent for adding I/O to `ActaKit`.
- `Sources/ActaRuntime/` — the recording pipeline: `RecordingController`, `RecordingSession`,
  `AudioRecorder`, `SegmentWriter`, `SegmentAssembler`, `RecoveryManager`, `SelfCheck`,
  `MeetingStore` — `SCStream`, FS and process I/O. Kept thin; decisions are delegated to ActaKit.
  It is a **library**, not part of the executable, because **SwiftPM cannot import an executable
  target**: while this code lived in `Sources/Acta`, nothing above pure logic could be reached from a
  test at all. A library target may import AppKit/SwiftUI, so the AppKit-touching types live here too.
- `Sources/Acta/` — the executable and nothing else: `ActaApp.swift` (`@main`, the SwiftUI menu bar
  and its views). New non-UI code belongs in `ActaRuntime`, not here.
- `Sources/ActaTestRunner/` — **where tests are actually written** (swift-testing `@Test`, run via
  `bash Scripts/test.sh`).
- `Tests/ActaTests/` — **a stub only**, so `swift test` compiles. Never add real tests here: under
  CLT-only they do not run and cannot fail.

The rule: a new behaviour worth testing gets its decision in ActaKit as a pure function, its I/O in
ActaRuntime, and its test in ActaTestRunner.

## Conventions and rules
- Environment: **Command Line Tools only**, build via **SwiftPM** (never assume Xcode/xcodebuild).
- **No external SwiftPM dependencies** (no transcription → no WhisperKit). But `ffmpeg` is a
  **required runtime tool** (`brew install ffmpeg`): every concat/mix goes through it.
  `SegmentAssembler.locateFFmpeg()` searches `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, then
  `PATH`. Without it nothing assembles — the segments survive and the marker stays `recording`, so
  recovery retries on the next launch.
- **Deployment target is macOS 14, but recording requires macOS 15+** (`SCStreamConfiguration.captureMicrophone`
  is 15+). Everything below `MenuContent` is `@available(macOS 15.0, *)`; macOS 14 gets
  `UnsupportedContent`. New code touching capture needs the same annotation.
- The app is **not sandboxed** (personal use); entitlements are minimal.
- Privacy: recordings stay **local** and are never uploaded.
- **Crash safety beats speed:** write in segments, flush often, every segment must be a valid file.
  An unfinalised `AVAssetWriter` file is corrupt after a crash — hence segmentation (see the skill).
- **Never show "recording" when data is not actually being written** — self-diagnosis comes first.
- **If stuck on a SwiftUI/ScreenCaptureKit problem after several attempts — check the official docs
  (links in the skills) or ask Codex for a second opinion.**
- Tests: cover **pure logic** (slug/front-matter, `ffmpeg` arguments, segment-selection logic for
  recovery, the "data is not flowing" detector). Live audio capture and UI are still tested manually,
  but "only `ActaKit` is reachable" is no longer true: since Task 11 the runner imports `ActaRuntime`
  and constructs `RecordingController`/`RecordingSession`/`AudioRecorder`/`RecoveryManager` for real
  (construction only — nothing starts capture; the fakes and seams are backlog work).
- A test may shell out to a system tool (`/usr/bin/pmset`) when only the OS can answer the question.
  Two rules learned the hard way: **scope the query to the runner's own pid** — `pmset -g assertions`
  is machine-wide, so a real recording would otherwise fail the suite — and mark such a suite
  `@Suite(.serialized)`, since the state is process-global and swift-testing parallelizes by default.
  Check what such a test can actually observe: a `beginActivity` token ends its activity when it
  deallocates, so `pmset` cannot distinguish a proper release from a dropped token — that half needs
  an injected seam that counts calls.

## Not verified automatically (needs a human)
- Granting TCC permissions (Screen Recording, Microphone) — only via System Settings.
- Real audio capture — by running the app.
- The crash scenario (`kill -9`) and auto-recovery on the next launch.
- Validation Commands only check compilation/build/lint/unit logic.
