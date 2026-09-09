import ActaKit
import CoreAudio
import Foundation
import os

/// The one and only CoreAudio HAL integration, mirroring `SCKCaptureSource`'s role for
/// ScreenCaptureKit: every `AudioObjectID`, every four-CC selector and every `OSStatus` lives here and
/// nowhere else, so the fakes above answer the questions production actually asks instead of bypassing
/// them. A `grep` guard keeps it that way (`coreAudioSymbolsAreConfinedToTheAdapter`).
///
/// **Nothing HAL-shaped escapes.** `AudioObjectID` in particular is ephemeral — measured, not assumed:
/// reconnecting one headset moved it from `140` to `181` while the UID stayed identical — so it is
/// resolved from the UID on every call rather than cached anywhere above.
public final class CoreAudioDeviceDirectory: AudioDeviceDirectory, @unchecked Sendable {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "AudioDevices")

    /// Serializes the subscriber registry and the HAL listener bookkeeping. Listener blocks fire on
    /// `listenerQueue`, `observe`/`cancel` arrive from callers, and both touch this state.
    private let lock = NSLock()
    private var subscribers: [UInt64: @Sendable (DeviceChange) -> Void] = [:]
    private var nextToken: UInt64 = 1
    /// Whether the two system-object listeners are installed. Registration is attempted on every
    /// `observe` and is idempotent; a failure is reported to that caller rather than remembered as a
    /// silent "no events".
    private var systemListenersInstalled = false
    /// Per-device liveness listeners, keyed by the device's HAL id. Presence in the device list is not
    /// availability, so a device that dies without leaving the list still has to produce a change.
    private var readinessListeners: [AudioObjectID: ReadinessListener] = [:]

    private let listenerQueue = DispatchQueue(label: "dev.personal.acta.audio.devices")

    /// A HAL failure carrying its readable reason. A named type rather than a bare `String` only
    /// because `Result` requires `Error`; the reason text is the payload that matters.
    private struct HALError: Error { let reason: String }

    private final class ReadinessListener {
        let uid: String
        let block: AudioObjectPropertyListenerBlock
        init(uid: String, block: @escaping AudioObjectPropertyListenerBlock) {
            self.uid = uid
            self.block = block
        }
    }

    /// One subscription. Cancelling it removes exactly one entry from the registry, leaving every other
    /// subscriber delivering — the broadcast half of the `AudioDeviceDirectory` contract.
    private final class Observation: AudioDeviceObservation, @unchecked Sendable {
        private let token: UInt64
        private weak var owner: CoreAudioDeviceDirectory?
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        init(token: UInt64, owner: CoreAudioDeviceDirectory) {
            self.token = token
            self.owner = owner
        }

        func cancel() {
            let alreadyCancelled = cancelled.withLock { state -> Bool in
                defer { state = true }
                return state
            }
            guard !alreadyCancelled else { return }
            owner?.removeSubscriber(token)
        }

        deinit { cancel() }
    }

    public init() {}

    deinit {
        // Best effort: the process is usually going away with us, but a directory that outlived its
        // subscribers must not leave HAL blocks pointing at freed state.
        removeAllListeners()
    }

    // MARK: - Enumeration

    public func enumerateInputDevices() -> DeviceEnumeration {
        let ids: [AudioObjectID]
        switch systemDeviceIDs() {
        case .success(let value): ids = value
        case .failure(let error): return .failed(reason: error.reason)
        }

        var devices: [AudioInputDevice] = []
        for id in ids {
            // A device that cannot be inspected is skipped rather than failing the whole enumeration:
            // one broken virtual driver must not blind the feature to every real microphone. The
            // *list* query failing is different, and is reported above as `.failed`.
            guard let device = describe(id) else { continue }
            guard device.inputChannels > 0 else { continue }
            devices.append(device)
        }
        return .devices(devices)
    }

    /// Read every field of one device. Returns `nil` only when the device cannot be identified at all —
    /// without a UID there is nothing above that could refer to it.
    private func describe(_ id: AudioObjectID) -> AudioInputDevice? {
        guard case .success(let uid) = stringProperty(id, kAudioDevicePropertyDeviceUID) else {
            log.info("Skipping device \(id, privacy: .public): no UID")
            return nil
        }
        let name: String
        if case .success(let value) = stringProperty(id, kAudioObjectPropertyName) {
            name = value
        } else {
            name = uid  // A nameless device is still selectable; the uid is a poor label, not a failure.
        }

        let channels = inputChannelCount(id)
        let transport = transportType(id)

        // ⚠️ The scope here is load-bearing and was measured. In `kAudioObjectPropertyScopeGlobal`
        // this selector returns `kAudioHardwareUnknownPropertyError` for *every* device; a helper that
        // ignored the status would then report "cannot be default" for the whole machine, and a filter
        // built on it would reject every microphone while looking like an ordinary empty result.
        let canBeDefault: DeviceCapability
        switch uint32Property(id, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                              scope: kAudioObjectPropertyScopeInput) {
        case .success(let value): canBeDefault = value != 0 ? .yes : .no
        case .failure(let error):
            log.info("canBeDefaultDevice unavailable for \(uid, privacy: .public): \(error.reason, privacy: .public)")
            canBeDefault = .unknown
        }

        let isAlive: Bool
        switch uint32Property(id, kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeInput) {
        case .success(let value): isAlive = value != 0
        // A device the OS lists but will not answer for is treated as alive: refusing to offer it
        // would repeat the whole-machine failure above in a second place.
        case .failure: isAlive = true
        }

        let isRunning: Bool
        switch uint32Property(id, kAudioDevicePropertyDeviceIsRunningSomewhere,
                              scope: kAudioObjectPropertyScopeGlobal) {
        case .success(let value): isRunning = value != 0
        case .failure: isRunning = false
        }

        return AudioInputDevice(uid: uid,
                                name: name,
                                transport: transport,
                                inputChannels: channels,
                                canBeSystemDefault: canBeDefault,
                                isAlive: isAlive,
                                isRunningSomewhere: isRunning)
    }

    // MARK: - The default input device

    public func currentDefaultInput() -> DefaultInputRead {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        guard status == noErr else {
            return .failed(reason: Self.describe(status: status))
        }
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return .none }
        guard case .success(let uid) = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else {
            return .failed(reason: "default input device \(deviceID) has no UID")
        }
        return .device(uid: uid)
    }

    public func setDefaultInput(uid: String) -> DefaultInputWrite {
        // Resolved fresh every time: the HAL id is ephemeral, so a cached one would eventually name a
        // different device — or nothing.
        guard let deviceID = resolve(uid: uid) else { return .unknownDevice(uid: uid) }
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var value = deviceID
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size), &value)
        guard status == noErr else {
            return .failed(reason: Self.describe(status: status))
        }
        return .written
    }

    private func resolve(uid: String) -> AudioObjectID? {
        guard case .success(let ids) = systemDeviceIDs() else { return nil }
        for id in ids {
            if case .success(let candidate) = stringProperty(id, kAudioDevicePropertyDeviceUID),
               candidate == uid {
                return id
            }
        }
        return nil
    }

    // MARK: - Observation

    public func observe(_ handler: @escaping @Sendable (DeviceChange) -> Void) -> ObservationOutcome {
        lock.lock()
        if !systemListenersInstalled {
            if let reason = installSystemListenersLocked() {
                lock.unlock()
                // Reported to this caller rather than remembered: a directory that failed to subscribe
                // is indistinguishable from a quiet machine, and the caller has to be able to tell.
                return .failed(reason: reason)
            }
            systemListenersInstalled = true
        }
        let token = nextToken
        nextToken += 1
        subscribers[token] = handler
        lock.unlock()

        refreshReadinessListeners()
        return .observing(Observation(token: token, owner: self))
    }

    private func removeSubscriber(_ token: UInt64) {
        lock.lock()
        subscribers.removeValue(forKey: token)
        let isLast = subscribers.isEmpty
        lock.unlock()
        // Only the last subscriber leaving tears the HAL listeners down — one consumer cancelling must
        // never end another's delivery.
        if isLast { removeAllListeners() }
    }

    private func broadcast(_ change: DeviceChange) {
        lock.lock()
        let handlers = Array(subscribers.values)
        lock.unlock()
        for handler in handlers { handler(change) }
    }

    /// Install the two system-object listeners. Returns a reason on failure, `nil` on success.
    /// Caller holds `lock`.
    private func installSystemListenersLocked() -> String? {
        var deviceListAddress = Self.address(kAudioHardwarePropertyDevices)
        let deviceListBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.refreshReadinessListeners()
            self.broadcast(.deviceListChanged)
        }
        let listStatus = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                            &deviceListAddress, listenerQueue,
                                                            deviceListBlock)
        guard listStatus == noErr else {
            return "device-list listener: \(Self.describe(status: listStatus))"
        }

        var defaultAddress = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.broadcast(.defaultInputChanged)
        }
        let defaultStatus = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                               &defaultAddress, listenerQueue,
                                                               defaultBlock)
        guard defaultStatus == noErr else {
            // Do not leave half a subscription installed: a directory reporting device-list changes but
            // never default-input changes is exactly the "unchanged winner, moved default" blind spot.
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &deviceListAddress, listenerQueue, deviceListBlock)
            return "default-input listener: \(Self.describe(status: defaultStatus))"
        }

        systemBlocks = (deviceList: deviceListBlock, defaultInput: defaultBlock)
        return nil
    }

    private var systemBlocks: (deviceList: AudioObjectPropertyListenerBlock,
                               defaultInput: AudioObjectPropertyListenerBlock)?

    /// Keep one liveness listener per present device. Without these, a device that dies **without
    /// leaving the device list** produces no notification at all, and the snapshot above goes stale
    /// while looking current.
    private func refreshReadinessListeners() {
        guard case .success(let ids) = systemDeviceIDs() else { return }
        var present: [AudioObjectID: String] = [:]
        for id in ids {
            if case .success(let uid) = stringProperty(id, kAudioDevicePropertyDeviceUID) {
                present[id] = uid
            }
        }

        lock.lock()
        let known = Set(readinessListeners.keys)
        let wanted = Set(present.keys)
        let toAdd = wanted.subtracting(known)
        let toRemove = known.subtracting(wanted)
        var removals: [(AudioObjectID, ReadinessListener)] = []
        for id in toRemove {
            if let listener = readinessListeners.removeValue(forKey: id) { removals.append((id, listener)) }
        }
        lock.unlock()

        for (id, listener) in removals {
            var address = Self.address(kAudioDevicePropertyDeviceIsAlive,
                                       scope: kAudioObjectPropertyScopeInput)
            AudioObjectRemovePropertyListenerBlock(id, &address, listenerQueue, listener.block)
        }

        for id in toAdd {
            guard let uid = present[id] else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.broadcast(.readinessChanged(uid: uid))
            }
            var address = Self.address(kAudioDevicePropertyDeviceIsAlive,
                                       scope: kAudioObjectPropertyScopeInput)
            let status = AudioObjectAddPropertyListenerBlock(id, &address, listenerQueue, block)
            guard status == noErr else {
                // Not fatal: the device-list listener still fires, so the loss is a readiness
                // transition, not the whole feature. Logged rather than silent.
                log.info("No readiness listener for \(uid, privacy: .public): \(Self.describe(status: status), privacy: .public)")
                continue
            }
            lock.lock()
            readinessListeners[id] = ReadinessListener(uid: uid, block: block)
            lock.unlock()
        }
    }

    private func removeAllListeners() {
        lock.lock()
        let blocks = systemBlocks
        systemBlocks = nil
        systemListenersInstalled = false
        let readiness = readinessListeners
        readinessListeners.removeAll()
        lock.unlock()

        if let blocks {
            var deviceListAddress = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &deviceListAddress, listenerQueue, blocks.deviceList)
            var defaultAddress = Self.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &defaultAddress, listenerQueue, blocks.defaultInput)
        }
        for (id, listener) in readiness {
            var address = Self.address(kAudioDevicePropertyDeviceIsAlive,
                                       scope: kAudioObjectPropertyScopeInput)
            AudioObjectRemovePropertyListenerBlock(id, &address, listenerQueue, listener.block)
        }
    }

    // MARK: - Property plumbing

    /// ⚠️ Every helper below returns the `OSStatus` on failure rather than a zero value. That is the
    /// whole point: the measured bug in this area was a helper that ignored the status and handed back
    /// its zero-initialised buffer, which reads as a perfectly ordinary "no".
    private func systemDeviceIDs() -> Result<[AudioObjectID], HALError> {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                                        &address, 0, nil, &size)
        guard sizeStatus == noErr else { return .failure(HALError(reason: Self.describe(status: sizeStatus))) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return .success([]) }
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &ids)
        guard status == noErr else { return .failure(HALError(reason: Self.describe(status: status))) }
        return .success(ids)
    }

    private func stringProperty(_ id: AudioObjectID,
                                _ selector: AudioObjectPropertySelector) -> Result<String, HALError> {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return .failure(HALError(reason: Self.describe(status: status))) }
        guard let string = value as String? else { return .failure(HALError(reason: "null string property")) }
        return .success(string)
    }

    private func uint32Property(_ id: AudioObjectID,
                                _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> Result<UInt32, HALError> {
        var address = Self.address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr else { return .failure(HALError(reason: Self.describe(status: status))) }
        return .success(value)
    }

    private func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration,
                                   scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func transportType(_ id: AudioObjectID) -> AudioTransport {
        guard case .success(let raw) = uint32Property(id, kAudioDevicePropertyTransportType,
                                                      scope: kAudioObjectPropertyScopeGlobal) else {
            return .other(0)
        }
        // ⚠️ Bluetooth is two constants. Mapping both here is what stops every caller above from
        // having to remember `'blea'` exists.
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth: return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: return .bluetoothLE
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        case kAudioDeviceTransportTypeContinuityCaptureWired: return .continuityWired
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return .continuityWireless
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypePCI: return .pci
        case kAudioDeviceTransportTypeFireWire: return .fireWire
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeAVB: return .avb
        default: return .other(raw)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// A readable `OSStatus`. Most HAL errors are four-CCs, which are unreadable as decimal — the
    /// scope bug above surfaced as `2003332927`, which is `'who?'`.
    private static func describe(status: OSStatus) -> String {
        let raw = UInt32(bitPattern: status)
        let bytes = withUnsafeBytes(of: raw.bigEndian) { Array($0) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let fourCC = String(bytes: bytes, encoding: .ascii) {
            return "OSStatus \(status) ('\(fourCC)')"
        }
        return "OSStatus \(status)"
    }
}
