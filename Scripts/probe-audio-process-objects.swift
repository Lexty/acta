// Who is holding the microphone, and by what key — read straight from the HAL.
//
// Run it: `swift Scripts/probe-audio-process-objects.swift`
//
// ⚠️ **Why this exists.** The per-application autonomy proposal in
// `docs/backlog/per-application-autonomy-modes.md` rests entirely on there being a *durable* key to
// remember a mode against. Whether there is one had been argued from an absent display name, which is
// unsound — `AudioProcessProjection.resolveNames` returns nil when the pid does not resolve to an
// `NSRunningApplication`, when `localizedName` is absent, **or** when the activation policy is not
// `.regular`, and only the last of those means "a helper". This prints the three facts separately so
// nobody has to infer one from another again.
//
// ⚠️ **What it can and cannot say.** It describes *this* machine at *this* instant. An application not
// running is not listed; an application running but not holding the input shows `-` under `input`. To
// answer "what does a Slack huddle look like", the huddle has to be live while this runs. Whether a
// bundle identifier is ever absent is **not documented by Apple** — `kAudioProcessPropertyBundleID` is
// described only as "a CFString containing the bundle id of the process" — so an empty column here is
// an observation, never a contract.
//
// Measured on 2026-09-12, macOS 15, 32 process objects: 29 carried a bundle identifier, including
// several that `NSRunningApplication` could not resolve at all. Chrome appeared three times — the app
// plus two helpers, both reporting `com.google.Chrome.helper`. `com.apple.CoreSpeech` was holding the
// input continuously, which is a system speech service and not a meeting.

import CoreAudio
import Foundation
import AppKit

func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                     0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value as String
}

func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Int32>.size)
    var value: Int32 = 0
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func bool(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value != 0
}

let processes = objects(kAudioHardwarePropertyProcessObjectList)
print("process objects: \(processes.count)")
print(String(format: "%-8@ %-7@ %-42@ %-28@ %@", "pid" as NSString, "input" as NSString,
             "bundleID" as NSString, "process name" as NSString, "policy" as NSString))
for object in processes {
    let pid = int32(object, kAudioProcessPropertyPID)
    let bundle = string(object, kAudioProcessPropertyBundleID)
    let running = bool(object, kAudioProcessPropertyIsRunningInput)
    var name = "<unresolved>"
    var policy = "-"
    if let pid, pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
        name = app.localizedName ?? "<no localizedName>"
        switch app.activationPolicy {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "?"
        }
    }
    let flag = running.map { $0 ? "INPUT" : "-" } ?? "?"
    print(String(format: "%-8d %-7@ %-42@ %-28@ %@", pid ?? -1, flag as NSString,
                 (bundle ?? "<none>") as NSString, name as NSString, policy as NSString))
}
