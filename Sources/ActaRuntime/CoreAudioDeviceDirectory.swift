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
/// ## The three concurrency domains, and why they are separate
///
/// - **`stateLock`** guards the subscriber registry and the listener bookkeeping. It is held for
///   pointer-shuffling only. ⚠️ **No HAL call ever runs under it**: `AudioObjectAddPropertyListenerBlock`
///   can call into the HAL server, and holding a lock across it invites a lock-order inversion against
///   a callback arriving on another thread.
/// - **`mutationQueue`** serializes *complete* listener lifecycle operations — install, teardown,
///   readiness refresh. Serializing the whole operation rather than each step is the point: two
///   refreshes that interleave can both register a block for the same device and leave only one of them
///   removable, and CoreAudio retains a registered block until a *matching* removal, so the other leaks
///   and keeps firing. A `generation` counter closes the remaining window, where a refresh that began
///   before a teardown would otherwise install listeners for a directory nobody is subscribed to.
/// - **`deliveryQueue`** is where HAL callbacks arrive and where handlers run. Cancellation drains it.
public final class CoreAudioDeviceDirectory: AudioDeviceDirectory, @unchecked Sendable {
    private let log = Logger(subsystem: BuildFlavor.logSubsystem, category: "AudioDevices")

    private let stateLock = NSLock()
    private var subscribers: [UInt64: Subscriber] = [:]
    private var nextToken: UInt64 = 1
    private var systemListenersInstalled = false
    private var systemBlocks: SystemBlocks?
    private var readinessListeners: [AudioObjectID: ReadinessListener] = [:]
    /// Bumped by every teardown. A lifecycle operation that began under an older generation must not
    /// apply its result.
    private var generation: UInt64 = 0

    private let deliveryQueue = DispatchQueue(label: "dev.personal.acta.audio.devices.delivery")
    private let mutationQueue = DispatchQueue(label: "dev.personal.acta.audio.devices.mutation")
    private static let deliveryKey = DispatchSpecificKey<Void>()
    private static let mutationKey = DispatchSpecificKey<Void>()

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

    /// One subscription's handler behind its **gate**.
    ///
    /// The gate alone is only half of the cancellation guarantee — see `Observation.cancel()` for the
    /// drain that is the other half.
    private final class Subscriber {
        private let lock = NSLock()
        private var handler: (@Sendable (DeviceChange) -> Void)?

        init(handler: @escaping @Sendable (DeviceChange) -> Void) { self.handler = handler }

        /// Read the gate and the handler in one acquisition, then run the handler **outside** the lock:
        /// holding it across the call would serialize unrelated subscribers against each other and put
        /// a caller-supplied closure inside our critical section.
        func deliver(_ change: DeviceChange) {
            lock.lock()
            let handler = self.handler
            lock.unlock()
            handler?(change)
        }

        /// Close the gate. Every *later* delivery finds nothing; the one already in flight is handled
        /// by the drain.
        func close() {
            lock.lock()
            handler = nil
            lock.unlock()
        }
    }

    private final class Observation: AudioDeviceObservation, @unchecked Sendable {
        private let token: UInt64
        private weak var owner: CoreAudioDeviceDirectory?
        private let lock = NSLock()
        private var cancelled = false

        init(token: UInt64, owner: CoreAudioDeviceDirectory) {
            self.token = token
            self.owner = owner
        }

        func cancel() {
            lock.lock()
            let already = cancelled
            cancelled = true
            lock.unlock()
            guard !already else { return }
            owner?.cancelSubscription(token)
        }

        deinit { cancel() }
    }

    public init() {
        deliveryQueue.setSpecific(key: Self.deliveryKey, value: ())
        mutationQueue.setSpecific(key: Self.mutationKey, value: ())
    }

