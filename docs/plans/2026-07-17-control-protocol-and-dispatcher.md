# Plan: The wire protocol and command dispatcher for `actactl` (in-process; no socket yet)

## Overview

The socket/CLI transport that will let an agent drive Acta is large and security-critical, so it is
split into three plans: **(1) this one — the pure wire protocol and the command dispatcher, entirely
in-process**; (2) the POSIX Unix-socket transport hosted in the app (the security-critical layer, with
real-socket tests); (3) the `actactl` CLI. This plan builds the parts that need no socket, so they land
with full unit coverage before any descriptor code exists.

Two shapes matter. The **wire protocol is a pure, dependency-free target** — it never imports the
runtime, so a `Codable` envelope and wire values are defined once and shared by the server and the CLI.
The **dispatcher maps a decoded command to a `ControlAPI` call** behind a narrow protocol, so command
policy (a busy `start`, honest immediate-vs-completion semantics, `watch` coalescing) is testable with a
fake — and the future transport depends on a **handler abstraction**, not on the concrete singleton.

The privacy framing, stated accurately: the transport drives `ControlAPI.shared`, the same controller
the menu observes, so it creates **no hidden second recording pipeline** — an API-started recording
shows in the menu **when the menu is opened**. (There is no persistent menu-bar recording indicator
today; do not claim one.)

## Validation Commands

- `swift build -c release`
- `bash Scripts/test.sh` (existing 317 tests **plus** the protocol and dispatcher tests; needs `ffmpeg`)
- `bash Scripts/lint.sh`
- `bash Scripts/bundle.sh dev` (flavor defaults to `dev` when omitted; `stable` refuses a dirty or untagged tree)

## Read before working

`SPEC.md`, every requirement in `CLAUDE.md`, and `ControlAPI` / `ControlState` / `MeetingStore.Recording`
/ `RecordingSettings`. ⚠️ **Facts the tasks depend on** — verify them: `ControlState` and its sub-types
are `Equatable, Sendable` but **not `Codable`**; `recordings` is `[MeetingStore.Recording]` (a `URL` +
a `SessionManifest`); `ControlAPI` is `@MainActor`, exposes the commands + `state` + `states()` in its
source, and `states()` is **unbounded**; `ControlAPI.start(title:)` **mutates the title even when busy**;
`ControlState` already computes `canStart`/`canStop`. No external SwiftPM dependencies (Foundation only).

## Scope of this plan

**In:** a dependency-free `ActaControlProtocol` target (the `Codable` envelope, the full command
algebra, wire state/settings/summary types, the JSON-lines framer, stable error codes, versioning); the
pure projection from `ControlState` into the wire types (in `ActaRuntime`); and an `@MainActor` command
dispatcher behind a narrow `ControlServing` protocol, exposed to the future transport as a
`ControlRequestHandling` abstraction.

**Out, and staying parked (later plans):** any socket/POSIX/descriptor code; hosting a server in the
app; the `actactl` executable; launch-on-demand; a network listener; auth tokens.

### Task 1: The dependency-free wire protocol

**Why.** A `Codable` boundary that never imports the runtime is what lets the server and the CLI share
one definition and be tested with fixtures, in-process.

