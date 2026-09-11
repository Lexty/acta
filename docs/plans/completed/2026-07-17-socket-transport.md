# Plan: The POSIX Unix-socket transport, hosted in the app (plan 2 of 3)

## Overview

The security-critical middle of the socket/CLI transport. Plan 1 built the wire protocol and a
`@MainActor` dispatcher behind a `ControlRequestHandling` abstraction (`func handle(_ Command) async ->
ControlResponse`, where `ControlResponse` is `.result` / `.error` / `.events(AsyncStream<WatchEvent>)`).
This plan makes that reachable over a **Unix domain socket** hosted by the running menu-bar app, so
`actactl` (Plan 3) can connect. It is the descriptor layer and nothing the CLI needs later.

**The trust boundary is the filesystem, and only that.** `AF_UNIX`/`SOCK_STREAM` only — never TCP,
Bonjour or a network fallback; **no token** (a `0600` socket in a `0700` user-private directory is the
whole boundary; any process running as the user can already act as the user). The server only serves an
already-running app; an absent socket means "not running" to a client (no implicit launch anywhere).

**A socket exposes real authority, and the plan is honest about it.** Every same-UID process gains what
the control API can do: start microphone capture, stop/finalise a recording, run recovery, persist
settings, activate Finder, set the title. That is the accepted consequence of a same-UID control socket.
**Two things the socket must nonetheless not grant, decided here:** (a) it must not relocate the archive
— Plan 1's `settingsSet` writes `archive_path` verbatim, so a socket could otherwise make `list`
enumerate any readable directory and `start` record into it; (b) it must not accept unbounded/adversarial
wire strings. So a **socket-specific dispatcher** ignores a wire-supplied `archive_path` and keeps the
current authoritative one, and all wire strings (title especially) are length-bounded and validated. The
in-process UI dispatcher stays unrestricted — a human relocating their archive is fine.

