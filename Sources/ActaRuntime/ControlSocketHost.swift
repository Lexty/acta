import ActaControlProtocol
import Foundation
import os

/// Hosts **exactly one** control server inside the running app: it builds the socket-confined dispatcher,
/// owns the Task-1 endpoint and the Task-2 serving layer, and gives the `AppDelegate` two calls —
/// `start()` and a synchronous, bounded `teardown()`.
///
/// SwiftPM cannot import the `Acta` executable, so the lifecycle owner has to live here rather than in
/// the app target; the `AppDelegate` is left as thin wiring over it.
///
/// **Privacy invariant.** `live()` drives `ControlAPI.shared` — the menu's own controller — so an
/// API-started recording is the same recording the menu shows. It must never wrap a second controller
/// (see `ControlAPI`).
///
/// ⚠️ **`teardown()` is synchronous on purpose.** `applicationWillTerminate` is **not** an async
/// suspension point, so a teardown dispatched into a `Task` may not run before the process exits. So
/// `teardown()` synchronously stops accepting, `shutdown()`+`close()`s the owned descriptors, initiates
/// cancellation of the client tasks and `unlinkat`s the socket — but it does **not** await the client
/// tasks. It covers every **orderly** AppKit termination route; a `SIGKILL`/crash it cannot, and there
/// stale-socket recovery in `ControlEndpoint` takes over.
@available(macOS 15.0, *)
@MainActor
public final class ControlSocketHost {
    private let endpoint: ControlEndpoint
    private let handler: any ControlRequestHandling
    private let timeouts: ControlServingTimeouts
    private let log: Logger
    private var server: ControlSocketServer?

    public init(endpoint: ControlEndpoint,
                handler: any ControlRequestHandling,
                timeouts: ControlServingTimeouts = .default,
                log: Logger? = nil) {
        self.endpoint = endpoint
        self.handler = handler
        self.timeouts = timeouts
        self.log = log ?? Logger(subsystem: BuildFlavor.logSubsystem, category: "ControlSocketHost")
    }

    /// The production host: the `.socket`-confined dispatcher over `ControlAPI.shared`, bound at the live
    /// flavor-specific path. The confinement is what stops a socket client from relocating the archive or
    /// driving an adversarial wire string (see `ControlDispatcher.Confinement`).
    public static func live() -> ControlSocketHost {
        let dispatcher = ControlDispatcher(service: ControlAPI.shared, confinement: .socket)
        return ControlSocketHost(endpoint: .live(), handler: dispatcher)
    }

    /// Bind the endpoint and begin serving. Idempotent — a second call while already serving is a no-op.
    /// Throws the `ControlEndpoint.BindError` on failure (notably `.addressInUse` when another instance
    /// already owns the path); the caller logs it and carries on without a socket.
    public func start() throws {
        guard server == nil else { return }
        let bound = try endpoint.bind()
        let server = ControlSocketServer(bound: bound, handler: handler, timeouts: timeouts, log: log)
        server.start()
        self.server = server
        log.notice("control socket serving at \(bound.path, privacy: .public)")
    }

    /// Synchronous, bounded teardown (see the type doc). Stops accepting, cancels client tasks, and
    /// removes the socket — only if this host still owns the exact device/inode it bound. Idempotent.
    public func teardown() {
        server?.shutdown()
        server = nil
    }
}
