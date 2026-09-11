import ActaControlProtocol
import Darwin
import Foundation

/// Errors the connection I/O can raise. All are terminal for the connection — the serve loop closes on
/// any of them.
enum ConnectionError: Error, Equatable {
    /// A read/idle deadline elapsed with no bytes.
    case idleTimeout
    /// A write deadline elapsed with the socket buffer full.
    case writeTimeout
    /// The connection's serve task was cancelled (server shutdown, or the watch's peer went away).
    case cancelled
    /// The peer closed the read end mid-write (`EPIPE`, delivered as an error rather than a signal
    /// because `SO_NOSIGPIPE` is set).
    case peerClosed
    /// A `read`/`write` syscall failed for an unrecoverable reason.
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
}

/// Non-blocking `read`/`write` over a single connection descriptor, with readiness bridged from a
/// `DispatchSource` into `async/await`.
///
/// ⚠️ **The descriptor-ownership model is load-bearing.** This object is the **one serialized owner** of
/// `fd`: every readiness wait runs on its private serial `queue`, and `close()` is the **one** close
/// path. The rules that keep it safe against fd-reuse:
/// - No syscall touches `fd` after `close()`. The serve loop calls `close()` exactly once, in its own
///   cleanup, only after every `await` has returned — so no `DispatchSource` is active at that moment
///   (closing a descriptor with a live source is undefined and crashes).
/// - Each readiness wait creates a **one-shot** source and resumes its continuation from the source's
///   **cancellation handler**, never its event handler — Apple guarantees the descriptor is safe to
///   touch only once the cancel handler runs, so the `await` completing means the source is fully torn
///   down.
/// - The continuation is resumed **exactly once**, whichever of event / timeout / task-cancellation
///   fires first, because all three record their outcome and cancel the source on the same serial
///   queue, and the cancel handler (which runs once) is the sole resumer.
public final class ControlConnectionIO: @unchecked Sendable {
    let fd: Int32
    private let queue: DispatchQueue

    public init(fd: Int32, label: String) {
        self.fd = fd
        self.queue = DispatchQueue(label: label)
    }

    /// The result of awaiting readiness.
    enum Readiness {
        case ready
        case timedOut
        case cancelled
    }

    // MARK: - Readiness

    func awaitReadable(deadline: DispatchTime) async -> Readiness {
        await waitReady(makeSource: { DispatchSource.makeReadSource(fileDescriptor: self.fd, queue: $0) },
                        deadline: deadline)
    }

    func awaitWritable(deadline: DispatchTime) async -> Readiness {
        await waitReady(makeSource: { DispatchSource.makeWriteSource(fileDescriptor: self.fd, queue: $0) },
                        deadline: deadline)
    }

