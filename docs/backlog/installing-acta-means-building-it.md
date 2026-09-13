---
worth: yes
where: Scripts/setup-signing.sh:44
added: 2026-09-13
---
# the only way to install Acta is to build it, and that is an identity problem, not a packaging one

To run Acta today you clone the repository, run `Scripts/bundle.sh`, and let `setup-signing.sh` mint a
self-signed certificate in a dedicated keychain. That certificate is what makes the TCC grants stick:
it gives the bundle a designated requirement that survives a rebuild. It works because **the machine
that signs is the machine that runs**.

That is exactly why it does not travel. A downloaded `.app` carrying someone else's self-signed
certificate is, to Gatekeeper, unsigned: it arrives quarantined, and on recent macOS opening it at all
means a trip through System Settings → Privacy & Security. So the obvious answers relocate the problem
rather than solve it — a Homebrew cask, a `.dmg` on a page, a release asset all deliver the same
unopenable bundle.

The chain that actually ends in "download it and it runs" is:

1. a **Developer ID Application** certificate, which requires paid Apple Developer Program membership;
2. **notarization** of the built artefact, and **stapling** the ticket to it;
3. only then a distribution channel, which at that point is the easy part.

⚠️ **The cost decision is the whole item.** Steps 2 and 3 are mechanical and cheap; step 1 is an
annual fee and an account. Nothing downstream can be evaluated before that is decided, which is why
this item names it first instead of comparing packaging formats.

## What is specific to this app, and would be missed by generic packaging advice

- **The TCC grant moves with the identity.** Screen Recording and Microphone are bound to the
  designated requirement, so switching to a Developer ID identity changes it once, for everyone, and
  anyone who had built locally re-grants both. `AGENTS.md` already documents this trap for the
  ad-hoc→certificate switch; distribution is the same event at a larger scale, and it wants a sentence
  in the release notes rather than a support thread.
- **Screen Recording is an alarming thing to ask a stranger for.** Someone who built from source has
  read why; someone who downloaded an app has not. Whatever fronts the download has to say that system
  audio on macOS is captured through ScreenCaptureKit and that this is what the permission is for,
  before the prompt appears rather than after.
- **macOS 14 builds it, macOS 15 records.** `SCStreamConfiguration.captureMicrophone` is 15+, and on 14
  the app launches and explains that recording is unavailable. That is a reasonable outcome for someone
  who compiled it and a bad one for someone who clicked Download, so the requirement belongs next to
  the button.
- **`ffmpeg` is needed to assemble, not to record.** Without it a recording runs to the end and then
  fails at assembly. ⚠️ **Nothing is lost** — the recovery marker stays `recording`, the segments are
  intact, and installing `ffmpeg` and relaunching assembles the meeting
  (`RecordingController.swift:433`). But the user meets an error screen immediately after their first
  real call, which is the worst possible moment to discover a dependency. A cask can declare
  `ffmpeg`; a bare disk image cannot. That is the strongest argument for Homebrew over a download link,
  and it is an argument about first-run trust rather than about data loss.

## Not established

- What the **official** `homebrew-cask` tap requires of software that is not notarized, and what its
  notability rules are. A **personal tap** (`brew tap Lexty/acta`) is believed to have no acceptance
  criteria and to be trivially served from this repository, which would make it the cheap first step —
  but that belief has not been checked against Homebrew's own documentation.
- Whether an unsigned cask can be installed without the user passing `--no-quarantine`, and whether
  that flag is acceptable to ask of anyone.

Settle those two before choosing a channel; neither changes the conclusion that step 1 gates everything.
