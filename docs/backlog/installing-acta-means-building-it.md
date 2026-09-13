---
worth: yes
where: Scripts/bundle.sh:129
added: 2026-09-13
---
# the only way to install Acta is to build it

To run Acta today you clone the repository, run `Scripts/bundle.sh`, and let `setup-signing.sh` mint a
self-signed certificate in a dedicated keychain. There is no route for someone who does not want a
compiler.

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
people to strip quarantine or click past Gatekeeper.

## What the release path actually involves

Not "swap the certificate". Hardened runtime, a secure timestamp, signing nested executable
components, notarization, and stapling the ticket — Apple's notarization troubleshooting page is the
list. Against that, the current build script:

- signs with no `--options runtime` and no `--timestamp`;
- ends with `codesign --verify --verbose=2 "$APP_DIR" || true`, so **verification cannot fail the
  build**. A release path needs that gate to be fatal, and the local dev path can keep its leniency.

Keep a separate dev identity and keep the production bundle identifier and requirement stable across
releases, or every release re-prompts for both permissions.

⚠️ **Do not promise from reasoning that every existing local-build user must re-grant.** Moving to a
Developer ID identity changes the requirement, and `AGENTS.md` documents that trap for the
ad-hoc→certificate switch — but which users on which OS versions actually re-prompt is a thing to
observe during a real upgrade, not to assert here.

## Homebrew is a delivery channel, not the trust mechanism

- Official `homebrew/cask` policy requires an artefact to pass its Gatekeeper checks without disabling
  or bypassing protections, and has shared acceptance criteria a new project cannot count on.
- Homebrew applies quarantine to cask downloads, so a cask does not route around the OS.
- A **personal tap** avoids the central tap's editorial acceptance, and can be the first channel — but
  "no criteria at all" is wrong: it still means the cask DSL, maintenance, and the same OS trust
  behaviour. Acceptance into the official tap need not block a first release.

What a cask genuinely buys here is `depends_on formula: "ffmpeg"`.

## `ffmpeg`, stated at its real size

`ffmpeg` is needed to assemble, not to record. Without it a recording runs to the end and fails at
assembly — and ⚠️ **nothing is lost**: the recovery marker stays `recording`, the segments are intact,
and installing `ffmpeg` and relaunching assembles the meeting (`RecordingController.swift:433`). The
first version of this item called it losing the meeting; it is not. What it is, is a stranger meeting
an error screen straight after their first real call, which is the worst moment to learn about a
dependency. That is an argument about first-run trust, and it favours a cask over a bare disk image.

⚠️ `SegmentAssembler.locateFFmpeg` tries `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, then
`PATH`. An app launched from Finder does not inherit the shell's environment, so the three fixed paths
carry more of the decision there than they do in a terminal — but the resolver still consults `PATH`,
and what it contains depends on the launch environment. That is a reason to test an **actual Finder
launch with the supported installation route**, not a reason to assert what a Finder `PATH` holds.

Bundling a licensed `ffmpeg` build is the alternative to declaring it; it adds third-party licensing,
signing and resolution work, so a cask is the smaller first scope.

## Also wrong in the metadata today

`Resources/Info.plist` declares `LSMinimumSystemVersion = 14.0`, while recording needs macOS 15
(`SCStreamConfiguration.captureMicrophone`) and everything under `MenuContent` is gated on 15. Building
and *usefully running* have different minimums, and a public artefact should advertise the recording
one in its own metadata as well as on any page or cask. Choose and test the CPU architectures
explicitly rather than inferring them from an OS minimum.

## Done means

A clean machine — no developer keychain, no Xcode, no `ffmpeg` — downloads the artefact through a real
quarantined path, opens it without a security exception, finds the menu-bar icon (there is no Dock
presence), grants both permissions, records a call and saves it. Denial and revocation tested
separately, and an upgrade from a previous signed artefact tested. A successful launch on the
developer's own Mac with grants already in place is weak evidence of any of this.

Signing and notary credentials stay outside the repository, and released artefacts follow the
accepted-`main`/tag rule.

## The open decision

Whether to fund Developer ID membership. Everything above is downstream of it, which is why this item
names it rather than comparing packaging formats.
