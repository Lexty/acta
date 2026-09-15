---
name: mic-activity-detection
description: Detect when another app starts or stops using the microphone on macOS (CoreAudio process objects) and identify which app. Use for AudioProcessReader / MicrophoneActivityRule / MicrophoneOwnershipRule — the "offer to record" prompt and the owner-release stop offer.
---

# Detecting microphone activity by other apps

> The source of truth is Apple's docs (links below). Below are verified facts and the gotchas that
> will bite. Check exact API signatures against the docs — do not invent them.

## Goal
Notice that some app (Slack, Teams, Meet in a browser, …) started listening to the microphone —
i.e. a call likely began — and offer to start recording. And, for a recording started from that
offer, notice that the same app let the input go and offer to stop. This is the same signal that
drives the orange microphone indicator in the macOS menu bar. ⚠️ It says a process runs input IO, not
that a meeting started or ended.

## Approach A (preferred, macOS 14+): who is using the mic
- `kAudioHardwarePropertyProcessObjectList` — enumerate audio process objects (`AudioObjectID`s).
- Per process object:
  - `kAudioProcessPropertyPID` — the process PID (**added in macOS SDK 14.0**).
  - `kAudioProcessPropertyIsRunningInput` — whether that process is running audio **input**.
  - `kAudioProcessPropertyBundleID` — the durable key. **Read it from the HAL, not from
    `NSRunningApplication`**: measured 2026-09-12, 29 of 32 process objects carried one, including
    processes `NSRunningApplication` cannot resolve (`com.apple.CoreSpeech`). A Slack huddle is held by
    `com.tinyspeck.slackmacgap.helper`, with a bundle id and no display name.
- `NSRunningApplication(processIdentifier:)` → `localizedName` is for the prompt text only, and only for
  an `activationPolicy == .regular` app. A missing name must never discard a valid HAL key.
- ⚠️ `kAudioProcessPropertyPID` (`'ppid'`) is the process's **own** pid, not a parent pid.

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
4. **Acta's own capture is not Acta's pid.** Acta captures through ScreenCaptureKit, and the HAL
   reports the input holder as **`com.apple.replayd`** — matched to Acta's log to the millisecond.
   Filtering Acta's own pid does nothing for it; what stops a self-triggered start offer is the
   rule's `isBusy` guard, after the key is spent. ⚠️ **Do not add `replayd` to the own-bundle list**:
   every ScreenCaptureKit client appears as replayd.
5. **Debounce, in both directions.** Many apps touch the mic for a moment (Siri, a browser tab probing
   devices). The start rule qualifies after `microphoneActivityHold` (3 s) of observed holding. A
   *release* flaps too: every measured Slack join was followed within 1.4–2.4 s by a release and
   re-acquisition (the pre-join dialog ending), with observed gaps of 266–834 ms. Those are intervals
   between polled states, not physical durations — **do not tune a threshold to them**.
6. **Permissions.** Reading device/process metadata is not the same as capturing audio; verify
   empirically whether this works before Microphone TCC is granted — do not assume either way.
7. **`com.apple.CoreSpeech` holds the input persistently** on the measured machine. Any rule that
   needs "exactly one holder", or that treats "another app still holds the input" as meaningful, is
   broken by it. The ownership rule looks only at the bound owner's own evidence.
8. **Unknown is never released.** An unreadable property or a partial process list must reset a
   release interval, not advance it. The owner absent from a *complete* enumeration is a release (that
   is what quitting looks like); absent from an incomplete one is unknown.

## Release: did the owner let go (`MicrophoneOwnershipRule`)
- Only a recording started from a start offer is bound (`OwnerBinding`), to that offer's **bundle**
  key. Menu and socket starts, and pid-only holders, are never bound — inferring an owner can bind a
  microphone test and stop a live call.
- `held → releaseCandidate → releasedQualified`, plus `unknown`. Qualified means released observations
  spanning 5 s with no gap over 2.5 s between them; unknown or a gap revokes; the owner returning needs
  a full new interval. ⚠️ **Never infer a release from the start rule's `!isEpisodeActionable`** — that
  predicate carries prompt history, not owner evidence.
- Production polls at 1 Hz (`ReminderCoordinator.pollInterval`), one snapshot per tick feeding both
  rules through one reduction (`AudioProcessReadings`). A sub-second re-acquisition can fall between
  samples; that limit is stated, not solved.
- Test against the recorded traces replayed at several 1 Hz phase offsets
  (`MicrophoneOwnershipFixtures`), not against a one-holder fake.

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