    deinit {
        // Best effort: a directory that outlived its subscribers must not leave HAL blocks pointing at
        // freed state. Synchronous, because after `deinit` there is no `self` left to run anything.
        performTeardown(removing: takeAllListeners())
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
        // device", which is a reason to leave it out of an input list; a failure means we do not know,
        // and dropping it silently is the same disappearing act as an unreadable UID.
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
            // ⚠️ Not `.unknownDevice`. "I could not enumerate" is not "that device is not here": the
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

    private func resolve(uid: String) -> Result<AudioObjectID?, HALError> {
        switch systemDeviceIDs() {
        case .failure(let error): return .failure(error)
        case .success(let ids):
            for id in ids {
                if case .success(let candidate) = stringProperty(id, kAudioDevicePropertyDeviceUID),
                   candidate == uid {
                    return .success(id)
                }
            }
            return .success(nil)
        }
    }

    // MARK: - Observation

    public func observe(_ handler: @escaping @Sendable (DeviceChange) -> Void) -> ObservationOutcome {
        // The whole install runs on the mutation queue, so it cannot interleave with a teardown that a
        // last cancellation just started.
        let outcome: ObservationOutcome = onMutationQueue {
            stateLock.lock()
            let needsInstall = !systemListenersInstalled
            stateLock.unlock()

            if needsInstall {
                switch installSystemListeners() {
                case .failure(let error):
                    // Reported to this caller rather than remembered: a directory that failed to
                    // subscribe is indistinguishable from a quiet machine, and the caller has to be
                    // able to tell.
                    return .failed(reason: error.reason)
                case .success(let blocks):
                    stateLock.lock()
                    systemBlocks = blocks
                    systemListenersInstalled = true
                    stateLock.unlock()
                }
            }

            stateLock.lock()
            let token = nextToken
            nextToken += 1
            subscribers[token] = Subscriber(handler: handler)
            let currentGeneration = generation
            stateLock.unlock()

            refreshReadinessListeners(generation: currentGeneration)
            return .observing(Observation(token: token, owner: self))
        }
        return outcome
    }

    /// Cancellation, in the two halves the contract requires.
    private func cancelSubscription(_ token: UInt64) {
        stateLock.lock()
        let subscriber = subscribers[token]
        stateLock.unlock()

        // 1. Close the gate: every *later* delivery finds nothing.
        subscriber?.close()

        // 2. Drain: a callback that read the gate as open is running right now, and `sync` onto the
        //    delivery queue returns only once it has finished. Skipped when we are *already* on that
        //    queue — cancelling from inside a handler is legal, and there the in-flight delivery is the
        //    caller's own, so there is nothing to wait for and `sync` would deadlock.
        if DispatchQueue.getSpecific(key: Self.deliveryKey) == nil {
            deliveryQueue.sync {}
        }

        // 3. Remove, and decide about teardown **in the same acquisition** as the removal. Splitting
        //    them lets a new subscriber arrive between the "registry is empty" observation and the
        //    teardown, see `systemListenersInstalled == true`, be told it is observing, and then have
        //    its listeners removed out from under it.
        stateLock.lock()
        subscribers.removeValue(forKey: token)
        var doomed: Listeners?
        if subscribers.isEmpty {
            doomed = takeAllListenersLocked()
        }
        stateLock.unlock()

        if let doomed {
            mutationQueue.async { [weak self] in self?.performTeardown(removing: doomed) }
        }
    }

    /// ⚠️ **Delivery follows registration order, and that is deliberate rather than incidental.**
    /// Iterating a dictionary's values hands out an arbitrary order that varies between runs, which
    /// makes "a handler cancelled by an earlier handler in the same broadcast" untestable: the test
    /// cannot know which ran first, so it degenerates into accepting either outcome — a tautology that
    /// passes against the very defect it was written for. Sorting by token costs nothing at this size
    /// and makes the gate's guarantee assertable.
    private func broadcast(_ change: DeviceChange) {
        stateLock.lock()
        let targets = subscribers.sorted { $0.key < $1.key }.map(\.value)
        stateLock.unlock()
        for target in targets { target.deliver(change) }
    }

    // MARK: - Listener lifecycle (mutation queue only)

    private struct Listeners {
        var system: SystemBlocks?
        var readiness: [AudioObjectID: ReadinessListener]
    }

    private func takeAllListeners() -> Listeners {
        stateLock.lock()
        defer { stateLock.unlock() }
        return takeAllListenersLocked()
    }

    /// Caller holds `stateLock`. Bumps the generation so any lifecycle operation already in flight
    /// discards its result instead of reinstalling listeners nobody is subscribed to.
    private func takeAllListenersLocked() -> Listeners {
        let taken = Listeners(system: systemBlocks, readiness: readinessListeners)
        systemBlocks = nil
        readinessListeners.removeAll()
        systemListenersInstalled = false
        generation &+= 1
        return taken
    }

    private func performTeardown(removing listeners: Listeners) {
        if let system = listeners.system {
            var deviceListAddress = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &deviceListAddress, deliveryQueue, system.deviceList)
            var defaultAddress = Self.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &defaultAddress, deliveryQueue, system.defaultInput)
        }
        for (id, listener) in listeners.readiness { removeReadiness(listener, from: id) }
    }

    private func installSystemListeners() -> Result<SystemBlocks, HALError> {
        var deviceListAddress = Self.address(kAudioHardwarePropertyDevices)
        let deviceListBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Hop off the delivery queue: the refresh makes HAL calls, and running them on the queue
            // the HAL is delivering into is how a callback ends up waiting for itself.
            let currentGeneration = self.currentGeneration()
            self.mutationQueue.async { self.refreshReadinessListeners(generation: currentGeneration) }
            self.broadcast(.deviceListChanged)
        }
        let listStatus = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                            &deviceListAddress, deliveryQueue,
                                                            deviceListBlock)
        guard listStatus == noErr else {
            return .failure(HALError(reason: "device-list listener: \(Self.describe(status: listStatus))"))
        }

        var defaultAddress = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.broadcast(.defaultInputChanged)
        }
        let defaultStatus = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                               &defaultAddress, deliveryQueue,
                                                               defaultBlock)
        guard defaultStatus == noErr else {
            // Do not leave half a subscription installed: a directory reporting device-list changes but
            // never default-input changes is exactly the "unchanged winner, moved default" blind spot.
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &deviceListAddress, deliveryQueue, deviceListBlock)
            return .failure(HALError(reason: "default-input listener: \(Self.describe(status: defaultStatus))"))
        }
        return .success(SystemBlocks(deviceList: deviceListBlock, defaultInput: defaultBlock))
    }

    /// Keep listeners on each present device for the transitions the device *list* cannot report.
    ///
    /// Two properties are watched, not one. `DeviceIsAlive` covers a device that stops working without
    /// leaving the list; `StreamConfiguration` covers its input channels changing, which is the other
    /// way a listed device silently stops being a usable microphone.
    ///
    /// ⚠️ Default-device **eligibility** has no listener here, deliberately: it is picked up by the
    /// re-enumeration every other trigger already performs. That is the "defined refresh fallback", and
    /// naming it is the point — an unstated gap is the thing that bites.
    ///
    /// Runs on `mutationQueue` only, so two refreshes cannot both register a block for the same device
    /// and leave one of them unremovable.
    private func refreshReadinessListeners(generation entryGeneration: UInt64) {
        guard case .success(let ids) = systemDeviceIDs() else { return }
        var present: [AudioObjectID: String] = [:]
        for id in ids {
            if case .success(let uid) = stringProperty(id, kAudioDevicePropertyDeviceUID) {
                present[id] = uid
            }
        }

        stateLock.lock()
        guard generation == entryGeneration else {
            // A teardown happened while we were reading the HAL. Installing now would resurrect
            // listeners for a directory with no subscribers.
            stateLock.unlock()
            return
        }
        let known = Set(readinessListeners.keys)
        var removals: [(AudioObjectID, ReadinessListener)] = []
        for id in known.subtracting(Set(present.keys)) {
            if let listener = readinessListeners.removeValue(forKey: id) { removals.append((id, listener)) }
        }
        let toAdd = Set(present.keys).subtracting(known)
        stateLock.unlock()

        for (id, listener) in removals { removeReadiness(listener, from: id) }

        for id in toAdd {
            guard let uid = present[id] else { continue }
            guard let listener = installReadiness(for: id, uid: uid) else { continue }
            stateLock.lock()
            if generation == entryGeneration, readinessListeners[id] == nil {
                readinessListeners[id] = listener
                stateLock.unlock()
            } else {
                // Lost a race with a teardown, or the entry is already taken. Remove what we just
                // installed rather than leaking a block CoreAudio will keep calling forever.
                stateLock.unlock()
                removeReadiness(listener, from: id)
            }
        }
    }

    private func installReadiness(for id: AudioObjectID, uid: String) -> ReadinessListener? {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.broadcast(.readinessChanged(uid: uid))
        }
        var aliveAddress = Self.address(kAudioDevicePropertyDeviceIsAlive,
                                        scope: kAudioObjectPropertyScopeInput)
        let aliveStatus = AudioObjectAddPropertyListenerBlock(id, &aliveAddress, deliveryQueue, block)
        guard aliveStatus == noErr else {
            reportDegradation("no liveness listener for \(uid): \(Self.describe(status: aliveStatus))")
            return nil
        }

        let streamsBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.broadcast(.readinessChanged(uid: uid))
        }
        var streamsAddress = Self.address(kAudioDevicePropertyStreamConfiguration,
                                          scope: kAudioObjectPropertyScopeInput)
        let streamsStatus = AudioObjectAddPropertyListenerBlock(id, &streamsAddress, deliveryQueue,
                                                                streamsBlock)
        guard streamsStatus == noErr else {
            AudioObjectRemovePropertyListenerBlock(id, &aliveAddress, deliveryQueue, block)
            reportDegradation("no stream-configuration listener for \(uid): \(Self.describe(status: streamsStatus))")
            return nil
        }
        return ReadinessListener(uid: uid, alive: block, streams: streamsBlock)
    }

    private func removeReadiness(_ listener: ReadinessListener, from id: AudioObjectID) {
        var aliveAddress = Self.address(kAudioDevicePropertyDeviceIsAlive,
                                        scope: kAudioObjectPropertyScopeInput)
        AudioObjectRemovePropertyListenerBlock(id, &aliveAddress, deliveryQueue, listener.alive)
        var streamsAddress = Self.address(kAudioDevicePropertyStreamConfiguration,
                                          scope: kAudioObjectPropertyScopeInput)
        AudioObjectRemovePropertyListenerBlock(id, &streamsAddress, deliveryQueue, listener.streams)
    }

    /// ⚠️ A per-device listener that would not install used to be **logged and nothing else**, while
    /// `observe` still reported success — so the subscription looked healthy and the only thing missing
    /// was exactly the transition that listener existed to catch. Consumers are told instead.
    private func reportDegradation(_ reason: String) {
        log.info("Observation degraded: \(reason, privacy: .public)")
        broadcast(.observationDegraded(reason: reason))
    }

    private func currentGeneration() -> UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation
    }

    /// Run `body` on the mutation queue, without deadlocking if we are already on it.
    private func onMutationQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.mutationKey) != nil { return body() }
        return mutationQueue.sync(execute: body)
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
