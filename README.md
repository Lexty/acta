# Acta

A minimal macOS **menu-bar recorder** for online meetings. It captures system audio and the
microphone as two separate tracks and writes them to disk as it goes. That is all it does —
transcription and summarisation are a separate, local step, shipped in this repository as a
companion Claude Code plugin (see below).

Recordings never leave the machine.

## Why two tracks

`system.wav` is everyone else, `mic.wav` is you. Keeping them apart is what makes speaker
separation tractable afterwards: your own track needs no diarization at all, and the other
participants are diarized without your voice muddying the clustering. No mixdown is produced.

## The three properties the recorder is built around

1. **Streaming writes** — audio goes to disk in segments as it arrives; a recording is never held
   in memory.
2. **Fault tolerance** — a crash or a restart does not lose what was already recorded. An
   interrupted recording is found and repaired on the next launch.
3. **Self-diagnosis** — if capture stalls, that is detected rather than displayed as "recording".
   The app never shows a recording indicator while nothing is being written.

## Requirements

- macOS 14 to build; **macOS 15+ to record** (`SCStreamConfiguration.captureMicrophone` is 15+).
  On macOS 14 the app launches and explains that recording is unavailable.
- **Command Line Tools** — there is no Xcode dependency; the build is SwiftPM.
- **ffmpeg** (`brew install ffmpeg`) — every segment concat goes through it.

## Build and run

```sh
bash Scripts/bundle.sh      # SwiftPM build → Acta.app, code-signed
open Acta.app
```

`bundle.sh` runs `Scripts/setup-signing.sh` on first use. That step is idempotent and
non-interactive: it generates a local self-signed identity so the app's designated requirement
stays stable across rebuilds, which is what lets a granted TCC permission survive a rebuild.
Ad-hoc signing would pin the requirement to the code hash and make you re-grant every build.

Other entry points:

```sh
swift build -c release      # compile only
bash Scripts/test.sh        # the Swift suite (needs ffmpeg)
bash Scripts/lint.sh        # SwiftLint
make test-skills            # the companion plugins' Python suite
```

### Permissions

Two TCC grants are needed and can only be given by hand, in System Settings: **Screen Recording**
(this is how system audio is captured) and **Microphone**.

## Where recordings go

`~/Acta/YYYY-MM-DD_HHMM__<slug>/`, one folder per meeting:

| file | what it is |
|---|---|
| `system.wav` | the other participants |
| `mic.wav` | your microphone |
| `info.md` | front-matter: title, UTC date, source (Slack / Teams / …), duration, status |
| `session.json` | segment bookkeeping and the recovery marker |

The layout is deliberately flat — folder names sort chronologically, and "the newest folder in
`~/Acta`" is a meaningful thing to ask for.

## Companion plugin: turning a recording into notes

This repository is also a Claude Code plugin marketplace, so the processing side installs from the
same place as the app:

```
/plugin marketplace add Lexty/acta
/plugin install acta-notes@acta
```

**acta-notes** takes a folder in `~/Acta` and produces a verbatim transcript, a speaker-named
transcript, and a summary — transcription with Parakeet and diarization with VBx, both running
locally through `fluidaudiocli`. It also maintains the archive: an index of every meeting, and a
retention pass that compresses the audio of meetings that are already written up (48 kHz stereo PCM
is ~1.7 GB per hour; Opus at 32 kbps per mono track is ~29 MB).

Audio and speech recognition stay on the machine. Summarisation is done by Claude, so the
transcript *text* does leave — see `tools/acta-notes/plugin/skills/acta-notes/SKILL.md`, which
states this plainly, and `tools/acta-notes/README.md` for setup.

The plugin needs `ffmpeg`, and builds `fluidaudiocli` on first use via its own `bootstrap.sh`.
Run its `doctor.py` if anything looks wrong; it reports every dependency and model it expects.

## Repository layout

```
Sources/ActaControlProtocol/  the wire protocol, Foundation-only, no dependencies
Sources/ActaKit/              pure logic, no I/O — where testable decisions live
Sources/ActaRuntime/          the recording pipeline, FS and process I/O
Sources/Acta/                 the executable: @main and the SwiftUI menu bar
Sources/ActaTestRunner/       where tests are actually written and run
tools/acta-notes/             the companion plugin (installed, not built)
.claude/skills/               skills for developing Acta — not shipped to users
```

`SPEC.md` holds the decisions and acceptance criteria; `CLAUDE.md` holds the working rules for
anyone — human or agent — changing this code.

## Privacy

Recordings are local files and are never uploaded by this app. It is not sandboxed (personal use)
and its entitlements are minimal.

## Licence

The code in this repository is MIT — see [`LICENSE`](LICENSE).

⚠️ **That covers this repository and nothing else.** The companion plugin drives software and models
it does not ship, and their terms are their own:

- `fluidaudiocli` / FluidAudio is Apache-2.0.
- The converted Parakeet model card **contradicts itself** — CC BY in its front matter, Apache in its
  footer. It is not resolved here, and this licence does not reach it. If you intend to use the
  transcription path for anything beyond personal use, settle that with the model's publisher first.
- The plugin also describes calls to an authenticated Slack CLI that this repository does not
  contain.
