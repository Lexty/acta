---
worth: yes
where: Scripts/bundle.sh:129
added: 2026-09-13
---
# ship Acta as a notarized Homebrew cask

To run Acta today you clone the repository, run `Scripts/bundle.sh`, and let `setup-signing.sh` mint a
self-signed certificate in a dedicated keychain. There is no route for someone who does not want a
compiler.

**The route is decided (2026-09-13, by the owner): `brew install --cask`.** A notarized artefact,
published from a public repository, installed through a cask in a personal tap. What is still not
decided is nothing technical — it is the one purchase below, which is not an engineering call.

## Prerequisite that is not code

Apple Developer Program membership, published at USD 99/year (local currency and tax apply). One
membership covers both Developer ID and App Store distribution; there is no separate notarization or
submission charge. Everything else in this item is free: notarization, GitHub Releases and Pages from a
public repository, and a personal tap, which is one more public repository.

## Four mechanisms, and the first draft of this item ran them together

Getting this wrong sends the work in the wrong direction, so they are separated here deliberately.

- **Signature.** A self-signed bundle *is* signed, and its signature verifies on any Mac. It is not
  tied to the machine that produced it.
- **Designated requirement.** What the local certificate buys is a requirement (identifier + leaf) that
  survives a rebuild, which is why a local build keeps its permissions. Apple documents self-created
  identities and requirements in TN2206.
- **Quarantine and Gatekeeper.** A downloaded artefact is quarantined *because it was downloaded*, not
  because of who signed it. What an ordinary download needs to open without a security exception is
  Apple-recognised distribution trust: Developer ID plus notarization.
- **TCC.** Neither a certificate nor notarization grants Microphone or Screen Recording. The user
  grants those, every time, whatever the signature says.

⚠️ **So "a prebuilt install is impossible without paid membership" is too strong**, and the first
version of this item said it. macOS has a documented Open Anyway path for an unidentified developer.
The defensible product requirement is the narrower one: *a normal install, with no security exception
asked of the user, needs Developer ID and notarization.* We should not ship instructions that teach
people to strip quarantine or click past Gatekeeper — and Homebrew's own policy forbids a cask that
does.

## The work

**Release signing.** Not "swap the certificate". Hardened runtime, a secure timestamp, signing nested
executable components, notarization, and stapling the ticket — Apple's notarization troubleshooting
page is the list. Against that, the current build script:

- signs at `Scripts/bundle.sh:129` with no `--options runtime` and no `--timestamp`;
- ends at `Scripts/bundle.sh:137` with `codesign --verify --verbose=2 "$APP_DIR" || true`, so
  **verification cannot fail the build**. A release path needs that gate to be fatal, and the local dev
  path can keep its leniency.

Keep a separate dev identity and keep the production bundle identifier and requirement stable across
releases, or every release re-prompts for both permissions.

⚠️ **Do not promise from reasoning that every existing local-build user must re-grant.** Moving to a
Developer ID identity changes the requirement, and `AGENTS.md` documents that trap for the
ad-hoc→certificate switch — but which users on which OS versions actually re-prompt is a thing to
observe during a real upgrade, not to assert here.

**Distribution.** A DMG or zip attached to a release of the now-public repository, and a cask in a
personal tap (`Lexty/homebrew-acta`) pointing at it, declaring the macOS minimum and the architectures
that were actually tested.

**Metadata that is wrong today.** `Resources/Info.plist` declares `LSMinimumSystemVersion = 14.0`,
while recording needs macOS 15 (`SCStreamConfiguration.captureMicrophone`) and everything under
`MenuContent` is gated on 15. Building and *usefully running* have different minimums, and a public
artefact should advertise the recording one in its own metadata as well as in the cask. Choose and test
the CPU architectures explicitly rather than inferring them from an OS minimum.

## Homebrew is a delivery channel, not the trust mechanism

- Official `homebrew/cask` policy requires an artefact to pass its Gatekeeper checks without disabling
  or bypassing protections, to work on the declared architectures and on the current macOS, and to come
  from a verifiable developer-published source; it also applies shared acceptance rules a new project
  cannot count on.
- Homebrew applies quarantine to cask downloads, so a cask does not route around the OS.
- A **personal tap** avoids the central tap's editorial acceptance and is the first channel here.
  "No criteria at all" is still wrong: it means the cask DSL, maintenance, and the same OS trust
  behaviour. Acceptance into the official tap need not block a first release.

What a cask genuinely buys here is `depends_on formula: "ffmpeg"`.

