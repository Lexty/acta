import ActaControlProtocol
import Darwin
import Foundation
import os

/// Accepts connections on the app's listening control socket and serves each one, isolating a slow or
/// hostile client from the app.
///
/// ⚠️ **Descriptor ownership.** The listener descriptor (inside `BoundSocket`) is owned here and closed
/// exactly once — by `bound.remove()`, run from the accept source's **cancellation handler**, the only
/// point at which closing a descriptor a `DispatchSource` watches is safe. Each connection descriptor is
/// owned by its own `ControlConnection`/`ControlConnectionIO`, which is its sole closer. The server
/// never closes a connection descriptor; it only cancels the connection's task, and the connection
/// unwinds and closes itself.
///
/// All bookkeeping (the accept loop, the live-connection table) runs on one serial `acceptQueue`, so
/// there is no lock and no cross-thread mutation of the table.
@available(macOS 15.0, *)
public final class ControlSocketServer: @unchecked Sendable {
    /// The maximum number of connections served at once; excess `accept`s are closed immediately. It
    /// matches the listen backlog in `ControlEndpoint`.
    public static let defaultConnectionCap = 16

    private let bound: BoundSocket
    private let handler: any ControlRequestHandling
    private let timeouts: ControlServingTimeouts
    private let connectionCap: Int
    private let log: Logger

    /// How long to stop accepting after a persistent accept error (e.g. `EMFILE`) before re-arming.
    private static let acceptBackoff: DispatchTimeInterval = .seconds(1)

    private let acceptQueue = DispatchQueue(label: "dev.personal.acta.control.accept")
    private var acceptSource: (any DispatchSourceProtocol)?
    private var acceptSuspended = false
    private var connections: [UUID: Task<Void, Never>] = [:]
    private var started = false
    private var shuttingDown = false

    /// Signalled by the accept source's cancellation handler, once the listener has been removed. It lets
    /// `shutdown()` be **synchronous**: an orderly quit (`applicationWillTerminate` is not an async
    /// suspension point) must not race the process exit and leave a stale socket behind. The wait is over
    /// exactly one bounded step — `unlinkat` + two `close`s — and never over the client tasks.
    private let listenerRemoved = DispatchSemaphore(value: 0)

    /// The socket path the server is bound to (for logging).
    public var socketPath: String { bound.path }

    public init(bound: BoundSocket,
                handler: any ControlRequestHandling,
                timeouts: ControlServingTimeouts = .default,
                connectionCap: Int = ControlSocketServer.defaultConnectionCap,
                log: Logger? = nil) {
        self.bound = bound
        self.handler = handler
        self.timeouts = timeouts
        self.connectionCap = connectionCap
        self.log = log ?? Logger(subsystem: BuildFlavor.logSubsystem, category: "ControlSocketServer")
    }

    /// Begin accepting. The listener is set non-blocking and its readiness drives `accept`.
    public func start() {
        acceptQueue.sync {
            guard !started, !shuttingDown else { return }
            started = true
            ControlSocketOptions.setNonBlocking(bound.fileDescriptor)
            let source = DispatchSource.makeReadSource(fileDescriptor: bound.fileDescriptor,
                                                       queue: acceptQueue)
            source.setEventHandler { [weak self] in self?.acceptReady() }
            source.setCancelHandler { [bound, listenerRemoved] in
                // The one safe moment to remove the listener: the source that watched it is fully torn
                // down. `remove()` unlinks the socket (device/inode-checked) and closes the descriptor.
                bound.remove()
                listenerRemoved.signal()
            }
            acceptSource = source
            source.resume()
        }
    }

    /// Stop accepting, cancel every in-flight connection task, and remove the listener. Synchronous,
    /// idempotent, and does **not** await the connection tasks — a client must never be able to delay
    /// the app's teardown. A cancelled connection unwinds and closes its own descriptor.
    public func shutdown() {
        var awaitListenerRemoval = false
        acceptQueue.sync {
            guard !shuttingDown else { return }
            shuttingDown = true
            if let source = acceptSource {
                // A suspended source's cancellation handler does not run until it is resumed; resume it
                // first so `cancel()` below actually removes the listener and signals `listenerRemoved`
                // (otherwise the synchronous wait would deadlock). Balances the suspend in `suspendAccepting`.
                if acceptSuspended {
                    source.resume()
                    acceptSuspended = false
                }
                // Its cancellation handler removes the listener — the one safe close point — and signals
                // `listenerRemoved`. We wait on that below so teardown is synchronous.
                source.cancel()
                acceptSource = nil
                awaitListenerRemoval = true
            } else {
                // Never started (no source ever watched the descriptor): safe to remove it directly.
                bound.remove()
            }
            for task in connections.values { task.cancel() }
            connections.removeAll()
        }
        // Bounded: the cancellation handler runs next on `acceptQueue` (this `sync` block just left it)
        // and does nothing but remove the listener. Client tasks are only cancelled, never awaited.
        if awaitListenerRemoval { listenerRemoved.wait() }
    }

    // MARK: - Accept loop (serial on `acceptQueue`)

    private func acceptReady() {
        guard !shuttingDown else { return }
        while true {
            let fd = Darwin.accept(bound.fileDescriptor, nil, nil)
            if fd < 0 {
                let e = errno
                if e == EINTR { continue }
                if e == EAGAIN || e == EWOULDBLOCK { return }   // drained
                if e == ECONNABORTED { continue }
                // EMFILE/ENFILE and friends: the connection stays pending, and the listener source is
                // level-triggered, so simply returning would have it re-fire immediately into the same
                // error — a CPU/log-spam busy-loop until a descriptor frees. Suspend accepting and re-arm
                // after a short backoff instead.
                log.error("accept failed: errno \(e, privacy: .public)")
                suspendAccepting()
                return
            }
            guard connections.count < connectionCap else {
                // At capacity — reject the excess rather than let an unbounded number of clients in.
                log.notice("control connection cap reached; rejecting a connection")
                Darwin.close(fd)
                continue
            }
            serveAccepted(fd)
        }
    }

    /// Stop the level-triggered accept source from re-firing after a persistent accept error, and
    /// schedule a re-arm. Runs on `acceptQueue`, as does every state touch, so no lock is needed; the
    /// `acceptSuspended` flag keeps suspend/resume balanced against both `resumeAccepting` and `shutdown`.
    private func suspendAccepting() {
        guard let source = acceptSource, !acceptSuspended, !shuttingDown else { return }
        source.suspend()
        acceptSuspended = true
        acceptQueue.asyncAfter(deadline: .now() + ControlSocketServer.acceptBackoff) { [weak self] in
            self?.resumeAccepting()
        }
    }

    private func resumeAccepting() {
        guard acceptSuspended, let source = acceptSource else { return }
        acceptSuspended = false
        source.resume()
    }

    private func serveAccepted(_ fd: Int32) {
        ControlSocketOptions.configureConnection(fd)
        let id = UUID()
        let io = ControlConnectionIO(fd: fd, label: "dev.personal.acta.control.conn.\(id.uuidString)")
        let connection = ControlConnection(io: io, handler: handler, timeouts: timeouts, log: log)
        let task = Task { [weak self] in
            await connection.serve()
            guard let self else { return }
            self.acceptQueue.async { [weak self] in self?.connections[id] = nil }
        }
        connections[id] = task
    }
}