**Privacy framing, accurate:** the server drives `ControlAPI.shared` (the menu's controller) — no hidden
second recording pipeline; an API-started recording shows in the menu **when the menu is opened** (there
is no persistent menu-bar recording indicator; do not claim one).

## Validation Commands

- `swift build -c release`
- `bash Scripts/test.sh` (existing 409 tests **plus** the endpoint, serving and lifecycle tests; needs `ffmpeg`). ⚠️ The transport tests run **real sockets in-process** (temp paths) — `Scripts/test.sh` must treat **abnormal runner termination** (a crash, e.g. a `SIGPIPE` regression) as failure, not as "no failing `@Test`"
- `bash Scripts/lint.sh`
- `bash Scripts/bundle.sh dev` (flavor defaults to `dev` when omitted; `stable` refuses a dirty or untagged tree)

## Read before working

`SPEC.md`, `CLAUDE.md`, and the Plan-1 code: `ControlRequestHandling`/`ControlDispatcher`/`ControlServing`,
the `JSONLinesFramer`, the wire `Command`/`CommandResult`/`WireError`/`WatchEvent`. ⚠️ **Facts the tasks
depend on** — verify: `ControlDispatcher` is `@MainActor`, conforms to `ControlRequestHandling`, and has
main-actor access to `ControlServing` (so it — not a blind `handle`-wrapper — is where a socket settings
policy can read the current archive path); `ControlAPI.shared` is the menu's controller;
`Bundle.main.bundleIdentifier` is the flavor id (`dev.personal.acta` / `-dev`); `AppDelegate` has
`applicationDidFinishLaunching` and `applicationShouldTerminate` (`.terminateNow` / `.terminateLater`) but
**no `applicationWillTerminate`**; SwiftPM **cannot import the `Acta` executable**; Foundation/POSIX/Darwin
only.

## Scope of this plan

**In:** a secure Unix-socket endpoint; a connection-serving layer (non-blocking I/O with an explicit
descriptor-ownership model, framing, the `@MainActor` dispatch hop, `watch` streaming, deadlines, clean
shutdown) with the socket-specific settings policy and wire-string validation; and hosting exactly one
server in the app with synchronous orderly teardown.

**Out, and staying parked:** the `actactl` CLI (Plan 3); launch-on-demand; a network listener; auth
tokens; protocol versions beyond v1.

### Task 1: The secure endpoint

**Why.** Binding the socket safely — right path, right permissions, never severing another live instance
— is where a bug is a security bug, so it is built and tested in isolation first.

- [x] **Flavor-specific path**: `~/Library/Application Support/<Bundle.main.bundleIdentifier>/control.sock` (falling back to `AppInfo.bundleID` outside a bundle, as `BuildFlavor.logSubsystem` does) — `ControlEndpoint.live()`
- [x] **Verify the private directory.** Create it if absent with mode `0700`; then **open it with `O_DIRECTORY | O_NOFOLLOW`** and `fstat` the handle to confirm a **real directory, current-UID-owned, mode `0700`** (reject a symlink or foreign owner). Perform endpoint and lock operations **relative to that verified descriptor** using `openat`/`fstatat`/`unlinkat` with `AT_SYMLINK_NOFOLLOW` — `openPrivateDirectory()`
- [x] ⚠️ **A `flock`-held initialization lock over the WHOLE sequence.** A lock file **opened relative to the verified directory with `O_NOFOLLOW`**, confirmed to be a **current-UID regular file** with a restrictive mode, held with `flock(LOCK_EX)` across probe → stale-unlink → `bind` → `chmod` → verify → `listen`, re-validating after acquiring it. Release only after `listen()` — `acquireInitLock()`, lock `lockFD` released by `defer { close(lockFD) }` after `listen`
- [x] ⚠️ **Stale-socket recovery, exactly.** Try `bind`. On `EADDRINUSE`, attempt a short `connect`: if it **succeeds**, another server is alive — **refuse**, unlink nothing. If `connect` fails **specifically with `ECONNREFUSED`** (never on timeout / `EACCES` / resource exhaustion / `EINPROGRESS` / unknown), `fstatat`-inspect the path and **unlink (via `unlinkat`) only if it is a socket owned by the current UID** — never a regular file or a symlink — then retry `bind` **once**; if it still fails, stop. ⚠️ The inspect→unlink pair is **not atomic**; this is safe **only** under the stated model (a verified `0700` directory excludes other UIDs, and same-UID processes are trusted) — state that dependency — `bindSocket()`/`probe()`, dependency stated in the type doc comment
- [x] **After bind:** `chmod` the socket to `0600`; verify its **type, owner, mode and device/inode**; `listen()`; release the lock. ⚠️ The `bind`→`chmod` window may briefly leave the socket at the process umask — **acceptable only because the `0700` parent excludes other UIDs** (state this; do not rely on `chmod` being atomic with `bind`). On orderly shutdown, `unlinkat` the socket **only if it is still the same device/inode** this server created — `verifyBoundSocket()` captures `SocketIdentity`, `BoundSocket.remove()` unlinks only on device/inode match
- [x] ⚠️ **Correct Darwin `sockaddr_un`:** zero-initialise; set `sun_len`; **reject a path containing an embedded NUL**, and one whose **UTF-8 byte length + NUL exceeds `sun_path`** (character count is not byte length); pass the exact address length **`offsetof(sun_path) + utf8ByteCount + 1`** (not `MemoryLayout<sockaddr_un>.size`); rebind pointers safely — `ControlSocketAddress`
- [x] Tests with a **real socket on a temporary short path**: clean bind + `listen`; a **live** server is never unlinked (a second bind refuses); a **stale** (`ECONNREFUSED`) socket is unlinked and rebound; a **regular file or symlink** at the path is **never** removed; the socket ends `0600` and the parent `0700`; an over-length path, an embedded-NUL path, and a **non-ASCII** (byte-length) path are handled correctly — `ControlEndpointTests`
- [x] Acceptance: build/test/lint/bundle green

### Task 2: Serving connections, the settings policy, and wire-string validation

**Why.** Turning bytes into a dispatched command without a slow client ever blocking the app or touching
the main actor — plus the authority the socket must not grant.

- [x] ⚠️ **Non-blocking I/O with an explicit descriptor-ownership model.** Drive `accept`/read/write with **`kqueue` or a `DispatchSource`** on non-blocking fds — a blocking POSIX syscall on a Swift cooperative task starves the executor even off the main actor. The ownership rules are load-bearing against fd-reuse races: **exactly one serialized owner per descriptor**; **exactly one `close()` path**; **no syscall after ownership has transitioned to closed**; **race-safe, exactly-once continuation resumption** across readiness / timeout / cancellation; if `DispatchSource` is used, its event and cancellation handlers are serialized on one queue and the source is **retained until its cancellation handler finishes**. Cancellation `shutdown()`s the fd to wake a pending readiness wait, but `close()` stays single-owner
- [x] **Per connection**: read and frame with Plan 1's `JSONLinesFramer` and its size limits (`EINTR` retry lives **here**, at the syscall boundary); decode **one** request; a `Task { @MainActor in … }` does only validation + dispatch + projection; write off the main actor. A normal command yields **exactly one** response frame, then close; **`watch`** consumes the `.events(AsyncStream<WatchEvent>)` and writes each event until the client disconnects
- [x] ⚠️ **The socket settings policy — a socket-specific dispatcher, not a blind `handle`-wrapper.** Because `ControlRequestHandling` exposes no settings getter, the policy is applied where the current settings are readable **on the same main-actor turn** as the change: a socket-configured dispatcher, on `settingsSet`, **ignores the wire `archive_path` and constructs the applied settings from the current authoritative archive path** (do not string-compare paths — ignore-and-substitute is race-free and avoids spelling ambiguity), applying only `segmentSeconds`/`deleteSegmentsAfterAssembly`. The **in-process UI dispatcher is not so configured**. Decide `settingsSave` deliberately: a socket may persist settings, but only ones it was allowed to set (never a smuggled archive path)
- [x] ⚠️ **Validate every wire string.** Bound the `title` length and reject control characters / NULs in it and in any other caller-supplied string, so a socket cannot drive unbounded memory or disk use through the app's state
- [x] ⚠️ **A slow or disconnected client must never harm the app.** `SO_NOSIGPIPE` on the socket (the Darwin mechanism — **not** the Linux `MSG_NOSIGNAL`) so a peer disconnect mid-write cannot signal-kill Acta; handle `EPIPE`/`EAGAIN`/short writes; per-connection **read/idle/write deadlines**; a **connection cap** (~16, reject excess); bounds on undecoded input, pending output and connection lifetime; a slow watcher keeps at most the newest pending state
- [x] **Clean shutdown**: stop accepting, cancel connection and watcher tasks, `shutdown()`+`close()` all owned descriptors (single-owner) so pending readiness waits wake, and `unlinkat` the listener's exact socket
- [x] Tests with a **real socket** (temp path) and a **fake `ControlRequestHandling`/dispatcher**: request→one response→close; `watch` streams events and **coalesces to the newest when the writer/output is deliberately stalled** (not merely sent fast); a disconnect cancels the watcher's task; a **peer disconnect mid-write does not kill** the process (and `test.sh` treats a runner crash as failure); a **slow client does not block a second**; a `settingsSet` carrying a different `archive_path` **applies segment length but keeps the current archive path**; an over-long/illegal `title` is rejected; a read/idle deadline fires; **cancelling a pending readiness wait** (there is no blocked `accept`) closes the fd; a short-write/`EAGAIN` path is exercised with a **saturated small socket buffer**, not a fake writer
- [x] Acceptance: build/test/lint/bundle green

### Task 3: Host exactly one server in the app

**Why.** Wiring the server to the real `ControlAPI.shared`, with a lifecycle that removes its socket on
orderly quit and never sacrifices a recording to a client.

- [x] **The lifecycle owner is a type in `ActaRuntime`** (SwiftPM cannot import the `Acta` executable). It builds the socket-configured dispatcher over `ControlAPI.shared`, owns the Task-1 endpoint and Task-2 serving, and exposes `start()` and a ⚠️ **synchronous, bounded `teardown()`** — because `applicationWillTerminate` is **not** an async suspension point, so a shutdown dispatched into a `Task` may not run before the process exits. `teardown()` synchronously stops accepting, `shutdown()`+`close()`s owned descriptors, initiates cancellation, and conditionally `unlinkat`s the socket; it **does not await client tasks**
- [x] **`AppDelegate` is thin wiring**: `start()` from `applicationDidFinishLaunching` **after** recovery is kicked off; log start and any bind refusal. ⚠️ **Call the synchronous `teardown()` on every orderly AppKit termination route** — add an `applicationWillTerminate` (there is none today) that calls it, reached by **both** the `.terminateNow` and the `.terminateLater` replies from `applicationShouldTerminate` (the `.terminateLater` path finalises the recording via the existing `stopAndWait()` first, then terminates, then `applicationWillTerminate` tears the socket down). It cannot cover `SIGKILL`/crash — stale-socket recovery handles those, so say "every **orderly** route", not "every route"
- [x] Tests: the `ActaRuntime` lifecycle owner in-process — `start()` binds and serves through a fake handler; `teardown()` closes and **unlinks its own socket** (and unlinks nothing when it no longer owns the path); a `start()` when another owns the path **refuses**. ⚠️ **Morning check (needs a human):** a **bundled** `Acta Dev.app` creates the socket at the dev path on launch, a second launch refuses, and quitting removes the socket (a full `actactl` round-trip is Plan 3) — automated in-process (`ControlSocketHostTests`); the bundled launch/quit lifecycle is recorded in CLAUDE.md's "Not verified automatically" section as a manual check
- [x] Update `CLAUDE.md`: the app hosts a Unix control socket at `~/Library/Application Support/<bundle-id>/control.sock` (`0600`, `0700` parent); the trust model (file permissions, no network, no token); the socket's refusal to relocate the archive; and the wire-string bounds
## Backlog (not this plan)

Plan 3 — the `actactl` CLI: logic in a library `ActaCLI` (unit-tested in-process) + a thin `actactl`
entry point; `Scripts/test.sh` explicitly builds/locates `actactl` for the one real subprocess test
(never `swift run actactl`); mandatory `--stable`/`--dev` (no default that could hit the wrong app, no
dev↔stable fallback); **no launch-on-demand** and no `NSWorkspace`/`open`/LaunchServices/activation in
discovery or retry; stable per-condition exit codes; a bundled + real-capture check stays manual.
Recorded in `docs/backlog/acta-full-plan.md`.