## `ffmpeg`, stated at its real size

`ffmpeg` is needed to assemble, not to record. Without it a recording runs to the end and fails at
assembly — and ⚠️ **nothing is lost**: the recovery marker stays `recording`, the segments are intact,
and installing `ffmpeg` and relaunching assembles the meeting (`RecordingController.swift:433`). The
first version of this item called it losing the meeting; it is not. What it is, is a stranger meeting
an error screen straight after their first real call, which is the worst moment to learn about a
dependency. That is an argument about first-run trust, and it is the reason the cask declares the
dependency rather than the README mentioning it.

⚠️ `SegmentAssembler.locateFFmpeg` tries `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, then
`PATH`. An app launched from Finder does not inherit the shell's environment, so the three fixed paths
carry more of the decision there than they do in a terminal — but the resolver still consults `PATH`,
and what it contains depends on the launch environment. That is a reason to test an **actual Finder
launch with the supported installation route**, not a reason to assert what a Finder `PATH` holds.

Bundling a licensed `ffmpeg` build is the alternative to declaring it; it adds third-party licensing,
signing and resolution work, so the declared dependency is the smaller first scope.

## Why not the Mac App Store

Recorded so the question is not re-argued from scratch. Reviewed on 2026-09-13 against Apple's current
text; the first version of this reasoning was wrong in three places and the corrections are the useful
part.

The same membership covers it, and a free app owes no commission — **the App Store is not the more
expensive route, it is the one that needs a port.** What the current build would have to change:

- **App Sandbox becomes mandatory** (`Resources/Acta.entitlements` sets `app-sandbox` to `false`
  today), under guideline 2.4.5(i).
- **The Homebrew `ffmpeg` dependency is the actual conflict**, under 2.4.5(ii) — "self-contained,
  single app installation bundles and cannot install code or resources in shared locations" — and
  2.5.2 — "may not … execute code which introduces or changes features or functionality of the app".
  ⚠️ That is a rule about *depending on a separately installed binary*, **not** a ban on subprocesses:
  Apple documents embedding a command-line tool in a sandboxed app, explicitly including one built by
  an external build system, and states the steps assume an App Store destination. The helper is signed
  with `app-sandbox` plus `inherit`, so it inherits the parent's sandbox rather than escaping it.
- ⚠️ **The `ffmpeg` licence is a compliance question about one build, not a blanket bar.** FFmpeg is
  LGPL-2.1-or-later by default and becomes GPL only when GPL components are enabled; shipping it means
  pinning the exact version and configuration, providing the corresponding sources, and preserving the
  rights the licence requires. The Homebrew build is not necessarily the build one may redistribute.
- **The archive moves.** `RecordingSettings.resolvedArchiveURL` puts meetings in the home directory,
  where `acta-notes` reads them. A sandboxed app can still use an ordinary folder outside its
  container, through a user selection and a persistent security-scoped bookmark — but the plugin needs
  its own access; seeing the path grants it nothing.
- **The control socket does not survive a naive move.** `ControlEndpoint.swift:25` takes its capacity
  from `sun_path` — 104 bytes on Darwin, path plus NUL. The container form of the live path measures
  **125 bytes**, so the address cannot even be constructed, before any sandbox decision is reached.
- **Updates.** 2.4.5(vii) requires an App-Store-installed build to take its updates from the App Store,
  so the two channels are two artefacts. ⚠️ It does not imply two source trees, and does not require
  the direct-download build to be unsandboxed; one sandbox-compatible implementation could serve both.

⚠️ **ScreenCaptureKit under the sandbox is not a blocker.** Apple's own sample sets `app-sandbox` to
`true`, configures `capturesAudio` and handles the `.audio` output. That is source evidence, not a live
test of Acta — and the sample declares no `audio-input` entitlement, so it says nothing about the
microphone path.

So: **not closed, not priced.** A port gated on a sandboxed end-to-end prototype, the dependency and
licence decision, the archive and IPC migration, and review. Nobody has measured it, and this item does
not claim to.

## Done means

A clean machine — no developer keychain, no Xcode, no `ffmpeg` — runs `brew install --cask` from the
tap, opens the app without a security exception, finds the menu-bar icon (there is no Dock presence),
grants both permissions, records a call and saves it. Denial and revocation tested separately, and an
upgrade from a previous signed artefact tested. A successful launch on the developer's own Mac with
grants already in place is weak evidence of any of this.

Signing and notary credentials stay outside the repository, and released artefacts follow the
accepted-`main`/tag rule.