    /// One-shot readiness. Every mutation of `box` happens on `queue`, so no lock is needed; the
    /// continuation is resumed once, from the source's cancel handler.
    private func waitReady(makeSource: @escaping @Sendable (DispatchQueue) -> any DispatchSourceProtocol,
                           deadline: DispatchTime) async -> Readiness {
        let box = OutcomeBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Readiness, Never>) in
                queue.async {
                    if box.cancelledEarly {
                        // The task was already cancelled before setup ran; there is nothing to wait for.
                        continuation.resume(returning: .cancelled)
                        return
                    }
                    let source = makeSource(self.queue)
                    box.source = source
                    box.resume = { continuation.resume(returning: $0) }
                    source.setEventHandler {
                        box.settle(.ready)
                    }
                    source.setCancelHandler {
                        // The descriptor is safe to touch again only now; resume the awaiter here.
                        box.timeout?.cancel()
                        box.timeout = nil
                        box.resume?(box.outcome ?? .cancelled)
                        box.resume = nil
                        box.source = nil
                    }
                    // Only arm a deadline timer for a finite deadline. A non-finite one
                    // (`.distantFuture`, used by the `watch` peer-disconnect monitor) would never fire, and
                    // `asyncAfter` retains its target queue and captured box until the block runs — leaking
                    // one queue + box per watch connection for the process's lifetime. The work item is
                    // cancelled in the cancel handler so a finite timer is released as soon as the wait
                    // resolves rather than lingering until its deadline.
                    if deadline != .distantFuture {
                        let timeout = DispatchWorkItem { box.settle(.timedOut) }
                        box.timeout = timeout
                        self.queue.asyncAfter(deadline: deadline, execute: timeout)
                    }
                    source.resume()
                }
            }
        } onCancel: {
            queue.async {
                if box.source != nil {
                    box.settle(.cancelled)
                } else {
                    // Setup has not run yet — flag it so the setup block resumes as cancelled.
                    box.cancelledEarly = true
                }
            }
        }
    }

    /// The per-wait state, confined to `queue`.
    private final class OutcomeBox: @unchecked Sendable {
        var source: (any DispatchSourceProtocol)?
        var outcome: Readiness?
        var resume: ((Readiness) -> Void)?
        var timeout: DispatchWorkItem?
        var cancelledEarly = false

        /// Record the first outcome and start the source teardown; later settles are ignored.
        func settle(_ readiness: Readiness) {
            guard outcome == nil, let source else { return }
            outcome = readiness
            source.cancel()
        }
    }

    // MARK: - Syscalls (non-blocking; EINTR retried at the boundary)

    /// A single non-blocking `read`. Returns the bytes read, an **empty** `Data` at EOF, or throws
    /// `WouldBlock` when the socket has nothing right now (the serve loop then awaits readiness).
    func readAvailable(maxBytes: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, maxBytes) }
            if n > 0 { return Data(buffer[0..<n]) }
            if n == 0 { return Data() }
            let e = errno
            if e == EINTR { continue }
            if e == EAGAIN || e == EWOULDBLOCK { throw WouldBlock() }
            throw ConnectionError.readFailed(errno: e)
        }
    }

    struct WouldBlock: Error {}

    /// Write a whole frame, awaiting writability on `EAGAIN` and looping over short writes.
    func write(_ frame: Data, deadline: () -> DispatchTime) async throws {
        let bytes = [UInt8](frame)
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let written = bytes.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), remaining)
            }
            if written > 0 {
                offset += written
                continue
            }
            let e = errno
            if e == EINTR { continue }
            if e == EAGAIN || e == EWOULDBLOCK {
                switch await awaitWritable(deadline: deadline()) {
                case .ready: continue
                case .timedOut: throw ConnectionError.writeTimeout
                case .cancelled: throw ConnectionError.cancelled
                }
            }
            if e == EPIPE { throw ConnectionError.peerClosed }
            throw ConnectionError.writeFailed(errno: e)
        }
    }

    /// Close the descriptor. The serve loop calls this exactly once, after every `await` has returned.
    func close() {
        Darwin.close(fd)
    }
}

// MARK: - Socket options

/// Configure an accepted connection descriptor: non-blocking, close-on-exec, and — the load-bearing one
/// — `SO_NOSIGPIPE`, so a peer that closes its read end mid-write yields `EPIPE` instead of a
/// process-killing `SIGPIPE` (the Darwin mechanism; there is no `MSG_NOSIGNAL` on this platform).
public enum ControlSocketOptions {
    public static func configureConnection(_ fd: Int32) {
        setNonBlocking(fd)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }
}

/// A `ByteWriting` sink that frames into memory (never blocks, always accepts the whole write) — used
/// with `FrameWriter` so the frame's size limit and its terminating `LF` are still validated by Plan
/// 1's writer, while the socket backpressure is handled separately in `ControlConnectionIO.write`.
final class DataFrameSink: ByteWriting {
    private(set) var data = Data()
    func write(_ data: Data) throws -> Int {
        self.data.append(data)
        return data.count
    }
}
