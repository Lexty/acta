// One uninterrupted trace of who holds microphone input, and when they let go.
//
// Run it: `swift Scripts/trace-microphone-ownership.swift` — then perform the scenario (join a call,
// mute, leave, rejoin) while it runs. Only transitions are printed, so a quiet five minutes is five
// lines.
//
// ⚠️ **Why a trace and not a snapshot.** `probe-audio-process-objects.swift` answers "who holds it
// now". The questions that decide the per-application autonomy design in
// `docs/backlog/per-application-autonomy-modes.md` are about *edges*: does leaving a call release the
// input, does muting, does the holder survive between calls. Only a continuous trace answers those,
// and the first attempt to answer them from two snapshots missed the finding below entirely.
//
// ⚠️ **A partial enumeration can never establish a release.** An object missing from an incomplete
// list is not evidence that it stopped — so completeness is checked on every sample and an incomplete
// one prints `!` and concludes nothing. A release is also reported with *which kind* it was: the
// object still present with input false, or the object gone from a complete list. Those are different
// facts and a design that conflates them will mis-handle a process that quit.
//
// ⚠️ **The sampling interval is a floor on what can be seen, not a measurement of the signal.** At
// 250 ms, a release and re-acquisition inside one interval is invisible. Measured on 2026-09-12 with
// Slack 4.52.155 on macOS 26.6.2: every huddle join was followed within 1.4–2.4 s by a release and
// re-acquisition lasting ~270 ms — the same order as the interval, so shorter flaps may exist and go
// unseen. Anything built on this signal must qualify a release as "false continuously for N", never as
// "a sample said false", or it will stop a recording two seconds into a call.
//
// Also measured in that run, and both are load-bearing: muting does **not** release the input (Slack
// keeps the stream and stops sending), and the helper is **not** restarted between calls — the same
// pid and process-object id across two huddles. Recurrence across an application *restart* is still
// unmeasured, and that is the case that decides whether a pid may ever be used as a policy key.

import AppKit
import CoreAudio
import Foundation

// One uninterrupted trace of microphone input ownership.
// ⚠️ A *partial* enumeration can never establish a release: an object that vanished from an incomplete
// list is not evidence it stopped. So completeness is recorded on every sample, and a release is only
// called one when the enumeration that showed it was complete.

let interval: UInt32 = 250_000            // 250 ms
let duration: TimeInterval = 300

struct Holder: Hashable { let bundle: String; let pid: Int32; let object: UInt32 }

func enumerate() -> (holders: [Holder], present: Set<UInt32>, complete: Bool, errors: Int) {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size) == noErr, size > 0 else {
        return ([], [], false, 1)
    }
    let stride = MemoryLayout<AudioObjectID>.stride
    guard Int(size) % stride == 0 else { return ([], [], false, 1) }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
    var returned = size
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                     0, nil, &returned, &ids) == noErr, returned == size else {
        return ([], [], false, 1)
    }
    var holders: [Holder] = []
    var errors = 0
    for object in ids {
        var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var pidSize = UInt32(MemoryLayout<Int32>.size); var pid: Int32 = -1
        if AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) != noErr { errors += 1 }

        var runAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var runSize = UInt32(MemoryLayout<UInt32>.size); var running: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &runAddress, 0, nil, &runSize, &running) == noErr else {
            errors += 1; continue
        }
        guard running != 0 else { continue }

        var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        var bundleSize = UInt32(MemoryLayout<CFString?>.size); var bundle: CFString?
        let status = withUnsafeMutablePointer(to: &bundle) {
            AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, $0)
        }
        let name = (status == noErr ? (bundle as String?) : nil) ?? "<none>"
        holders.append(Holder(bundle: name, pid: pid, object: object))
    }
    return (holders, Set(ids), true, errors)
}

let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
if let slack = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.tinyspeck.slackmacgap" }) {
    let plist = slack.bundleURL?.appendingPathComponent("Contents/Info.plist")
    let version = plist.flatMap { NSDictionary(contentsOf: $0)?["CFBundleShortVersionString"] as? String }
    print("Slack \(version ?? "<unknown>") pid \(slack.processIdentifier)")
} else {
    print("Slack is not running")
}
print("sampling every 250 ms for \(Int(duration)) s; transitions only; ± marks acquire/release")
print("a release is only reported from a COMPLETE enumeration")

var previous: Set<Holder> = []
var previousObjects: Set<UInt32> = []
var started = false
let deadline = Date().addingTimeInterval(duration)
while Date() < deadline {
    let (holders, present, complete, errors) = enumerate()
    guard complete else {
        print("\(formatter.string(from: Date()))  ! incomplete enumeration — nothing concluded")
        usleep(interval); continue
    }
    let now = Set(holders)
    if !started {
        print("\(formatter.string(from: Date()))  = baseline: "
              + (now.isEmpty ? "nothing holding" : now.map { "\($0.bundle)#\($0.pid)" }.sorted().joined(separator: ", ")))
        started = true
    } else if now != previous {
        for h in now.subtracting(previous).sorted(by: { $0.pid < $1.pid }) {
            print("\(formatter.string(from: Date()))  + \(h.bundle) pid=\(h.pid) object=\(h.object)")
        }
        for h in previous.subtracting(now).sorted(by: { $0.pid < $1.pid }) {
            let gone = !present.contains(h.object)
            print("\(formatter.string(from: Date()))  - \(h.bundle) pid=\(h.pid) object=\(h.object) "
                  + (gone ? "(object disappeared)" : "(object present, input now false)"))
        }
    }
    if errors > 0 { print("\(formatter.string(from: Date()))  ! \(errors) property read error(s)") }
    previous = now
    previousObjects = present
    usleep(interval)
}
print("\(formatter.string(from: Date()))  = end: "
      + (previous.isEmpty ? "nothing holding" : previous.map { "\($0.bundle)#\($0.pid)" }.sorted().joined(separator: ", ")))
