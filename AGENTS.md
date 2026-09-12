# Working on Acta

Canonical for every contributor, human or agent. `CLAUDE.md` points here and adds only Claude Code
specifics; Codex, and anything else, reads this file. Read it before the first edit — several rules
below exist because breaking them already cost hours, and each one says which.

A minimal macOS **menu-bar** app that **only records** online meetings (Slack/Teams/Meet and any
other audio source): system audio + microphone. Transcription and summarisation are **out of
scope** (done separately, locally, via `mlx_whisper`). Full specification — **`SPEC.md`**,
plan — **`docs/plans/acta.md`**.

## Language convention (applies to everything)

**English only** across the whole project — no exceptions:

- **UI strings** shown to the user (menu bar, buttons, statuses, errors, notifications) — including
  `NSMicrophoneUsageDescription` in `Resources/Info.plist`, which macOS renders verbatim in the TCC
  dialog and which is the first string a new user ever sees.
- **Code**: identifiers, comments, log messages, error text, generated files (e.g. `~/Acta/CLAUDE.md`
  — the doc written **into the user's archive** for their own Claude Code, unrelated to this
  repository's `CLAUDE.md`).
- **Docs**: `SPEC.md`, `docs/plans/*.md`, `AGENTS.md`, `CLAUDE.md`, `.claude/skills/**`, shell scripts, configs
  (`Resources/Info.plist`, `Resources/Acta.entitlements`, `.swiftlint.yml`, `.claude/hooks/**`).
  Check with `grep -rP '[\x{0400}-\x{04FF}]' --exclude-dir=.git --exclude-dir=.build .` — a grep
  scoped to `Sources/` alone once let a Russian TCC prompt ship.
- **Git**: commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):
  `type(scope): subject` — `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `perf`.
  Subject in imperative mood, lowercase, no trailing period. Body explains *why*, not just *what*.

The conversation with the user may be in Russian; the repository must not be.

## Plan files: one file per ralphex run, never reused

**A plan file is a container for a single run, not a living document.** Name every new plan
`docs/plans/YYYY-MM-DD-<slug>.md` (e.g. `2026-07-16-capture-seam.md`) and never re-scope an existing
one for a new run.

**Why it matters — reusing a name destroys the run's history.** ralphex derives its progress log from
the plan's basename (`acta.md` → `.ralphex/progress/progress-acta.txt`), and archives the finished
plan to `docs/plans/completed/<same-basename>.md`. Point a second run at the same plan name and both
are overwritten: the log is gitignored, so **that trace is gone for good** — it already cost us the
whole reasoning trail of the overnight run that removed the mix. The archive survives only because
git happens to have it.

Consequences to keep in mind:
- The plan currently being executed **must not be renamed mid-run** — the running process holds that
  path. Fix the name when mounting the *next* plan, not during a run.
- Work parked out of a plan goes to `docs/backlog/`, which is where scope lives between runs. The
  plan file is written once, executed once, archived, and left alone.

## Branches: `dev` is where work lands, `main` is what has been accepted

**Every change goes to `dev` first.** The `dev` flavor (`bash Scripts/bundle.sh dev` — and note that
`bundle.sh` with no argument builds `dev`) is built from it, the user runs that build by hand, and only
when it has been seen to work does `dev` merge into `main`. `main` is therefore not "the latest work";
it is the last state a human accepted. Do not commit to `main`.

⚠️ **This was written down on 2026-09-11, after it had already cost a divergence.** The rule existed in
the user's head and nowhere else, so 57 commits of microphone work went straight onto `main` while the
socket transport and the app icons sat on `socket-transport`, tagged `v0.3.0`, branched from the same
commit and never merged. Neither line contained the other's feature; a fresh clone of `main` built an
app with no icon and no control socket, and `git describe` on that line could not even see `v0.3.0`.
The merge that reconciled them found two textual conflicts and **four** things that compiled and passed
every test while being wrong — which is the real lesson here, not the bookkeeping.

**The version number is bumped on `dev`; the tag is cut on `main`.** A version is a file change like any
other, so it goes through `dev` — putting it straight on `main` is the thing the rule above forbids. A
**tag** is a statement that a state was accepted, so it belongs on the merge commit in `main`, after the
human acceptance run. Order: bump on `dev` → acceptance → merge to `main` → tag the merge. `git describe`
then reads as "the last accepted release, plus N" on both branches, which is the only reading that is
useful.

⚠️ **Both halves of that were being done wrong, and the symptoms looked unrelated.** `v0.3.0` was cut on
`socket-transport`, a branch that never reached `main`, so `git describe` from `main` could not see it at
all and reported `v0.2.1-99`. Meanwhile `CFBundleShortVersionString` sat at **`0.1.0` from the package
skeleton through four tags** — nobody noticed, because nothing in `Sources/` reads it: the version the
app actually shows comes from `ActaBuildRevision`, which `bundle.sh` injects from `git describe` at
bundle time. So the plist version is what **Finder and the Get Info panel** report, and it had been lying
for two months. A number that no code reads is a number no test can catch; it is checked by remembering
to bump it here.

**What a merge of two long-lived lines owes, beyond a green gate.** The 696 tests that passed the
moment the merge compiled proved nothing about the merge: neither branch had a test for the other's
feature, so the suite was green *because* the interaction was untested. Every finding came from reading
the seams instead. Ask, in this order:
- **Which caller-supplied values did the other branch add?** (Here: a socket made `microphone_priority`
  reachable by a stranger.)
- **Which of my synchronous assumptions did the other branch make asynchronous — or give a second
  client?** (Here: `applySettings` returns before it applies, which only a second client could observe.)
- **Which invariant did the other branch state in a comment that my change quietly falsified?**
  (Here: "every peer ships in the same binary", written before a Unix socket existed.)
- **Which document did the other branch write against code I have since moved or rebuilt?**
  (Here: `docs/ui-vocabulary.md`, read off a file that no longer lives at that path.)

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
- Build: `bash Scripts/bundle.sh` (SwiftPM → `.app` + codesign; there is NO full Xcode). Signs with a
  local self-signed identity so the **designated requirement is stable across rebuilds** and a TCC
  grant survives a rebuild — ad-hoc pins the requirement to the cdhash, which changes every build.
  `bundle.sh` runs `Scripts/setup-signing.sh` automatically on first use (idempotent, non-interactive,
  no GUI or login-keychain password; the private key is generated locally and never committed).
  ⚠️ Switching an already-granted app from the old ad-hoc signature to the certificate changes its
  requirement **once**, so both flavors must be granted one final time after their first
  certificate-signed build; from then on rebuilds keep the grant.
- Compile: `swift build -c release`
- Tests: `bash Scripts/test.sh` (real run via `ActaTestRunner`; exits non-zero on the first failure).
  **Needs `ffmpeg`** — `SegmentAssemblerTests` shells out to it for real; without it the assembly
  tests fail rather than skip, which is deliberate (a passing suite must not mean "assembly untested").
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
- `Sources/ActaControlProtocol/` — **the wire protocol and nothing else**: `Envelope` (`WireRequest`/
  `WireResponse`/`WireEvent`/`ProtocolVersion`/`ControlProtocolCodec`), `Command`, `CommandResult`,
  `WireError`, `WireValues` (`WireControlState`/`WireSettings`/`RecordingSummary`), `WireMessageCode`,
  `RecordingID`, `JSONLinesFramer`. **It declares no dependencies in `Package.swift`, deliberately** —
  Foundation alone, no `ActaKit`, no `ActaRuntime`, no AppKit. That is what lets the app and the future
  `actactl` share one definition, and what stops a runtime rename from silently renaming a wire key.
  **It is not `ActaKit`, even though it is pure**: `ActaKit`'s rule is "no I/O" and it may freely name
  runtime-adjacent types; the rule here is **dependency-free and frozen**, because a separate binary
  decodes this schema. Do not move wire types into `ActaKit` because "they're pure", and do not reach for
  a runtime type from here — the package graph will refuse, which is the point.
  ⚠️ **The forward-compat rules in `ProtocolVersion` are narrower than they read.** Only the command
  `type` tag decodes tolerantly (to `.unsupportedCommand`); every response-direction enum throws on an
  unknown discriminator, and the **exact-version match** is what makes that safe. Adding a case to
  `RecordingSummary.Status` or `Operation.Kind` within v1 would make the whole enclosing response
  undecodable to an older client — that is a version bump, not an additive change.
- `Sources/ActaKit/` — **pure logic, no I/O**: `Recovery`, `WAV`, `FFmpeg` (argument builders),
  `MeetingArchive`, `RecordingSettings`, `Diagnostics`, `SegmentLayout`, `SegmentProgress`,
  `SessionManifest`, `SelfCheckTuning`, `ControllerMessage`, `ControlStringPolicy` (the shared
  length/character bound the socket dispatcher enforces on every caller-supplied command-payload string).
  Anything worth testing goes here —
  including **constants a test must assert exactly against** (`SelfCheckTuning.maxRestartAttempts`):
  `SelfCheck` is internal to `ActaRuntime`, and a threshold written once in the runtime and again in
  the test asserts only that the test agrees with itself. The same rule is what puts
  **`ControllerMessage`** here: it is the one home of every string `RecordingController` writes into
  its untyped `errorMessage`, read by the controller that emits it *and* by `ControlState`'s reverse
  lookup that classifies it. That cost was paid once already — while the mapping held hand-typed
  copies, rewording a controller message left the build and all 296 tests green while
  `ControlFailure.category` silently degraded to `.unknown` in production. One deliberate exception, **predating
  `ActaRuntime`**, from when a test could reach nothing else: `SegmentRepair` touches the FS, but it
  is the code that rescues crashed audio. That rationale has expired — since `ActaRuntime` exists,
  I/O-touching code that needs a test belongs there, not here. Do not cite `SegmentRepair` as
  precedent for adding I/O to `ActaKit`.
- `Sources/ActaRuntime/` — the recording pipeline: `RecordingController`, `RecordingSession`,
  `AudioRecorder`, `SegmentWriter`, `SegmentAssembler`, `RecoveryManager`, `SelfCheck`,
  `MeetingStore`, `DisplayWakeLock`, the typed boundary — `ControlAPI`/`ControlState`/
  `ControlState+Mapping` — the transport boundary above it — `WireProjection` (the pure
  `ControlState` → `WireControlState` projection, plus `ControlRecordingLookup`), `ControlServing` (the
  narrow surface a transport may reach for; `ControlAPI` conforms) and `ControlDispatcher` (`@MainActor`,
  conforms to `ControlRequestHandling`) — the Unix-socket transport over it —
  `ControlEndpoint`/`BoundSocket`/`ControlSocketAddress` (the secure bind),
  `ControlSocketServer`/`ControlConnection`/`ControlConnectionIO` (non-blocking serving) and
  `ControlSocketHost` (the app-side lifecycle owner) — plus the injected seams — `CaptureSource`/`SCKCaptureSource`,
  `PermissionChecking`/`SystemPermissions`, `SelfCheckClock`/`SystemClock`, `RecordingDependencies`
  — FS, `powerd` and process I/O. Kept thin; decisions are delegated to ActaKit.
  **A pure function may live here when its *types* cannot leave.** `ControllerSnapshot` and
  `ControlState(from:)` have no I/O, no clock and no controller in reach — `ControlStateTests` drives
  them with literals alone — but they name `RecordingController.Phase` and `MeetingStore.Recording`
  and inherit the phase's macOS 15 availability, so `ActaKit` cannot hold them. The rule that binds is
  "no I/O", not "in `ActaKit`": purity is what makes the mapping exhaustively testable, and the target
  it sits in does not change that. Do not cite this to move I/O-touching code into `ActaKit`.
  **`WireProjection` is that same rule's second instance, not a new exception**: it is pure
  (`WireProjectionTests` drives it from literals), but it names `ControlState`/`MeetingStore.Recording`/
  `RecordingSettings`, so `ActaControlProtocol` cannot hold it. ⚠️ It is a **projection — never a
  `Codable` conformance on the runtime types**: conforming `ControlState` to `Codable` would let a
  field rename in the runtime silently rename a wire key.
  **A transport depends on `ControlRequestHandling`, never on `ControlDispatcher` or `ControlAPI.shared`**
  — the seam exists so descriptor code (`flock`, `sockaddr_un`, `SO_NOSIGPIPE`) is testable against a
  handler returning canned results and can reach nothing in the recorder. It **inherits** the
  `ControlAPI.shared` invariant below: the dispatcher production constructs is the one over
  `ControlAPI.shared`, and no test may touch it.
  **`SCStream` no longer permeates the target**: it lives *only* in `SCKCaptureSource`, behind the
  `CaptureSource` protocol. `AudioRecorder` sees `(Track, CMSampleBuffer)` and nothing more.
  It is a **library**, not part of the executable, because **SwiftPM cannot import an executable
  target**: while this code lived in `Sources/Acta`, nothing above pure logic could be reached from a
  test at all. A library target may import AppKit/SwiftUI, so the AppKit-touching types live here too.
- `Sources/Acta/` — the executable and nothing else: `ActaApp.swift` (`@main`, the SwiftUI menu bar
  and its views). ⚠️ **`ControlViewModel` moved to `ActaRuntime`**, and the reason is worth keeping:
  while it lived here it was unreachable from any test, and "the executable target cannot be imported"
  got recorded as "the adapter cannot be tested". It is not a view — it is the `ControlAPI` adapter
  (`@MainActor` `ObservableObject`, owned by `MenuContent` as a `@StateObject` — `@MainActor`
  `ObservableObject`, owned by `MenuContent` as `@StateObject`; seeds its `state` synchronously from
  `ControlAPI.shared.state` so the first frame is not blank, subscribes to `states()` **and**
  `microphoneStatuses()` from the view's `.task {}`, and keeps optimistic local values reconciled
  against the pending write). Four defects were found in it the day it became importable — a missing
  subscription, a stale continuation, a lost edit intent and a dropped incompleteness — none of which
  manual rendering acceptance would have caught. New non-UI code belongs in `ActaRuntime`, not here,
  and so does anything the views merely *call*.
  ⚠️ **A user-facing string that states a fact is a projection, not view code**, and this rule was paid
  for three times in one review round. A ternary in the menu said the feature was "holding the Mac's
  input" for every enabled state, *suspended* and *refused* included; a summary resolved from
  insufficient inputs told the user their microphones were disconnected when the snapshot had merely
  been incomplete; a sentence teaching the priority list contradicted the picker three lines below it,
  and its own correction was then wrong in a fourth combination. Every fix was the same move — into
  `ControlAPI.MicrophoneStatus` (`captureSummary`, `managementSummary`, `listExplanation`), with tests.
  The view still decides **layout, colour and what to show when**; the moment it decides **what is
  true**, it is in the one layer nothing checks.
  ⚠️ **A hover tooltip is not an explanation here.** In a menu-bar popover it effectively does not
  exist, which is how the "add to my list" control shipped as an unlabelled circle that read as a radio
  button, with its meaning only in `.help`.
- `Sources/ActaTestRunner/` — **where tests are actually written** (swift-testing `@Test`, run via
  `bash Scripts/test.sh`).
- `Tests/ActaTests/` — **a stub only**, so `swift test` compiles. Never add real tests here: under
  CLT-only they do not run and cannot fail.

The rule: a new behaviour worth testing gets its decision in ActaKit as a pure function, its I/O in
ActaRuntime, and its test in ActaTestRunner.

**New seams go into `RecordingDependencies`, never into a default argument.** `.live` is the shipped
wiring written once, as a value a test can assert against; a default argument is the same claim in a
form no test can reach — you cannot ask a function what it *would* have passed. Its members are
factories because a `CaptureSource` is stateful and belongs to exactly one recording.
`RecordingSession` is the **composition root** (it hands the one `PermissionChecking` instance to
both consumers, `AudioRecorder` and `SelfCheck`); it asks no permission questions itself.

**Amendment: the rule above is about *per-recording* seams, and does not reach app-lifetime ones.**
This is a widening of the rule, not a reading of it — the original wording says "new seams" with no
lifetime qualifier, and every seam that existed when it was written had the same lifetime. The
evidence that forced the change: `RecordingDependencies`' members are **factories**, and its own doc
says why — "a source is stateful and belongs to exactly one recording, so `.live` must mint a fresh
one per session". Microphone management is the first seam where that is exactly backwards. It must run
**while nothing is recording** (feature B's promise is that the Mac's default input stays on your list
while Acta is merely running) and **survive a recording ending**; a per-recording factory gives it
neither — it would exist only between `start()` and `stop()`, which is precisely the interval the
feature is *not* about. ⚠️ An earlier draft of this paragraph also claimed a watchdog restart would
produce several enforcers at once. **That was wrong and is removed rather than softened**:
`AudioRecorder.restart()` (`AudioRecorder.swift:187`) stops and restarts the *same* source with the
same writers and the same session — it mints no `RecordingSession` and no `RecordingDependencies`.
The lifetime argument above stands on its own and needs no invented mechanism.
So: an **app-lifetime** seam gets its own owner with its own wiring value.
`MicrophoneWiring.live` is that value and carries the same burden `RecordingDependencies.live` does
(a claim about production a test can call back, which a default argument can never be); the
difference is that `MicrophoneManager` calls each factory **once, in `init`**, and holds the result
for the process. **`MicrophoneManager` is the composition root** for this, exactly as
`RecordingSession` is for permissions: it builds the one `AudioDeviceDirectory` and hands it out —
whole to the reconciler it owns, and as the read-only `AudioDeviceReading` to everyone else.
⚠️ The `AudioDeviceReading` split is **static narrowing, not a capability guarantee, and the
difference matters**: both protocols are public in the same target and the object handed out still
conforms to `AudioDeviceDirectory`, so anything holding the reader can cast it back and construct a
second reconciler. What the split buys is that a recording cannot reach `setDefaultInput` *by
accident* — the type it is handed does not offer it. "A recording never enforces and never constructs
a reconciler" stays a **composition rule**, enforced by review, and this paragraph is where it is
written down. ⚠️ **`shutdown()` does not unregister the raw HAL listeners**, and must not be described as if it
did: `CoreAudioDeviceDirectory` removes its `AudioObjectAddPropertyListenerBlock` registrations only
in `deinit`, and the manager keeps the directory alive — in production, to process exit. What it does
guarantee, awaited, is that nothing in Acta reads or writes through the directory afterwards — which
requires draining the reconciler's in-flight verification, not merely disabling it, since a poll
already running goes on reading. Keeping the raw registrations to process exit is a **deliberate
ownership policy**: the manager owns the directory for the life of the app. ⚠️ An earlier draft
justified it by claiming a final close would amount to resurrecting teardown-on-last-subscriber; that
equated two different operations and is removed. `MicrophoneManager.shared` inherits
the `ControlAPI.shared` prohibition — it reaches the real CoreAudio, so **no test may touch it**; tests
build their own over a fake directory. The scope of this exception is one owner per app-lifetime
concern, injected explicitly at composition; it does **not** loosen the per-recording rule, and a new
seam that belongs to one recording still goes into `RecordingDependencies`.

**One seam is deliberately not in `RecordingDependencies`**, and the rule above does not cover it:
`RecordingController.awaitRecovery()` (`RecordingController+Recovery.swift`) is a **completion** seam,
not an injection point — it returns the verdict of the pass `onLaunch()` already started
(`RecoveryOutcome`: `.nothingToRecover` / `.recovered(count:)` /
`.incomplete(partial:unassembled:retrying:lost:)` / `.scanFailed`).
The disk cannot answer that question: a pass still running and a pass that finished but could not
assemble both leave `session.json` at `recording`, so polling can only bound the ambiguity, never
resolve it — and the crash harness's recoverer has to tell "recovery worked" from "recovery gave up"
to have proved anything. The verdict rides on `recoveryTask`'s own value, which is why that property
is `internal` rather than `private` and why `didRunRecovery` is gone: the task's existence *is* that
fact. Relatedly, `RecoveryManager.Outcome` (`RecoveryManager+Outcome.swift`) has **five** lists, not
three, and the last two exist for one reason: a folder the pass acted on that lands in no list is
reported as an archive with nothing to recover — the opposite answer. `retrying` holds folders left
interrupted for a later launch (a spent repair attempt, or no `ffmpeg`); it is not terminal, the
marker still says `recording`. `lost` holds folders closed because the crash left no salvageable
segment — terminal, and total data loss, which must never come back as success. `isEmpty` counts both,
and either makes the verdict `.incomplete`.

**A sixth signal, `unscannable`, is not a list**, and it closes the same ambiguity one level up: the
scan's *own* failure. An archive root behind a lost permission fails
`contentsOfDirectory`, and returning the empty `Outcome` for that is the pass vouching for every
meeting at the one moment it checked none — `.nothingToRecover`, exit `0`, no banner. It maps to its
own verdict (`.scanFailed`, `Exit.recoveryScanFailed` = 73) and its own sentence, because "I could not
look" is not "there was nothing to find". A root that **does not exist** is deliberately not this: that
is an ordinary first launch, and reporting it would put a banner in front of every new user — the
distinction is existence, not readability. Both readings of a pass go through
`RecoveryReport.Counts`, whose `init` defaults nothing: a field added to `Outcome` and forgotten in
either reading fails to compile instead of going quiet, which is how `retrying` and `lost` once
reached the log while the other three reached the user.

## Conventions and rules
- Environment: **Command Line Tools only**, build via **SwiftPM** (never assume Xcode/xcodebuild).
- **No external SwiftPM dependencies** (no transcription → no WhisperKit). But `ffmpeg` is a
  **required runtime tool** (`brew install ffmpeg`): every concat goes through it.
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
  and constructs `RecordingController`/`RecordingSession`/`AudioRecorder`/`RecoveryManager` for real.
  The I/O below capture is tested for real: `SegmentAssemblerTests` writes fixture PCM WAV segments
  into a temp directory and drives `SegmentAssembler.assemble` end-to-end through the segment plan,
  the header repair, a real `ffmpeg` and the segment deletion. Where a *directory* is the input,
  prefer fixture bytes to a fake.
  **The capture seam has landed, so the pipeline itself is driven in-process too**: a scripted
  `FakeCaptureSource` feeds real `CMSampleBuffer`s through `AudioRecorder` → `SegmentWriter` →
  assembly, with `PermissionChecking` and `SelfCheckClock` injected, so a full recording — the
  startup probe, the watchdog's restart and its give-up — runs with no TCC prompt, no display, no
  audio device and no wall-clock waiting (`RecordingPipelineTests`, `RecordingPipelineFailureTests`).
  Only **real ScreenCaptureKit capture and the UI** are still manual.
  **Crash recovery is automated too, by a process-based harness** — the one property that cannot be
  tested in-process, because throwing, cancelling and dropping all run cleanup and `SIGKILL` does not.
  `ActaTestRunner` **spawns itself**: `main.swift` branches on `--harness-child` / `--harness-recover`
  *before* the swift-testing entry point (a child must never fall through into the suite — the suite
  spawns children), so the child is the same binary re-invoked and `FakeCaptureSource` needs no
  extraction. The child records through `RecordingController.start()`, publishes readiness by an
  atomic rename once the **production recovery scan** sees a closed and an open segment per track, is
  `SIGKILL`ed at the pid it published, and is recovered by a **fresh process** (`HarnessCrashTests`,
  `HarnessPlumbingTests`, `HarnessProtocol`/`HarnessChild`/`HarnessSupervisor`). Assertions read only
  durable filesystem state — in-memory state died with the child — and go through
  `PositionEncodedAudio`, whose samples encode their own position, so a lost frame is named rather
  than decoded past. Length is **bounded, not exact** (closed segments ≤ recovered ≤ the emitted count
  published at readiness): a crash cannot be scheduled. A permanent negative control runs the same
  harness against a child that drops audio in a *surviving* segment and requires the oracle's
  **specific** verdict — an oracle that cannot fail rubber-stamps everything. ⚠️ This is
  **approximate** E2E: it proves segmentation → `SIGKILL` → recovery → repair → assembly, **not** that
  ScreenCaptureKit captures anything or that TCC prompts appear.
  **The controller's lifecycle above that pipeline is frozen as a characterization contract**:
  `RecordingController` is driven through the operations the UI calls (`start`, `stop`, `stopAndWait`,
  `onLaunch`, `onAppear`) over a temp archive with the same seams injected
  (`RecordingControllerLifecycleTests`, `RecordingControllerGuardTests`, fixtures in
  `ControllerTestSupport`). It records the lifecycle **as it is**, not as it should be: the capture is
  already live while `phase == .idle` during the probe, `phase` stays `.error` while the assembly is
  still writing, `start()` clears both banners, `.error` is not a latch. ⚠️ Those assertions **are the
  contract, not bugs to fix** — they exist to catch the next refactor, and the first one has landed:
  the **`ControlAPI` façade** (`ControlAPI`/`ControlState`) wraps this controller *unchanged*, which is
  what makes those frozen assertions the thing the façade is checked against. The **UI migration has
  landed**: `ActaApp.swift`/`MenuContent` now read `ControlState` and issue commands through
  `ControlAPI.shared` (via the UI-owned `ControlViewModel` adapter), so the SwiftUI menu is the
  façade's first production client. The **wire protocol and dispatcher have landed** too
  (`ActaControlProtocol`, `ControlDispatcher` over `ControlServing`, with `ControlDispatcherTestSupport`'s
  `FakeControlServing` injected by every dispatcher test) — the boundary's second client, in-process and
  socket-free. The **POSIX socket transport has landed** too: the app hosts **exactly one** Unix control
  socket at `~/Library/Application Support/<bundle-id>/control.sock` (`0600`, in a verified `0700` current-UID
  parent), so a future `actactl` can reach the running app. **The trust boundary is the filesystem and
  only that** — `AF_UNIX`/`SOCK_STREAM` only (never TCP, Bonjour or a network fallback), **no token** (a
  `0600` socket in a `0700` user-private directory is the whole boundary; any same-UID process can already
  act as the user), and no launch-on-demand (an absent socket means "not running"). The pieces:
  `ControlEndpoint`/`BoundSocket`/`ControlSocketAddress` (the secure bind — `flock`ed init, exact
  stale-socket recovery that never severs a live server nor removes a non-socket, device/inode-checked
  teardown), `ControlSocketServer`/`ControlConnection`/`ControlConnectionIO` (non-blocking `DispatchSource`
  I/O with single-owner descriptors, `SO_NOSIGPIPE`, deadlines, a ~16 connection cap, `watch` coalescing
  to the newest state), and `ControlSocketHost` (the `ActaRuntime` lifecycle owner — `AppDelegate` is thin
  wiring — with a **synchronous, bounded `teardown()`** because `applicationWillTerminate` is not an async
  suspension point). ⚠️ **A socket dispatcher is `.socket`-confined, the in-process UI one `.trusted`**: a
  socket client **cannot relocate the archive, rewrite the microphone priority list, or switch
  management of the Mac's default input** (`settingsSet` ignores the wire `archive_path`,
  `microphone_priority` and `manages_system_default_input`, substituting the current authoritative
  values) and every caller-supplied command-payload string is
  length-bounded and rejected for control characters (`ControlStringPolicy`) — the envelope's echo-only
  correlation id and an unknown-tag discriminator are round-tripped verbatim and bounded only by the 64 KiB
  frame limit, since neither reaches recorder state; a human relocating their own archive through the
  menu is fine. What stays parked in `docs/backlog/` is the `actactl` CLI (Plan 3).
  ⚠️ **The two microphone substitutions were added when the socket and the microphone feature were merged
  (2026-09-11), and the rule they follow is not the archive path's.** A path is a filesystem reach; those
  two fields decide whether Acta writes the **Mac's system-wide default input** and which device it
  writes — state every other application on the machine reads, changed by an app the user never opened.
  **Both, and unconditionally**: substituting only the enable flag would still let a client redirect
  enforcement that is already on, and substituting the list only while enforcement is on would let a
  client plant a list that takes effect the moment the user enables it. `captureMicrophoneChoice` is
  deliberately **not** substituted — it selects the microphone *Acta's own recording* uses and writes
  nothing outside the app, which is what a control client is for. ⚠️ It is an **authority** boundary, not
  a security one: the socket is same-UID and such a process can do more directly. What it buys is that a
  client round-tripping `settings_get` → edit → `settings_set` cannot silently carry the machine's audio
  configuration along with the field it meant to change.
  ⚠️ **`ok` on a settings write means *applied*, not *accepted*, and that needed a barrier
  (`ControlServing.settleMicrophoneSettings()`).** `saveSettings()` hands the microphone half of the
  settings to `MicrophoneManager`, which chains the application and returns; the capture policy is
  published several suspension points later. In-process that never mattered — the same person clicks Save
  and then Start, seconds apart. A socket client receives `ok` and can send `start` in the next frame, and
  a recording resolving under the policy it just replaced is the one failure this feature exists to
  prevent. The dispatcher awaits the barrier before acknowledging `settingsSave` **and before admitting a
  `start`** (before the `canStart` guard, never between the guard and `start(title:)`, which must stay one
  turn). The same rule holds for `.trusted`: the menu cannot lose the race in practice, but a weaker
  guarantee for the in-process client is one nobody could state a reason for. **`AppDelegate` defers
  hosting the socket** behind the same barrier for the same reason — ordering the calls at launch is not
  enough, because `applySettings` returns before it has applied — and carries an `isTerminating` flag so a
  bind that completes after quit began does not reopen the endpoint the quit-time teardown just closed.
  ⚠️ That last part is in the **executable** target and no test reaches it; it is human-acceptance work.
  ⚠️ **An `await` added ahead of a guard moves the command behind the entry gate, and that is a defect
  shape worth recognising.** `handle` checks `Task.isCancelled` once, on entry — sufficient while nothing
  suspended before `start(title:)`. Joining an unstructured task does **not** throw when the *waiter* is
  cancelled, so a start parked in the barrier sails through the quit that tore the socket down and
  cancelled its connection, and begins recording inside the finalisation window. Cancellation is
  re-checked immediately after the barrier. Any future `await` inserted before a command acts must do the
  same; the gate is a gate at the point it is written, not for the whole function.
  ⚠️ **The barrier's fake-driven tests would pass if `ControlAPI.settleMicrophoneSettings()` became a
  no-op**, because a fake `ControlServing` proves only that the dispatcher waits on what it is handed.
  `ControlDispatcherMicrophoneIntegrationTests` closes that: a dispatcher over a **real** `ControlAPI`
  over a real `MicrophoneManager` on a fake directory and a `GatedClock`, with the application parked
  deterministically. Deleting the forwarding fails it and nothing else — which is what makes it worth
  having. Note what makes the parking work: the fake's default input must be a device **other** than the
  head of the priority list, or enforcement has no write to make and the application finishes before it
  can be held.
  Assert only through the
  public surface: `isStopping` is
  `@Published private` and the derived flags (`isBusy`/`isSaving`/`isRecording`/`hasWorkInFlight`) are
  computed properties with no publisher, so `$phase` is subscribed while the flags are **sampled**
  around `objectWillChange` — synchronously (which settles the *previous* change, and is what makes a
  transient window deterministic) and again deferred by one turn (for the last change, which no later
  fire reports). Never construct `RecordingController.shared` in a test: it reaches for the real
  `~/Acta`, real TCC and real time. Three behaviours are real but cannot be induced through today's
  public surface and are deliberately uncharacterized rather than faked (listed at the top of
  `RecordingControllerLifecycleTests`): a controller-level assembly failure, `openArchive()` failing,
  and `suggestedTitle`. Each needs a seam a plan must add first.
  The fake is only worth something if it behaves like the real source, so the `CaptureSource`
  contract is itself asserted (`CaptureSourceContractTests`) — per-track serial queues, a delivery
  gate, a draining `stop()`. A guarantee the fake makes and `SCKCaptureSource` does not is a bug in
  the fake. Where the real source cannot answer (it needs a live `SCStream`), **skip visibly** with
  `.enabled(if:)` — a bare `return` reports as a pass and hides that nothing ran.
  **A test that needs settings uses `VolatileDefaults.make()`, never `UserDefaults(suiteName:)`.**
  `.standard` would point the developer's own app at a temp archive, but a *named suite* is a
  persistent domain: it mints `~/Library/Preferences/<name>.plist`, and `cfprefsd` — not the process —
  decides when that file is written. So `removePersistentDomain` at teardown races the daemon and
  loses, and a unique suite per run leaks a file per run: that is not hypothetical, it left ~2 700 of
  them in the home directory before `VolatileDefaults` replaced it (and `SIGKILL`, which the crash
  harness depends on, runs no teardown at all). Nothing needs the persistence — settings are read back
  by the process that wrote them, and the harness's two processes agree on the archive through
  `--root`.
- **`ControlAPI.shared` wraps `RecordingController.shared` — never a second controller.** The menu now
  observes `ControlAPI.shared` (which wraps that one controller), so a façade over any *other*
  controller instance would record into the archive with the menu showing nothing: an API-initiated
  recording no one on the machine can see, which the privacy rule forbids. **No test can guard this** — `.shared` reaches for the real `~/Acta`, real TCC and real
  time, so every test injects its own controller and none may touch `.shared`. It is a review-only
  invariant.
- **Four confinements, and only two are tests — the wording used to overstate this.**
  ⚠️ `controlProtocolSourcesImportOnlyFoundation` and `SourceConfinementTests` are real tests and fail
  the suite. The **ScreenCaptureKit and TCC rules are not**: they are held by a human remembering to run
  a `grep`, and calling all of them "grep-enforceable" read as though something checked them. Converting
  those two is deliberately still out of scope; this line exists so the gap is visible rather than
  implied away.
  ⚠️ The reader behind both real guards is shared (`SourceConfinement`) and is **itself tested**
  against fixtures. It has to be: the first version matched `trimmed.hasPrefix("import ")`, so
  `@preconcurrency import AppKit` under `ActaControlProtocol/` would have **passed** it — and that form
  is in use here (`SCKCaptureSource.swift:5`), so the hole was reachable, not theoretical. A guard whose
  reader has a hole is worse than no guard, because it is believed.
- **The fourth: the CoreAudio HAL lives only in `CoreAudioDeviceDirectory.swift`.** Guarded by **symbol
  use**, not by imports — a transitive framework import exposes `AudioObject*` with no `import
  CoreAudio` line at all. Deliberately narrow: it covers the object/property API and its `kAudio*`
  constants and nothing else, because forbidding `CMSampleBuffer` or `AudioBufferList` for belonging to
  an audio framework would make it a rule people route around. Comments are stripped, so a doc comment
  may name these APIs; move the comment rather than contorting the code. Task 9's live probe is outside
  the production targets by design — it must import `AVFoundation` — which is why the guard scans the
  four production targets rather than keeping an exemption list.
- **The identity this whole feature stands on is measured, not documented — and a probe says so.**
  The CoreAudio device UID (`kAudioDevicePropertyDeviceUID`) and `AVCaptureDevice.uniqueID` are the same
  string, which is what lets a UID read from the HAL be handed to
  `SCStreamConfiguration.microphoneCaptureDeviceID`. Apple documents each identity's persistence
  separately and **never states they are one identity**; the equality was measured here, once, on one
  OS. If a future macOS diverges, every line still compiles and either the wrong microphone is recorded
  or capture fails outright. `MicrophoneIdentityProbe` (+ `bash Scripts/probe-microphone-identity.sh`)
  takes **two independent live observations** and compares them.
  ⚠️ **Its correspondence is deliberately not the UID.** Matching the two lists by UID and then
  asserting the UIDs agree is `x == x`; devices are corresponded **by role** (each API asked separately
  which device is the system default input) and **by display name**, with a name that is not unique on
  both sides excluded rather than paired arbitrarily — which is the same fact production encodes by
  keying identity on the UID and never on the name.
  ⚠️ **Three outcomes, and merging any two defeats it**: corresponded with two different identities is a
  **failure**; hardware that is simply absent is a **visible `.enabled(if:)` skip**; a comparison that
  corresponded **nothing** is `inconclusive` and fails, because that is also what a total divergence
  looks like from inside the matcher. It claims to detect divergence **on the devices this machine
  exercises** — not compatibility with a future macOS, and not that ScreenCaptureKit captured the
  intended microphone, which stays in manual acceptance.
  ⚠️ **The probe warms AVFoundation before the suite runs** (`MicrophoneIdentityProbe.warmUp()` in
  `main.swift`), and that is measured, not defensive: the first `AVCaptureDevice.DiscoverySession` in a
  process costs 221 ms of one-time initialization, and paying it *inside* the parallel suite took the
  gate from 7.6 s to 67 s with `SegmentWriter.finish` exhausting its 30-second `pendingWrites` wait.
  `isWarm` fails a test if the call is deleted. See
  `docs/backlog/segment-finalisation-waits-under-parallel-tests.md`.
- **Two CoreAudio traps that cost real time, both of which pass silently.**
  ⚠️ **`kAudioDevicePropertyDeviceCanBeDefaultDevice` must be asked in
  `kAudioObjectPropertyScopeInput`.** Asked in `kAudioObjectPropertyScopeGlobal` it returns
  `kAudioHardwareUnknownPropertyError` for **every** device, so an adapter reports `.unknown` across the
  board — and nothing notices, because `.unknown` is a legitimate answer for any single device. Only
  *universal* `.unknown` identifies it, which is what
  `theEligibilityQueryUsesTheScopeThatActuallyAnswers` asserts. ⚠️ It is also **not** the question "may
  Acta record this" — BlackHole and an aggregate device both answered *yes* to it here while being
  exactly the software endpoints `isPhysical` excludes.
  ⚠️ **A swallowed `OSStatus` becomes a claim about the hardware.** An adapter that catches a failed
  HAL call and returns `[]` reports "this machine has no microphones" with the same value it would use
  for a machine that genuinely has none, and every consumer above then behaves as though it had
  *looked*. Same class as the recovery scan's `unscannable`: "I could not look" is not "there was
  nothing to find". Hence `DeviceEnumeration.failed`, `DefaultInputRead.failed`,
  `ObservationOutcome.failed` and `DeviceEnumeration.devices(_, uninspectable:)` — a driver that will
  not answer is **named**, because a snapshot that omits it silently is indistinguishable from one where
  the device left, and consumers above read a departure as a disconnect.
- **The two a human holds, and the one the package graph holds — keep them green.** ⚠️ The heading
  used to say "three confinements, grep-enforceable", which read as though something checked all of
  them; only the third is checked. ScreenCaptureKit (`import
  ScreenCaptureKit`, `SCStream*`, `SCContentFilter`, `SCShareableContent`) appears only in
  `SCKCaptureSource.swift`; the TCC calls (`CGPreflightScreenCaptureAccess`,
  `CGRequestScreenCaptureAccess`, `AVCaptureDevice`) only in `SystemPermissions.swift`.
  ⚠️ **Both are rules about the production targets, and that scope is now load-bearing**:
  `MicrophoneIdentityProbe` in `ActaTestRunner` imports `AVFoundation` and names `AVCaptureDevice` by
  design — it exists to compare that API against the HAL — so a grep run across the whole repository
  reports it and is right to. Scope the grep (`Sources/ActaKit Sources/ActaRuntime
  Sources/ActaControlProtocol Sources/Acta`) or read the hit before acting on it. That is what
  makes the fakes answer the questions production actually asks instead of bypassing them. Match type
  references, not prose — doc comments legitimately name `SCStream`. Never contort code to satisfy
  the grep; move the comment instead. The third: `Sources/ActaControlProtocol/` imports **Foundation and
  nothing else** (`grep -rn '^import' Sources/ActaControlProtocol/`), and the target lists **no
  dependencies** in `Package.swift`. The package graph enforces the hard half — it cannot see `ActaKit`
  or `ActaRuntime` — and `controlProtocolSourcesImportOnlyFoundation` catches the rest, since an
  `import AppKit` compiles without any package dep at all.
- A test may shell out to a system tool (`/usr/bin/pmset`) when only the OS can answer the question.
  Two rules learned the hard way: **scope the query to the runner's own pid** — `pmset -g assertions`
  is machine-wide, so a real recording would otherwise fail the suite — and mark such a suite
  `@Suite(.serialized)`, since the state is process-global and swift-testing parallelizes by default.
  Check what such a test can actually observe: a `beginActivity` token ends its activity when it
  deallocates, so `pmset` cannot distinguish a proper release from a dropped token — that half needs
  an injected seam that counts calls.

## The reminders

Three prompts, added 2026-09-12: one offers to record when another application takes the microphone, one
offers to stop when a recording has gone quiet, and one offers to stop when the application a
prompt-started recording belongs to has let the microphone go. All three are off-limits to the socket.

**Nothing in this feature acts on its own — with one narrow exception, decided by the user.** A timer may
withdraw a prompt; no timer may answer one. An expired offer to record records nothing; an expired quiet
offer keeps recording. If you are changing this code and a path appears where a timeout starts a
recording, deletes one, or answers the quiet offer, that is the bug, not a feature.

⚠️ **The exception: the owner-release stop offer's countdown may stop a recording** — and only when all of
these hold, each of which has a test and a negative control (`OwnerReleaseOfferTests`, `ReminderPresenterTests`):
- the recording was **started from a start offer** and admitted bound to that offer's application
  (`OwnerBinding`); a menu or socket start is never bound and never offered this;
- that application was **observed released** for the full qualification interval, with no gap and no
  unreadable observation (`MicrophoneOwnershipRule`); the owner returning, or the evidence lapsing,
  withdraws the offer whether its countdown is running or still awaiting acknowledgement;
- the presenter **acknowledged the prompt as on screen** and the countdown then ran its **full duration**,
  watched without a gap (`AcknowledgedCountdown`). A publication is not a presentation, and a lock, a
  display sleep or a wake withdraws the countdown rather than letting it catch up;
- at completion the recording is **still the one the offer named** — by the coordinator's id, the folder
  being written into, and the admitted binding — and its release still stands qualified.

⚠️ **Those tests reach the coordinator's side of the presenter contract, not the panel's.** That
`ReminderPanel.swift` acknowledges only once the window server reports the panel visible, reports a
lock or a display sleep as a lost presentation, and acknowledges nothing while one is still in force — until
its own counterpart (unlock, wake, session active) is observed — is human acceptance — see "Not verified
automatically". The lock pair is registered with `.deliverImmediately`: coalesced while the app is inactive, a
lock flushed after its unlock would hold for the rest of the process.

Keep Recording, a dismissal, a displacement by another prompt, the preference being switched off and quit
all end the countdown without acting. **The panel's own expiry is not a dismissal here**
(`ReminderCoordinator.expire(_:)`): it leaves a running countdown to end itself, and ends one never
acknowledged as a lost presentation, so an offer raised onto a locked screen is offered again afresh
rather than recorded as declined. **What stays forbidden, and is not widened by this:** automatic
start, automatic deletion, and any timer answering the quiet offer. A second prompt that wants to act on a
timer is a new decision for the user, not an extension of this paragraph.

**Say what was measured, not what it implies.** `kAudioProcessPropertyIsRunningInput` means the process
runs IO with an active input stream — not that a meeting started. A muted participant usually keeps the
stream open; a listen-only one may never open it. The stop rule measures *energy*, not speech: it is not
a voice detector and must never be described as one. The prompts say "microphone activity" and "little
audio activity" for exactly this reason.

**Attribution is measured and mostly absent.** On this machine `NSRunningApplication` names 16 of 33
audio processes, and a call in a Safari tab is held by `com.apple.WebKit.GPU`, "Safari Graphics and
Media"; Chrome's audio is `com.google.Chrome.helper`. `activationPolicy == .regular` separates
user-facing applications from helpers, so only a regular application's name may go in a prompt.
Everything else is an unattributed prompt. Never map a helper to a parent application by guessing.

**Unknown is never idle, and never quiet.** An unreadable property, a partial process list, a failed
measurement, a stalled track, a generation change: each of these resets a clock rather than advancing
one. Collapsing any of them into "nothing is happening" produces a second prompt for one conversation,
or an offer to stop a live meeting. Every one of those has a regression test, and they were all found by
executing the rule rather than by reading it.

**The prompts are an in-app panel, and this was decided by measurement.** A `UNUserNotificationCenter`
banner does not show its action buttons — they appear on hover, in both the Temporary and Persistent
alert styles, verified with a registered two-action category. `UNNotificationSettings.alertStyle` is
read-only, and time-sensitive delivery needs an entitlement this app does not have. So the panel is
ours; it is **not** a notification, it does not respect Focus, and no copy anywhere may claim it does.

**Identity travels with every prompt, and is re-checked at the admission point.** An episode staying
*alive* through its anti-duplicate grace is not the same as a call still in progress
(`isEpisodeActionable`, not `isEpisodeLive`). A start from a prompt awaits the same microphone barrier a
socket `start` awaits, and re-checks quit, preference, episode and `canStart` after that await with no
suspension before the command. Quit latches `beginClosing()` synchronously at `applicationShouldTerminate`,
for the same reason the socket is torn down there.

**The meter is a passenger.** It runs on the capture queue after the write, behind a gate read before
anything else happens; with the stop reminder off, `AudioRecorder` does not call in at all. It keeps no
audio, starts no tasks, and publishes one coarse value per track per half-second. If a change here can
make a recording wait on analysis, the change is wrong.


## Not verified automatically (needs a human)
- Granting TCC permissions (Screen Recording, Microphone) — only via System Settings.
- **The reminder panel's half of the presenter contract.** `ReminderPresenterTests` and
  `OwnerReleaseOfferTests` drive an injected presenter. That the real panel acknowledges a countdown only
  once it is visible, reports a real lock, display sleep and full-screen Space as lost, and updates the
  number in place without moving, needs a human with a real lock and a real call. A panel that
  acknowledged while hidden would arm an automatic stop with every test green.
- Real audio capture — by running the app.
- **Microphone release on stop** — that the mic indicator and Control Center's attribution to Acta
  clear within ~5s after every stop, and after a watchdog restart. `SCKCaptureSource`'s teardown is
  exercised by **no test**: the suite runs against `FakeCaptureSource`, and the real path needs a
  TCC-authorized build, an audio device and a human watching the indicator. See Gotcha 4 in the
  `screencapturekit-audio` skill — the mitigation there is a workaround for a suspected macOS 26 SCK
  defect, so a regression here is silent and only a human can see it.
- The crash scenario **on real capture**. The `kill -9` → recover cycle itself is now automated
  (`HarnessCrashTests`, see the tests bullet above), so a regression in the crash-safety machinery
  fails the suite. What the harness cannot reach is what sits above its seams: a `kill -9` of the real
  **app**, killed while a real `SCStream` is feeding it, recovered on the next real launch. Worth a
  human's eyes when capture or recovery changes — the harness approximates that run, it does not
  replace it.
- **The microphone feature's own floor, which the seams end above.** The suite proves the decision
  logic and none of the OS behaviour:
  - **A real default-input write.** No test writes `kAudioHardwarePropertyDefaultInputDevice` on the
    real machine. System Settings must be *seen* to follow, and to keep following across a headset
    connect/disconnect cycle and across sleep/wake.
  - **That ScreenCaptureKit honours `microphoneCaptureDeviceID`.** The fake accepts any string. Only a
    TCC-authorized build recording from a deliberately non-default microphone — and the audio being
    listened to — proves the pin took effect. ⚠️ The identity probe does **not** cover this: equal UIDs
    say the string is the right string, not that capture used it.
  - **Live failover and *Use now* during a real recording** — the pinned device pulled out mid-recording
    and the next candidate actually producing audio rather than silence; and that the segments on both
    sides of a switch are valid and the assembled file survives a format change.
  - **That the production HAL listeners actually fire.** The observation tests drive the *fake*: they
    establish the contract's shape, not that `CoreAudioDeviceDirectory`'s registrations deliver. Only
    plugging a device in and out on a real Mac shows that — the same gap as `SCKCaptureSource`'s.
  - **That a real sleep/wake reconciles.** ⚠️ The *handler* is tested — a synthetic post into the
    injected notification centre exercises it (`aWakeReconcilesWhatSleepHid`), which is how it was
    found that replacing its body with a no-op had passed every test. What needs a human is the OS
    behaviour around it: that macOS posts the notification, and that the device world after a real sleep
    is what the reconciler then finds.
  - **That the fight-back policy is livable** — whether enforcement feels correct or hostile when the
    user reaches for System Settings anyway, and whether the conflict budget suspends at the right
    point.
  - **The menu's rendering.** ⚠️ Not "the menu cannot be tested" — that claim was wrong and cost four
    defects. `ControlViewModel` lives in `ActaRuntime` and its commands, subscriptions and intents are
    tested. What a human still has to look at is the **drawing**: that the priority rows never collapse
    on screen, that an absent preferred device is visibly removable, that Pause is reachable.
- The control socket **hosted by a bundled app**. `ControlSocketHost` is driven in-process against a
  fake handler (`ControlSocketHostTests`), but the real launch/quit lifecycle is not: that a bundled
  `Acta Dev.app` creates the socket at the dev path on launch, that a second launch refuses, and that
  quitting removes it, needs a human (a full `actactl` round-trip is Plan 3).
- **The `dev`-flavor acceptance run itself.** A green gate on `dev` is not the gate — the branch rule
  above exists because a human runs `Acta Dev.app` and looks. Nothing merges to `main` before that.
- Validation Commands check compilation/build/lint, unit logic, the in-process pipeline **and** the
  process-based crash harness — but nothing above the seams: no ScreenCaptureKit, no TCC, no UI.
