import Foundation

/// How a device is attached. A **pure** mirror of CoreAudio's transport constants: the HAL four-CC is
/// translated once, in the adapter, so nothing above it needs `kAudioDeviceTransportType*` — and so
/// this enum can be reasoned about in `ActaKit`, which may not import CoreAudio.
///
/// ⚠️ **`bluetooth` and `bluetoothLE` are two constants, not one.** `AudioHardwareBase.h` defines
/// `'blue'` (line 616) and `'blea'` (line 617) separately, so every "is this wireless?" question asked
/// against one of them alone has a hole. Ask `AudioInputDevice.isBluetooth` instead of matching a case,
/// which is why that property exists at all.
public enum AudioTransport: Equatable, Sendable {
    case builtIn
    case usb
    case bluetooth
    case bluetoothLE
    case virtual
    case aggregate
    case continuityWired
    case continuityWireless
    case thunderbolt
    case pci
    case fireWire
    case hdmi
    case displayPort
    case airPlay
    case avb
    /// A transport this build does not name, carrying the raw four-CC so a log can identify it.
    /// Deliberately not an error: an unknown transport is an ordinary device, not a broken one.
    case other(UInt32)
}

/// The answer to a yes/no question the OS may decline to answer.
///
/// ⚠️ **`unknown` exists because `false` is a lie here, and the lie has already been observed.**
/// `kAudioDevicePropertyDeviceCanBeDefaultDevice` returns `kAudioHardwareUnknownPropertyError` when it
/// is queried in the global scope instead of the input scope; a helper that ignores the `OSStatus` and
/// returns its zero-initialised buffer then reports "no" for **every device on the machine**, and a
/// filter built on that rejects the entire machine while looking like a normal empty result. Keeping
/// the third case is what makes that failure representable instead of silent.
public enum DeviceCapability: Equatable, Sendable {
    case yes
    case no
    /// The query failed. **Not** `no`.
    case unknown
}

/// One input-capable audio device, as everything above the HAL sees it.
///
/// **Identity is the `uid` and only the `uid`.** The HAL's own `AudioObjectID` is deliberately absent:
/// it is ephemeral, and this was measured rather than assumed — reconnecting one headset moved it from
/// `140` to `181` while the UID stayed byte-identical. Letting the integer escape the adapter would
/// invite exactly the bug the measurement rules out.
///
/// The `uid` is also the string ScreenCaptureKit wants for
/// `SCStreamConfiguration.microphoneCaptureDeviceID`, which is documented as an `AVCaptureDevice`
/// `uniqueID`. That the two are the same string is **measured, not a documented contract** — see the
/// live divergence probe, which is what will fail if a future macOS separates them.
public struct AudioInputDevice: Equatable, Sendable, Identifiable {
    /// The persistent identifier (`kAudioDevicePropertyDeviceUID`), stable across boots and reconnects.
    public var uid: String
    /// The display name (`kAudioObjectPropertyName`). For humans only — **never** for identity:
    /// two devices may share a name, and a rename must not orphan a priority entry.
    public var name: String
    public var transport: AudioTransport
    /// Channels on the **input** scope. Zero means this is not an input device at all.
    public var inputChannels: Int
    /// Whether the OS will accept this device as the **system default input**.
    /// ⚠️ This is *not* the same question as "can Acta capture it" — see `isCaptureCandidate`.
    public var canBeSystemDefault: DeviceCapability
    /// `kAudioDevicePropertyDeviceIsAlive`. A device can stop being usable without leaving the device
    /// list, which is why presence alone is not availability.
    ///
    /// ⚠️ **Tri-state for the same reason `canBeSystemDefault` is.** A liveness read that *failed* must
    /// not arrive as `yes`: consumers above treat "not alive" as a disconnect, so a transient read
    /// failure reported as a definite answer would expire a temporary override or fail a recording over
    /// nothing. Deciding to use an uncertain device is a policy; reporting it as *known* alive is a lie.
    public var isAlive: DeviceCapability
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` — some process currently has it open. Reported
    /// for diagnosis; it never affects selection, because "in use" is not "unavailable" on macOS.
    public var isRunningSomewhere: Bool

    public init(uid: String,
                name: String,
                transport: AudioTransport,
                inputChannels: Int,
                canBeSystemDefault: DeviceCapability,
                isAlive: DeviceCapability,
                isRunningSomewhere: Bool) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.inputChannels = inputChannels
        self.canBeSystemDefault = canBeSystemDefault
        self.isAlive = isAlive
        self.isRunningSomewhere = isRunningSomewhere
    }

    public var id: String { uid }

    /// Wireless over Bluetooth, by **either** transport constant. The one place that distinction is
    /// made, so no caller can reintroduce the `'blea'` hole by matching `.bluetooth` alone.
    public var isBluetooth: Bool {
        transport == .bluetooth || transport == .bluetoothLE
    }

    /// A real microphone rather than a software endpoint. Loopback drivers, aggregates and virtual
    /// devices are excluded: they carry audio, they do not hear a room.
    ///
    /// ⚠️ Deliberately **not** derived from `canBeSystemDefault`. That was measured to be a different
    /// question: on this machine BlackHole and the aggregate device both report *yes* to it while being
    /// exactly the kind of software endpoint this property excludes.
    public var isPhysical: Bool {
        switch transport {
        case .virtual, .aggregate: return false
        default: return true
        }
    }

    /// Usable at all: present, not known-dead, and actually carrying input channels.
    ///
    /// ⚠️ **Presence is not availability**, which is why `isAlive` is consulted here. A device can stay
    /// in `kAudioHardwarePropertyDevices` after it has stopped working, and a directory that watches
    /// only the device *list* will never see that transition.
    ///
    /// ⚠️ **`unknown` liveness counts as available**, matching `isSystemDefaultCandidate`'s optimism and
    /// for the same reason: a machine whose liveness property stops answering must not become a machine
    /// with no microphones. The uncertainty is preserved in the value so a caller that needs to *report*
    /// it still can — this property answers "may I use it", not "is it definitely there".
    public var isAvailable: Bool {
        isAlive != .no && inputChannels > 0
    }

    /// Whether Acta may record from it. Availability alone — **`canBeSystemDefault` is not consulted**,
    /// because it answers whether the OS will make the device the system default, which is a different
    /// question from whether ScreenCaptureKit can capture it.
    public var isCaptureCandidate: Bool { isAvailable }

    /// Whether the reconciler may write it into `kAudioHardwarePropertyDefaultInputDevice`.
    ///
    /// ⚠️ **`unknown` counts as eligible, and that is a decision.** Treating a failed capability query
    /// as "ineligible" is what turns one broken property read into a machine with no selectable
    /// microphone at all — the precise shape of the scope bug this type's `DeviceCapability` exists to
    /// represent. Being optimistic instead costs at most one failed write, which is visible, bounded by
    /// the reconciler's conflict budget, and reported; being pessimistic costs the whole feature and
    /// says nothing.
    public var isSystemDefaultCandidate: Bool {
        isAvailable && canBeSystemDefault != .no
    }
}
