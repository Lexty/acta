---
worth: yes
where: docs/backlog/acta-full-plan.md:486
added: 2026-09-12
---
# a recording cannot be stopped without hand-writing a socket frame

The menu-bar item is the only way to stop a recording, and on 2026-09-12 it went off-screen **twice
within half an hour** — the status bar was full, the icon was pushed past the notch, and there was no
way to reach Stop. Both times the recording was ended by hand:

```
printf '{"version":2,"id":"x","command":{"type":"stop_and_wait"}}\n' \
  | nc -U ~/Library/Application\ Support/dev.personal.acta-dev/control.sock
```

That works — the socket, the command algebra and the dispatcher are all shipped — but it asks a person
under time pressure to get a JSON envelope, a protocol version and a command tag right by hand, at the
moment they are least able to. `stop_and_wait` in particular has to be chosen deliberately over `stop`
to know the segments were assembled rather than merely that the command was accepted.

**This is not a new design.** `acta-full-plan.md` already specifies **Plan 3 — the `actactl` CLI**, down
to the hardening: CLI logic in a testable `ActaCLI` library behind a thin entry point, a mandatory
`--stable`/`--dev` with no default that could address the wrong running app, no launch-on-demand and no
LaunchServices in discovery, stable per-condition exit codes, and `Scripts/test.sh` locating the built
binary rather than nesting a build through `swift run`. `AGENTS.md` already refers to "the CLI" as the
client that must invent nothing beyond `Command`. What is missing is only the client itself.

What this sighting adds is **materiality**: the missing client is now the difference between stopping a
recording and losing access to the running app's one control. `stop` and `stop_and_wait` are the part
that earns its keep first; `status` and `start` are convenience.

⚠️ **Not to be confused with fixing the icon.** A status item can always be pushed off a full menu bar,
and the CLI is the answer to that regardless of whether anything is done about the icon itself.
