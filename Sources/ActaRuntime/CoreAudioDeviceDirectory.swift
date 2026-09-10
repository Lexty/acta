import ActaKit
import CoreAudio
import Foundation
import os

/// The one and only CoreAudio HAL integration, mirroring `SCKCaptureSource`'s role for
/// ScreenCaptureKit: every `AudioObjectID`, every four-CC selector and every `OSStatus` lives here and
/// nowhere else, so the fakes above answer the questions production actually asks instead of bypassing
/// them.
///
/// **Nothing HAL-shaped escapes.** `AudioObjectID` in particular is ephemeral — measured, not assumed:
/// reconnecting one headset moved it from `140` to `181` while the UID stayed identical — so it is
/// resolved from the UID on every call rather than cached anywhere above.
///
/// ## One execution domain, and why the previous two were wrong
///
/// **Every piece of mutable state and every handler call lives on `coordinatorQueue`, a single serial
/// queue.** The registry, the listener bookkeeping and delivery are one domain, so none of them can
/// interleave with another.
///
/// This replaced a design with separate mutation and delivery queues plus a generation counter, and the
/// replacement is not a tidy-up: that design produced a new race every time one was fixed. Delivery on
/// one queue and lifecycle on another meant a handler could reach `observe`, which waited on mutation,
/// while mutation reported degradation into a handler that cancelled, which waited on delivery — a
/// cycle. `observe` read "listeners are installed", released the lock, and registered its subscriber
/// afterwards, so a cancellation in between left an accepted subscriber with no listeners. A callback
/// that read the generation *at delivery* rather than carrying its registration's generation could
/// adopt a newer one and resurrect listeners after teardown. Each was real; each was a symptom of the
/// same cause, so the cause went instead of the symptoms.
///
/// HAL callbacks still arrive on their own `halQueue` and immediately hop to the coordinator. That hop
/// is deliberate: making HAL calls from the very queue the HAL delivers into is a self-wait waiting to
/// happen, and the hop costs nothing.
///
/// ## No teardown when the last subscriber leaves, deliberately
///
/// Listeners are installed once, on the first `observe`, and removed only in `deinit`. Tearing them
/// down when the registry empties is defensible policy and was implemented first — but nothing needs
/// it. Production holds **one** directory for the app's lifetime with subscribers that live as long as
/// it does, so the teardown path served a case that never happens while generating the resurrection,
/// ordering and lifetime races above. A directory with no subscribers now broadcasts into an empty
/// registry, which costs nothing measurable. Deleting the machinery removed three defects that fixing
/// it would only have moved.
public final class CoreAudioDeviceDirectory: AudioDeviceDirectory, @unchecked Sendable {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "AudioDevices")

    /// The single serial domain. Everything below is touched only from here.
    private let coordinatorQueue = DispatchQueue(label: "dev.personal.acta.audio.devices")
    /// Where the HAL is told to deliver. Separate so a HAL call made from the coordinator can never
    /// wait on the queue the HAL is delivering into.
    private let halQueue = DispatchQueue(label: "dev.personal.acta.audio.devices.hal")
    /// ⚠️ **Per instance, not static.** A shared static key makes "am I on my own queue?" true while
    /// standing on a *different* directory's queue, which silently skips this one's serialization.
    private let coordinatorKey = DispatchSpecificKey<ObjectIdentifier>()

    private var subscribers: [UInt64: Subscriber] = [:]
    private var nextToken: UInt64 = 1
    private var systemBlocks: SystemBlocks?
    private var readinessListeners: [AudioObjectID: ReadinessListener] = [:]

    private struct HALError: Error { let reason: String }

    private struct SystemBlocks {
        let deviceList: AudioObjectPropertyListenerBlock
        let defaultInput: AudioObjectPropertyListenerBlock
    }

    private final class ReadinessListener {
        let uid: String
        let alive: AudioObjectPropertyListenerBlock
        let streams: AudioObjectPropertyListenerBlock
        init(uid: String,
             alive: @escaping AudioObjectPropertyListenerBlock,
             streams: @escaping AudioObjectPropertyListenerBlock) {
            self.uid = uid
            self.alive = alive
            self.streams = streams
        }
    }

    /// One subscription's handler behind its gate. Only ever touched on `coordinatorQueue`, so the gate
    /// needs no lock of its own — the queue *is* the lock.
    private final class Subscriber {
        var handler: (@Sendable (DeviceChange) -> Void)?
        init(handler: @escaping @Sendable (DeviceChange) -> Void) { self.handler = handler }
    }

    private final class Observation: AudioDeviceObservation, @unchecked Sendable {
        private let token: UInt64
        private weak var owner: CoreAudioDeviceDirectory?

        init(token: UInt64, owner: CoreAudioDeviceDirectory) {
            self.token = token
            self.owner = owner
        }

        /// ⚠️ **No "already cancelled" short-circuit.** An early return let a second caller leave while
        /// the first had not yet closed the gate, so `cancel()` returned without its guarantee holding.
        /// Every call now performs the same idempotent work on the coordinator; a redundant one costs a
        /// queue hop, and that is the price of a guarantee that is true for *every* caller.
        func cancel() { owner?.cancelSubscription(token) }

        deinit { cancel() }
    }

    public init() {
        coordinatorQueue.setSpecific(key: coordinatorKey, value: ObjectIdentifier(self))
    }

    deinit {
        // The only teardown there is. It reads the state directly, without hopping to the coordinator,
        // and the argument is **ownership rather than queue affinity** — `deinit` is *not* guaranteed to
        // run on the coordinator, since a HAL callback's temporary strong reference can be the last
        // owner and release it on the HAL queue.
        //
        // What makes the direct reads sound: coordinator work holds a strong `self` for its duration,
        // so no deinitialization can begin while any of it is executing; and every queued callback
        // captures `self` weakly, so once deinitialization has begun none of them can acquire the
        // object. There is therefore no concurrent reader left to race. Scheduling the removal instead
        // would be worse, not better: a queued job capturing `self` weakly would find nothing and skip
        // it, leaving registered blocks with no cleanup path at all.
        if let systemBlocks { Self.removeSystemListeners(systemBlocks, on: halQueue) }
        for (id, listener) in readinessListeners { Self.removeReadiness(listener, from: id, on: halQueue) }
    }

    /// Run `body` on the coordinator. Inline when already there, which is what makes cancelling from
    /// inside a handler legal instead of a deadlock.
    private func onCoordinator<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: coordinatorKey) == ObjectIdentifier(self) { return body() }
        return coordinatorQueue.sync(execute: body)
    }

    // MARK: - Observation

    public func observe(_ handler: @escaping @Sendable (DeviceChange) -> Void) -> ObservationOutcome {
        onCoordinator {
            if systemBlocks == nil {
                switch installSystemListeners() {
                case .failure(let error):
                    // Reported to this caller rather than remembered: a directory that failed to
                    // subscribe is indistinguishable from a quiet machine, and the caller has to be
                    // able to tell.
                    return .failed(reason: error.reason)
                case .success(let blocks):
                    systemBlocks = blocks
                }
            }
            let token = nextToken
            nextToken += 1
            subscribers[token] = Subscriber(handler: handler)
            refreshReadinessListeners()
            return .observing(Observation(token: token, owner: self))
        }
    }

    /// Cancellation, entirely on the coordinator. Because delivery runs there too, being inside this
    /// block *is* the proof that no handler is executing concurrently — the separate "drain" step the
    /// two-queue design needed is gone with the second queue.
    private func cancelSubscription(_ token: UInt64) {
        onCoordinator {
            subscribers[token]?.handler = nil
            subscribers.removeValue(forKey: token)
        }
    }

    private func broadcast(_ change: DeviceChange) {
        // Registration order, not dictionary order: an arbitrary order leaves "a handler cancelled by an
        // earlier handler in the same broadcast" untestable, so its test degenerates into accepting
        // either outcome and passes against the defect it was written for.
        let targets = subscribers.sorted { $0.key < $1.key }.map(\.value)
        for target in targets { target.handler?(change) }
    }

    /// Hop a HAL callback onto the coordinator. Always asynchronous: the HAL thread must never be made
    /// to wait on our own work.
    private func onHALCallback(_ body: @escaping (CoreAudioDeviceDirectory) -> Void) {
        coordinatorQueue.async { [weak self] in
            guard let self else { return }
            body(self)
        }
    }

    // MARK: - Listener lifecycle (coordinator only)

    private func installSystemListeners() -> Result<SystemBlocks, HALError> {
        var deviceListAddress = Self.address(kAudioHardwarePropertyDevices)
        let deviceListBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onHALCallback { directory in
                directory.refreshReadinessListeners()
                directory.broadcast(.deviceListChanged)
            }
        }
        let listStatus = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                            &deviceListAddress, halQueue, deviceListBlock)
        guard listStatus == noErr else {
            return .failure(HALError(reason: "device-list listener: \(Self.describe(status: listStatus))"))
        }

        var defaultAddress = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onHALCallback { $0.broadcast(.defaultInputChanged) }
        }
        let defaultStatus = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                               &defaultAddress, halQueue, defaultBlock)
        guard defaultStatus == noErr else {
            // Do not leave half a subscription installed: a directory reporting device-list changes but
            // never default-input changes is exactly the "unchanged winner, moved default" blind spot.
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &deviceListAddress, halQueue, deviceListBlock)
            return .failure(HALError(reason: "default-input listener: \(Self.describe(status: defaultStatus))"))
        }
        return .success(SystemBlocks(deviceList: deviceListBlock, defaultInput: defaultBlock))
    }

    /// Keep listeners on each present device for the transitions the device *list* cannot report.
    ///
    /// Two properties are watched. `DeviceIsAlive` covers a device that stops working without leaving
    /// the list; `StreamConfiguration` covers its input channels changing, the other way a listed device
    /// silently stops being a usable microphone.
    ///
    /// ⚠️ Default-device **eligibility** has no listener, deliberately: it is picked up by the
    /// re-enumeration every other trigger already performs. That is the defined refresh fallback, and
    /// naming it is the point — an unstated gap is the thing that bites.
    private func refreshReadinessListeners() {
        let ids: [AudioObjectID]
        switch systemDeviceIDs() {
        case .success(let value): ids = value
        case .failure(let error):
            // ⚠️ Not a silent return. Returning quietly leaves the caller believing readiness is
            // watched; worse, an earlier version treated an unreadable list as "every device left" and
            // removed live listeners on the strength of a failed query.
            reportDegradation("device list unreadable, readiness listeners not refreshed: \(error.reason)")
            return
        }

        var present: [AudioObjectID: String] = [:]
        var unreadable: [AudioObjectID] = []
        for id in ids {
            switch stringProperty(id, kAudioDevicePropertyDeviceUID) {
            case .success(let uid): present[id] = uid
            case .failure: unreadable.append(id)
            }
        }

        // ⚠️ A device whose UID would not read is **kept**, not removed. "I could not identify it" is
        // not "it is gone", and dropping its listener on that basis is how a transient read failure
        // becomes a permanently unwatched device.
        let keep = Set(present.keys).union(unreadable)
        for (id, listener) in readinessListeners where !keep.contains(id) {
            readinessListeners.removeValue(forKey: id)
            Self.removeReadiness(listener, from: id, on: halQueue)
        }
        if !unreadable.isEmpty {
            reportDegradation("\(unreadable.count) device(s) could not be identified; their readiness state is uncertain")
        }

        for (id, uid) in present where readinessListeners[id] == nil {
            guard let listener = installReadiness(for: id, uid: uid) else { continue }
            readinessListeners[id] = listener
        }
    }

    private func installReadiness(for id: AudioObjectID, uid: String) -> ReadinessListener? {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onHALCallback { $0.broadcast(.readinessChanged(uid: uid)) }
        }
        var aliveAddress = Self.address(kAudioDevicePropertyDeviceIsAlive,
                                        scope: kAudioObjectPropertyScopeInput)
        let aliveStatus = AudioObjectAddPropertyListenerBlock(id, &aliveAddress, halQueue, block)
        guard aliveStatus == noErr else {
            reportDegradation("no liveness listener for \(uid): \(Self.describe(status: aliveStatus))")
            return nil
        }

        let streamsBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onHALCallback { $0.broadcast(.readinessChanged(uid: uid)) }
        }
        var streamsAddress = Self.address(kAudioDevicePropertyStreamConfiguration,
                                          scope: kAudioObjectPropertyScopeInput)
        let streamsStatus = AudioObjectAddPropertyListenerBlock(id, &streamsAddress, halQueue, streamsBlock)
        guard streamsStatus == noErr else {
            AudioObjectRemovePropertyListenerBlock(id, &aliveAddress, halQueue, block)
            reportDegradation("no stream-configuration listener for \(uid): \(Self.describe(status: streamsStatus))")
            return nil
        }
        return ReadinessListener(uid: uid, alive: block, streams: streamsBlock)
    }

    private static func removeReadiness(_ listener: ReadinessListener,
                                        from id: AudioObjectID,
                                        on queue: DispatchQueue) {
        var aliveAddress = address(kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeInput)
        AudioObjectRemovePropertyListenerBlock(id, &aliveAddress, queue, listener.alive)
        var streamsAddress = address(kAudioDevicePropertyStreamConfiguration,
                                     scope: kAudioObjectPropertyScopeInput)
        AudioObjectRemovePropertyListenerBlock(id, &streamsAddress, queue, listener.streams)
    }

    private static func removeSystemListeners(_ blocks: SystemBlocks, on queue: DispatchQueue) {
        var deviceListAddress = address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &deviceListAddress, queue, blocks.deviceList)
        var defaultAddress = address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &defaultAddress, queue, blocks.defaultInput)
    }

    /// ⚠️ A per-device listener that would not install used to be **logged and nothing else**, while
    /// `observe` still reported success — so the subscription looked healthy and the only thing missing
    /// was exactly the transition that listener existed to catch. Consumers are told instead.
    ///
    /// Called on the coordinator, so it delivers straight into `broadcast` with no hop: a hop would put
    /// the degradation notice out of order with the change it explains.
    private func reportDegradation(_ reason: String) {
        log.info("Observation degraded: \(reason, privacy: .public)")
        broadcast(.observationDegraded(reason: reason))
    }

    // MARK: - Enumeration

    public func enumerateInputDevices() -> DeviceEnumeration {
        let ids: [AudioObjectID]
        switch systemDeviceIDs() {
        case .success(let value): ids = value
        case .failure(let error): return .failed(reason: error.reason)
        }

        var devices: [AudioInputDevice] = []
        var uninspectable: [String] = []
        for id in ids {
            switch describe(id) {
            case .described(let device):
                // Not an input device at all — an ordinary, complete answer, not a gap.
                guard device.inputChannels > 0 else { continue }
                devices.append(device)
            case .uninspectable(let label):
                uninspectable.append(label)
            }
        }
        return .devices(devices, uninspectable: uninspectable)
    }

    private enum Inspection {
        case described(AudioInputDevice)
        /// The OS listed the device and then would not describe it. Reported rather than dropped: a
        /// silent omission is read as a disconnect by everything above.
        case uninspectable(String)
    }

    private func describe(_ id: AudioObjectID) -> Inspection {
        guard case .success(let uid) = stringProperty(id, kAudioDevicePropertyDeviceUID) else {
            return .uninspectable("device \(id) (no UID)")
        }
        let name: String
        if case .success(let value) = stringProperty(id, kAudioObjectPropertyName) {
            name = value
        } else {
            name = uid  // A nameless device is still selectable; the uid is a poor label, not a failure.
        }

        // ⚠️ A failed channel query is **not** zero channels. Zero means "this is an output-only
        // device", a reason to leave it out of an input list; a failure means we do not know, and
        // dropping it silently is the same disappearing act as an unreadable UID.
        guard let channels = inputChannelCount(id) else {
            return .uninspectable("\(uid) (stream configuration unreadable)")
        }

        // ⚠️ The scope here is load-bearing and was measured. In `kAudioObjectPropertyScopeGlobal` this
        // selector returns `kAudioHardwareUnknownPropertyError` for *every* device; a helper that
        // ignored the status would report "cannot be default" for the whole machine, and a filter built
        // on it would reject every microphone while looking like an ordinary empty result.
        let canBeDefault = capability(id, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                      scope: kAudioObjectPropertyScopeInput, label: uid)
        let isAlive = capability(id, kAudioDevicePropertyDeviceIsAlive,
                                 scope: kAudioObjectPropertyScopeInput, label: uid)

        let isRunning: Bool
        switch uint32Property(id, kAudioDevicePropertyDeviceIsRunningSomewhere,
                              scope: kAudioObjectPropertyScopeGlobal) {
        case .success(let value): isRunning = value != 0
        case .failure: isRunning = false
        }

        return .described(AudioInputDevice(uid: uid,
                                           name: name,
                                           transport: transportType(id),
                                           inputChannels: channels,
                                           canBeSystemDefault: canBeDefault,
                                           isAlive: isAlive,
                                           isRunningSomewhere: isRunning))
    }

    /// A yes/no property that may decline to answer. ⚠️ The `.unknown` case is the whole reason this
    /// helper exists instead of a `!= 0` at the call site.
    private func capability(_ id: AudioObjectID,
                            _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope,
                            label: String) -> DeviceCapability {
        switch uint32Property(id, selector, scope: scope) {
        case .success(let value): return value != 0 ? .yes : .no
        case .failure(let error):
            log.info("property unavailable for \(label, privacy: .public): \(error.reason, privacy: .public)")
            return .unknown
        }
    }

    // MARK: - The default input device

    public func currentDefaultInput() -> DefaultInputRead {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        guard status == noErr else { return .failed(reason: Self.describe(status: status)) }
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return .none }
        guard case .success(let uid) = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else {
            return .failed(reason: "default input device \(deviceID) has no UID")
        }
        return .device(uid: uid)
    }

    public func setDefaultInput(uid: String) -> DefaultInputWrite {
        // Resolved fresh every time: the HAL id is ephemeral, so a cached one would eventually name a
        // different device — or nothing.
        switch resolve(uid: uid) {
        case .failure(let error):
            // ⚠️ Not `.unknownDevice`. "I could not look it up" is not "that device is not here": the
            // caller would otherwise drop a perfectly present microphone from its priority list.
            return .failed(reason: error.reason)
        case .success(nil):
            return .unknownDevice(uid: uid)
        case .success(.some(let deviceID)):
            var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
            var value = deviceID
            let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                    &address, 0, nil,
                                                    UInt32(MemoryLayout<AudioObjectID>.size), &value)
            guard status == noErr else { return .failed(reason: Self.describe(status: status)) }
            return .written
        }
    }

    /// `nil` means "looked, and no device carries that uid". A failure means "could not look".
    ///
    /// ⚠️ **The distinction survives a per-device read failure too, and that was a bug once.** Reporting
    /// "no such device" after failing to read some device's UID is a guess dressed as an answer: the
    /// device we were asked about may be exactly the one that would not answer.
    private func resolve(uid: String) -> Result<AudioObjectID?, HALError> {
        switch systemDeviceIDs() {
        case .failure(let error): return .failure(error)
        case .success(let ids):
            var unreadable = 0
            for id in ids {
                switch stringProperty(id, kAudioDevicePropertyDeviceUID) {
                case .success(let candidate) where candidate == uid: return .success(id)
                case .success: continue
                case .failure: unreadable += 1
                }
            }
            guard unreadable == 0 else {
                return .failure(HALError(reason: "\(uid) not found, but \(unreadable) device(s) would not report a UID"))
            }
            return .success(nil)
        }
    }

    // MARK: - Property plumbing

    /// ⚠️ Every helper below surfaces the `OSStatus` rather than a zero value. That is the whole point:
    /// the measured bug in this area was a helper that ignored the status and handed back its
    /// zero-initialised buffer, which reads as a perfectly ordinary "no".
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

    /// `nil` when the query failed — **not** zero. Zero is a real answer ("output-only device") and a
    /// reason to leave a device out of an input list; a failure is not.
    private func inputChannelCount(_ id: AudioObjectID) -> Int? {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration,
                                   scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        guard sizeStatus == noErr else { return nil }
        guard size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func transportType(_ id: AudioObjectID) -> AudioTransport {
        guard case .success(let raw) = uint32Property(id, kAudioDevicePropertyTransportType,
                                                      scope: kAudioObjectPropertyScopeGlobal) else {
            return .other(0)
        }
        // ⚠️ Bluetooth is two constants. Mapping both here is what stops every caller above from having
        // to remember `'blea'` exists.
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

    /// A readable `OSStatus`. Most HAL errors are four-CCs, unreadable as decimal — the scope bug above
    /// surfaced as `2003332927`, which is `'who?'`.
    private static func describe(status: OSStatus) -> String {
        let raw = UInt32(bitPattern: status)
        let bytes = withUnsafeBytes(of: raw.bigEndian) { Array($0) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let fourCC = String(bytes: bytes, encoding: .ascii) {
            return "OSStatus \(status) ('\(fourCC)')"
        }
        return "OSStatus \(status)"
    }
}
