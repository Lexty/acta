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
  `SessionManifest`, `SelfCheckTuning`, `ControllerMessage`. Anything worth testing goes here —
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
  conforms to `ControlRequestHandling`) — plus the injected seams — `CaptureSource`/`SCKCaptureSource`,
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
  and its views) and `ControlViewModel.swift` (the UI-owned `ControlAPI` adapter — `@MainActor`
  `ObservableObject`, owned by `MenuContent` as `@StateObject`; seeds its `state` synchronously from
  `ControlAPI.shared.state` so the first frame is not blank, subscribes to `states()` from the view's
  `.task {}`, and keeps an optimistic local title reconciled against the pending write). New non-UI
  code belongs in `ActaRuntime`, not here.
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
while Acta is merely running) and **survive a recording ending**; putting it in
`RecordingDependencies` would mint one enforcer per session — several alive at once during a watchdog
restart, each writing `kAudioHardwarePropertyDefaultInputDevice`, which is Acta fighting itself.
So: an **app-lifetime** seam gets its own owner with its own wiring value.
`MicrophoneWiring.live` is that value and carries the same burden `RecordingDependencies.live` does
(a claim about production a test can call back, which a default argument can never be); the
difference is that `MicrophoneManager` calls each factory **once, in `init`**, and holds the result
for the process. **`MicrophoneManager` is the composition root** for this, exactly as
`RecordingSession` is for permissions: it builds the one `AudioDeviceDirectory` and hands it out —
whole to the reconciler it owns, and as the read-only `AudioDeviceReading` to everyone else.
⚠️ That protocol split is structural, not documentation: `AudioDeviceReading` has no
`setDefaultInput`, so "a recording never enforces, and never constructs a reconciler" is a fact the
package graph checks rather than a rule a reviewer has to remember. `MicrophoneManager.shared` inherits
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
  socket-free. What stays parked in `docs/backlog/` is the POSIX socket transport and the `actactl` CLI.
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
- **Three confinements, grep-enforceable — keep them green.** ScreenCaptureKit (`import
  ScreenCaptureKit`, `SCStream*`, `SCContentFilter`, `SCShareableContent`) appears only in
  `SCKCaptureSource.swift`; the TCC calls (`CGPreflightScreenCaptureAccess`,
  `CGRequestScreenCaptureAccess`, `AVCaptureDevice`) only in `SystemPermissions.swift`. That is what
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

## Not verified automatically (needs a human)
- Granting TCC permissions (Screen Recording, Microphone) — only via System Settings.
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
- Validation Commands check compilation/build/lint, unit logic, the in-process pipeline **and** the
  process-based crash harness — but nothing above the seams: no ScreenCaptureKit, no TCC, no UI.
