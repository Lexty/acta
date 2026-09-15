import ActaKit
import Foundation

/// What the OS told us about the input devices, or that it refused to say.
///
/// ⚠️ **A failure is not an empty list, and collapsing the two is the bug this enum exists to prevent.**
/// An adapter that swallows the `OSStatus` and returns `[]` reports "this machine has no microphones"
/// with the same value it would use for a machine that genuinely has none — and every consumer above
/// then behaves as though it had *looked* and found nothing. That is the same class of error as the
/// recovery scan's `unscannable`: "I could not look" is not "there was nothing to find".
public enum DeviceEnumeration: Equatable, Sendable {
    /// The devices that could be described, plus **what could not be**.
    ///
    /// ⚠️ `uninspectable` is not decoration. Walking past a driver that will not answer is the right
    /// call — one broken virtual device must not blind the feature to every real microphone — but a
    /// snapshot that omits it *silently* is indistinguishable from one where the device genuinely left.
    /// Consumers above read a departure as a disconnect: they expire a temporary override on it and
    /// fail a recording over it. So the omission is reported, and a consumer may decline to act
    /// destructively on an incomplete snapshot.
    case devices([AudioInputDevice], uninspectable: [String])
    case failed(reason: String)
}

/// The current system default input, or the OS declining to say.
public enum DefaultInputRead: Equatable, Sendable {
    case device(uid: String)
    /// The OS answered, and there is no default input device. A real state (no input hardware at all),
    /// distinct from the query failing.
    case none
    case failed(reason: String)
}

/// The result of writing `kAudioHardwarePropertyDefaultInputDevice`.
///
/// ⚠️ `written` means **the write call succeeded**, not that the default is now that device. The two
/// differ whenever something else is competing for the property, which is the entire premise of the
/// reconciler — hence its separate verification read.
public enum DefaultInputWrite: Equatable, Sendable {
    case written
    /// The uid names no device the directory currently knows.
    case unknownDevice(uid: String)
    case failed(reason: String)
}

/// A change worth re-reading the world for.
///
/// ⚠️ **`readinessChanged` is not redundant with `deviceListChanged`.** A device can stop being usable
/// — or start being usable — while the device list is byte-for-byte identical, and a directory that
/// watches only the list will never report it. Presence is not availability.
public enum DeviceChange: Equatable, Sendable {
    case deviceListChanged
    case defaultInputChanged
    case readinessChanged(uid: String)
    /// Observation is **partially** working: the subscription is live, but some changes will not be
    /// reported. Emitted when a per-device listener could not be installed.
    ///
    /// ⚠️ Without this case the degradation is invisible in the worst possible way: `observe` returned
    /// success, events keep arriving for everything that *did* register, and the gap is exactly the
    /// transition the missing listener existed to catch. A consumer that receives this should stop
    /// trusting change notification alone and fall back to re-reading on its other triggers.
    case observationDegraded(reason: String)
}

/// A live subscription. Cancelling one **must not** end any other subscription — see
/// `AudioDeviceDirectory.observe`.
public protocol AudioDeviceObservation: AnyObject, Sendable {
    func cancel()
}

/// The result of subscribing.
///
/// ⚠️ **`failed` is a third outcome, and it is the one that hides.** A directory whose listener
/// registration failed looks exactly like a machine where nothing is happening: no events, no error,
/// no difference. Everything above must be able to tell "subscribed, and the machine is quiet" from
/// "never subscribed, and I would not know either way".
public enum ObservationOutcome: Sendable {
    case observing(any AudioDeviceObservation)
    case failed(reason: String)
}

/// The audio-device seam: everything the microphone-priority feature needs from CoreAudio, and nothing
/// else. It owns **only** device enumeration, the system-default input property, and change
/// notification — it knows nothing about priorities, recordings or the menu.
///
/// The contract, honoured by every implementation (a fake that breaks any of it is worse than no fake
/// at all):
///
/// - **every operation reports failure explicitly**; no operation may express "the OS refused" as an
///   ordinary value (`[]`, `false`, "no default");
/// - **observation is broadcast.** More than one consumer subscribes — the reconciler and the
///   recording-side observer — and they are independent: every subscriber receives every change, and
///   cancelling one subscription leaves the others delivering. A single-consumer stream would make the
///   two compete, and whichever subscribed second would silently win or lose depending on
///   implementation detail;
/// - **a handler may be called from any thread**, at any time between subscribing and `cancel()`
///   returning. Consumers serialize for themselves; the directory promises delivery, not a queue;
/// - **`cancel()` is idempotent**, and after it returns that subscription's handler is not called
///   again.
///
/// There is deliberately **no `preferredDevice()` or `reconcile()`**. The decision is a pure function
/// over a snapshot (`ActaKit`), and the policy that applies it is the reconciler; pushing either down
/// here would put untestable judgement behind a HAL call.
/// Everything about the audio devices that can be **learned**, and nothing that changes them.
///
/// ⚠️ **The split is structural, not decorative.** A recording needs to know which microphones exist
/// and which one the system prefers; it has no business moving the Mac's default input, and feature
/// (B) is opt-in precisely because that write affects every other application on the machine.
/// `MicrophoneManager` hands out this half; only the reconciler it owns holds the other.
///
/// ⚠️ **It narrows what is reachable by accident; it is not a capability guarantee, and an earlier
/// version of this comment said otherwise.** Both protocols are public in one target and the object
/// handed out still conforms to `AudioDeviceDirectory`, so a caller determined to cast it back can.
/// "A recording never enforces and never constructs a reconciler" stays a composition rule kept by
/// review — see the seam amendment in `CLAUDE.md`.
public protocol AudioDeviceReading: AnyObject, Sendable {
    /// Every input-capable device the OS currently lists.
    ///
    /// ⚠️ Hidden devices are **out of scope by design**: `kAudioDevicePropertyIsHidden`
    /// (`AudioHardwareBase.h:717`) documents that they are absent from the normal device list and
    /// cannot become the default device. Do not add a hidden-device path here.
    func enumerateInputDevices() -> DeviceEnumeration

    /// Read `kAudioHardwarePropertyDefaultInputDevice`.
    func currentDefaultInput() -> DefaultInputRead

    /// Subscribe to changes. Independent of every other subscription — see the contract above.
    func observe(_ handler: @escaping @Sendable (DeviceChange) -> Void) -> ObservationOutcome
}

public protocol AudioDeviceDirectory: AudioDeviceReading {
    /// Write `kAudioHardwarePropertyDefaultInputDevice`.
    ///
    /// ⚠️ The caller must re-read before writing and verify after: this call reports what the OS said
    /// about the *write*, and says nothing about what the property holds a moment later.
    func setDefaultInput(uid: String) -> DefaultInputWrite
}
