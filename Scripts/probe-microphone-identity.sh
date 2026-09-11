#!/usr/bin/env bash
# The live microphone-identity divergence probe, run deliberately.
#
# Acta's whole microphone-priority design rests on one equality that Apple documents nowhere as a
# single identity: `kAudioDevicePropertyDeviceUID` (CoreAudio) and `AVCaptureDevice.uniqueID` are the
# same string, which is what lets a UID read from the HAL be handed to
# `SCStreamConfiguration.microphoneCaptureDeviceID`. It was measured, once, on one machine. This probe
# takes two independent live observations of *this* machine and compares them.
#
# It runs as part of `bash Scripts/test.sh` too — this script exists so a human can run it on its own
# (after a macOS upgrade, or with a particular headset paired) and read the verdict.
#
# ⚠️ What it can and cannot say:
#   - it detects divergence on the devices THIS machine currently exposes;
#   - a device that is not plugged in is not checked, and reports as a visible SKIP, never a pass;
#   - it says nothing about whether ScreenCaptureKit actually captured the intended microphone —
#     that needs ears, and stays in manual acceptance.
#
# Result categories, printed per device:
#   agreed     — corresponded across the APIs (by role, or by a name unique on both sides) and the
#                two identities are the same string
#   DIVERGENT  — corresponded, and the identities differ. The failure this probe exists for
#   unmatched  — could not be corresponded (an ambiguous name, or listed by one API only). Missing
#                coverage, not a failure — but if NOTHING corresponded the verdict is `inconclusive`
#                and the run fails, because a comparison of nothing is not agreement
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export ACTA_PROBE_VERBOSE=1
exec bash Scripts/test.sh --filter 'MicrophoneIdentityProbeTests' "$@"