- [x] **A new target `ActaControlProtocol` with NO package dependency** — it imports only Foundation (for `Codable`/`Data`/dates). ⚠️ Enforce the isolation **structurally in `Package.swift`** (the target lists no `dependencies`), not only by an import grep; and it must not import `MeetingStore`, `RecordingController`, `ControlAPI`, `RecordingSettings`, AppKit or SwiftUI. The wire settings type is its **own** `WireSettings`, **not** a re-export of the runtime `RecordingSettings`, so the wire schema is not coupled to the runtime representation
- [x] **A `Codable` envelope with a top-level integer `version` (=1)**: request `{version, id, command}`, response `{version, id, result}` | `{version, id, error}`, watch `{version, id, event}`. Errors carry a **stable machine `code`** + a human `message`. Version matched **exactly**; forward-compat rules stated, no adapters built: ignore unknown keys, only optional fields added within v1, unknown command/enum discriminators → `unsupported_command`/`unsupported_value` (never a crash), version mismatch → `unsupported_version` carrying the supported versions
- [x] **The FULL command algebra AND result algebra, defined here** (so the dispatcher and the CLI invent nothing). Commands: `status`, `list`, `watch`, `start(title?)`, `stop`, `stopAndWait`, `recover`, `refresh`, `openArchive`, `openInFinder(id)`, `settingsGet`, `settingsSet(WireSettings)`, `settingsSave`, `titleGet`, `titleSet(String)`, `dismissRecoveryNotice`. ⚠️ **Every command's `result` case and payload is fixed here too**, discriminated: `state(WireControlState)` (status/start-accepted/stop-initiated/completion all return the projected state), `recordings([RecordingSummary])` (list), `settings(WireSettings)`, `title(String)`, and `ok` (void acknowledgements: recover/refresh/openArchive/openInFinder/settingsSet/settingsSave/titleSet/dismissRecoveryNotice). The JSON discriminator shape (a `type` tag + associated payload) is pinned in fixtures
- [x] ⚠️ **Custom decoding for forward-compat, not synthesized.** A synthesized `Codable` command enum fails to decode an unknown discriminator **before** the dispatcher can answer — so decode the command/enum discriminators by hand and map an unknown one to a decoded `unsupportedCommand(raw:)` / `unsupportedValue`, never a decode throw. **The complete stable error-code set is frozen here** with **exact code-specific fields**, each on top of `{code, message}`: `command_rejected` `{reason: String}`; `unknown_recording` `{id: String}`; `unsupported_command` `{raw: String}` (the unknown command tag); `unsupported_value` `{field: String, raw: String}`; `unsupported_version` `{supported_versions: [Int]}`; `not_recording` (no extra field); `internal` (no extra field)
- [x] **Wire value types** (`Codable, Equatable, Sendable`): `WireControlState` (`operation` = `kind` idle/starting/recording/saving with `elapsed_seconds` only when recording; `lifecycle_failure`/`notice`/`recovery_notice` as `{code, message}`; `title`, `suggested_title`, `settings: WireSettings`, `recordings: [RecordingSummary]`, `can_start`, `can_stop`), `WireSettings`, and `RecordingSummary`. ⚠️ Its fields must survive a **missing manifest** (`MeetingStore.Recording.manifest` is optional): an **opaque `id`**, `directory_name` and `path` are **always present**; `status` is `recording`/`done`/`recovered`/**`unknown`** (the last when the manifest is absent); `started_at` (ISO-8601), `segment_seconds`, `segment_count`, `assembly_attempts` are **optional** and omitted when the manifest is absent. ⚠️ **The opaque `id` is specified, not left to the implementer:** the exact, frozen encoding **`"v1:" + base64(UTF8(directory.lastPathComponent))`** using the URL-safe base64 alphabet (`-`/`_`, no `=` padding) — reversible and collision-free — produced by a **shared helper used by both the projection and the id→recording lookup** (which base64url-decodes the `id`, matches the `lastPathComponent`, and rejects any `id` that does not decode or does not match a current recording), so they cannot diverge; `path` is the recording directory's absolute path (this is a local-archive agent interface — but `openInFinder` still resolves by `id`, never by a caller-supplied path). Explicit JSON date handling; **sorted keys** in fixtures; do not rely on encoder defaults
- [x] **A JSON-lines framer as a precise byte protocol**: one UTF-8 JSON object then exactly one `LF`; a newline may span reads and several frames may arrive in one read; a non-empty unterminated tail at EOF is a truncated-frame error; empty lines invalid; short writes handled (never assume one `write` sends a whole frame — loop until fully written). ⚠️ The size limit is **buffered payload bytes excluding the terminating `LF`**, **directional and exact**: request limit **65536 bytes (64 KiB)**, response limit **1048576 bytes (1 MiB)**, named as separate constants. **On oversize the framer fails the stream immediately** (it does not discard-through-the-next-`LF` and resume — a control socket has no reason to skip a frame). The **maximum read-chunk is 65536 bytes (64 KiB)**; the framer must handle a reader that returns a larger chunk (slice it) rather than trusting it. ⚠️ **`EINTR` is out of this plan** — it is POSIX syscall behaviour and belongs to Plan 2's descriptor adapter; a pure framer tested against an injected reader/writer cannot honestly cover it. Tested with an injected reader/writer
- [x] Tests (in-process, no socket): golden fixtures; unknown-key tolerance and exact-version rejection; fragmented input, multiple frames per read, an oversized (over-limit) frame rejected, a truncated frame at EOF; short-write handling via an injected writer
- [x] Acceptance: `swift build -c release`, `bash Scripts/test.sh`, `bash Scripts/lint.sh`, `bash Scripts/bundle.sh dev` green; the `ActaControlProtocol` dependency/import-confinement grep is clean

### Task 2: The projection and the `@MainActor` command dispatcher

**Why.** Turning `ControlState` into the wire type, and a decoded command into a `ControlAPI` call, is where the transport-facing policy lives — and all of it is testable with a fake, before any socket exists.

- [ ] **The projection in `ActaRuntime`** (where both `ControlState` and the wire types are visible): pure `WireControlState(state:)` and `RecordingSummary(_:)` — **not** `Codable` conformances on the runtime types. The recording `id` is an opaque stable encoding of the archive-relative directory name
- [ ] **A narrow `ControlServing` protocol** (the commands + `state`/`states()` the transport needs) that `ControlAPI` conforms to; and a **`ControlRequestHandling` abstraction** — the thing that takes a decoded wire request and returns a wire result/event stream — which the future transport will depend on **instead of** the concrete dispatcher or the singleton
- [ ] **An `@MainActor` dispatcher** implementing `ControlRequestHandling` over a `ControlServing`. ⚠️ `start` **rejects with a `command_rejected` error when `state.canStart == false`, on the same main-actor turn, before calling `start`** — otherwise `ControlAPI.start(title:)` edits the title on a start that cannot proceed
- [ ] **Honest command semantics**: `start` → `accepted` + the immediately projected state (**not** "capture started"); `stop` → stop initiated; `status`/`list` → snapshots and must **not** call `refresh()` implicitly; `openInFinder(id)` resolves the **opaque id** (via the Task-1 shared helper) against the current recordings and returns `unknown_recording` if it does not match. ⚠️ **`stopAndWait` — the finalisation is detached from the request, with a concrete ownership model**: the dispatcher stores an **unstructured `Task`** for the current finalisation only **while it is in flight**, and each `stopAndWait` request `await`s that task's **value**; a client giving up or a timeout cancels **only its own await**, never the stored task; concurrent `stopAndWait`s for the *same* stop await the *same* task. ⚠️ **Reset policy:** the stored task is **cleared when it completes**, so a later recording's `stopAndWait` never reuses a stale completed task — it starts a fresh finalisation; a `stopAndWait` when nothing is recording or stopping returns the current state immediately without creating a task
- [ ] ⚠️ **Do not overclaim actor serialization.** Main-actor access is serialized only *between* suspension points, and an `async` `stopAndWait` permits reentrancy — so the invariant is stated precisely: **every `ControlServing` access happens on `MainActor`**, and any whole-request ordering that is actually required is provided by the stored-task model above, not by assuming the actor serializes across `await`
- [ ] **`watch`, with an exact construction rule**: consume the **first element of `states()` as the initial event** (do not separately read `state` then subscribe — that risks a duplicate or a fetch/subscribe ordering gap). ⚠️ Because `ControlAPI.states()` is **unbounded**, place a concrete bounded primitive between it and the (later, slow) writer — `AsyncStream(bufferingPolicy: .bufferingNewest(1))` or an equivalent single-slot mailbox — so at most one pending state per subscription survives, replaced by the newest; a `sequence` is assigned **before** coalescing (so a client can see that intervening states were dropped, rather than pretending none were). Document this as transport coalescing, distinct from `states()`'s sampling contract
- [ ] Tests with a fake `ControlServing` (no socket): every command mapping; a busy `start` returns `command_rejected` **without changing the title**; error codes incl. `unknown_recording`; the immediate-vs-completion semantics; `watch` initial replay, coalescing to the newest pending state, and cancellation; that every `ControlServing` access is on `MainActor`; and that concurrent `stopAndWait`s for one stop **share the same stored task** (one underlying stop), while a later recording's `stopAndWait` creates a **fresh** one
- [ ] Acceptance: build/test/lint/bundle green

## Backlog (not this plan)

Plan 2 — the **POSIX Unix-socket transport** hosted in the app, depending on the `ControlRequestHandling`
abstraction from this plan: `AF_UNIX`/`SOCK_STREAM` only (no network, no token; parent dir `0700`, socket
`0600`); flavor-specific path under `~/Library/Application Support/<bundle-id>/`; ⚠️ a **`flock`-held
initialization lock** over the whole probe/stale-unlink/bind/chmod/listen sequence to close the race
where two instances unlink each other's live socket (unlink only a `ECONNREFUSED`-dead, current-UID-owned
**socket**, never a regular file/symlink, and re-validate under the lock); **non-blocking descriptors via
`kqueue`/Dispatch I/O** (a blocked POSIX syscall on a cooperative task starves the executor even off the
main actor), with cancellation that `close()`/`shutdown()`s descriptors; Darwin **`SO_NOSIGPIPE`** (not
`MSG_NOSIGNAL`); correct `sockaddr_un` (zero-init, `sun_len`, UTF-8-byte-length path check, right address
length); per-connection deadlines and a connection cap; the **server lifecycle owner in `ActaRuntime`**
(a library, since SwiftPM cannot import the `Acta` executable where `AppDelegate` lives) stopped on
**every** termination route (there is no `applicationWillTerminate` today). Plan 3 — the **`actactl` CLI**:
CLI logic in a library `ActaCLI` (unit-tested in-process) + a thin `actactl` entry point, with
`Scripts/test.sh` explicitly building/locating `actactl` for the one real subprocess test (never
`swift run actactl`); **mandatory `--stable`/`--dev`** (no default that could hit the wrong app, no
dev↔stable fallback); **no launch-on-demand** and no `NSWorkspace`/`open`/LaunchServices/activation in
discovery or retry; stable per-condition exit codes. All in `docs/backlog/acta-full-plan.md`.
