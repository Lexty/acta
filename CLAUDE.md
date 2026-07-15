# CLAUDE.md — Acta

A minimal macOS **menu-bar** app that **only records** online meetings (Slack/Teams/Meet and any
other audio source): system audio + microphone. Transcription and summarisation are **out of
scope** (done separately, locally, via `mlx_whisper`). Full specification — **`SPEC.md`**,
plan — **`docs/plans/acta.md`**.

## Language convention (applies to everything)

**English only** across the whole project — no exceptions:

- **UI strings** shown to the user (menu bar, buttons, statuses, errors, notifications).
- **Code**: identifiers, comments, log messages, error text, generated files (e.g. `~/Acta/CLAUDE.md`).
- **Docs**: `SPEC.md`, `docs/plans/*.md`, `CLAUDE.md`, `.claude/skills/**`, shell scripts, configs.
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

## Conventions and rules
- Environment: **Command Line Tools only**, build via **SwiftPM** (never assume Xcode/xcodebuild).
- **No external dependencies** (no transcription → no WhisperKit).
- The app is **not sandboxed** (personal use); entitlements are minimal.
- Privacy: recordings stay **local** and are never uploaded.
- **Crash safety beats speed:** write in segments, flush often, every segment must be a valid file.
  An unfinalised `AVAssetWriter` file is corrupt after a crash — hence segmentation (see the skill).
- **Never show "recording" when data is not actually being written** — self-diagnosis comes first.
- **If stuck on a SwiftUI/ScreenCaptureKit problem after several attempts — check the official docs
  (links in the skills) or ask Codex for a second opinion.**
- Tests: cover **pure logic** (slug/front-matter, `ffmpeg` arguments, segment-selection logic for
  recovery, the "data is not flowing" detector). Audio/UI runtime is tested manually.

## Not verified automatically (needs a human)
- Granting TCC permissions (Screen Recording, Microphone) — only via System Settings.
- Real audio capture — by running the app.
- The crash scenario (`kill -9`) and auto-recovery on the next launch.
- Validation Commands only check compilation/build/lint/unit logic.
