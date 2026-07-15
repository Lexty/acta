---
name: mic-activity-detection
description: Detect when another app starts using the microphone on macOS (CoreAudio process objects) and identify which app. Use for MicActivityMonitor / the "offer to record" prompt.
---

# Detecting microphone activity by other apps

> The source of truth is Apple's docs (links below). Below are verified facts and the gotchas that
> will bite. Check exact API signatures against the docs — do not invent them.

## Goal
Notice that some app (Slack, Teams, Meet in a browser, …) started listening to the microphone —
i.e. a call likely began — and offer to start recording. This is the same signal that drives the
orange microphone indicator in the macOS menu bar.

## Approach A (preferred, macOS 14+): who is using the mic
- `kAudioHardwarePropertyProcessObjectList` — enumerate audio process objects (`AudioObjectID`s).
- Per process object:
  - `kAudioProcessPropertyPID` — the process PID (**added in macOS SDK 14.0**).
  - `kAudioProcessPropertyIsRunningInput` — whether that process is running audio **input**.
- Map PID → `NSRunningApplication(processIdentifier:)` → `localizedName` / `bundleIdentifier`
  for the notification text and for the ignore list.

## Approach B (fallback): is the mic used at all
- `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device — tells you the mic is
  in use, but **not by whom**.

## Gotchas (these will bite)
1. **Listeners for `IsRunningInput` are unreliable.** Developers report callbacks arriving for
   `kAudioProcessPropertyIsRunning` and `kAudioProcessPropertyDevices` but **not** consistently for
   `kAudioProcessPropertyIsRunningInput`/`IsRunningOutput`. Do not rely on a listener alone:
   listen on `kAudioHardwarePropertyProcessObjectList` (+ `kAudioProcessPropertyIsRunning`) **and**
   poll `IsRunningInput` on a light timer (e.g. every 1–2 s). Polling is cheap; a missed call is not.
2. **Bluetooth microphones do not report accurately** via
   `kAudioDevicePropertyDeviceIsRunningSomewhere` (internal and wired mics are fine). Another reason
   to prefer Approach A.
3. **Swift bug with `AudioObjectRemovePropertyListenerBlock`** — if you need to remove a listener,
   use `AudioObjectPropertyListenerProc` instead of the block-based API.
4. **Exclude Acta itself.** Acta opens the microphone while recording; without filtering its own PID
   the monitor would trigger on its own recording.
5. **Debounce.** Many apps touch the mic for a moment (Siri, a browser tab probing devices). Only
   treat it as a real session when input stays active for a dwell period (≥ 5 s).
6. **Permissions.** Reading device/process metadata is not the same as capturing audio; verify
   empirically whether this works before Microphone TCC is granted — do not assume either way.

## Sketch (verify against the docs)
```swift
// enumerate process objects
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
// AudioObjectGetPropertyDataSize + AudioObjectGetPropertyData -> [AudioObjectID]
// per object: kAudioProcessPropertyPID -> pid_t, kAudioProcessPropertyIsRunningInput -> UInt32
```

## References
- kAudioHardwarePropertyProcessObjectList: https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyprocessobjectlist
- Detect when a microphone is being used (forum thread, incl. the listener caveat): https://developer.apple.com/forums/thread/741026
- Detect if other apps are using the microphone (forum thread): https://developer.apple.com/forums/thread/49703
