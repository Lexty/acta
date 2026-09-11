import ActaControlProtocol
import ActaKit
import ActaRuntime
import Darwin
import Foundation
import os
import Testing

// The client and fixtures the `ControlServingTests` are driven with — split out (as
// `ControlDispatcherTestSupport` is) so the suite itself stays readable.
//
// ⚠️ The test client does its **blocking** socket I/O on a global queue, never on the test's actor, so
// awaiting it releases the main actor for the server's `@MainActor` dispatch hop. A blocking read on the
// main actor would deadlock: the reply cannot be produced while the actor that must produce it is
// parked in `read`.

func servingTestLogger() -> Logger { Logger(subsystem: "dev.personal.acta-test", category: "serving") }

/// A blocking Unix-socket client whose I/O is offloaded to a global queue.
final class TestSocketClient: @unchecked Sendable {
    let fd: Int32
    private var readBuffer = Data()

    init(fd: Int32) {
        self.fd = fd
        // The runner hosts both ends: a client write to a server that already closed would otherwise
        // raise SIGPIPE and kill the whole test process (the server side is protected by
        // `SO_NOSIGPIPE`; the client end is ours to protect here).
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func connect(to path: String) -> TestSocketClient? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard let addr = try? ControlSocketAddress(path: path) else { Darwin.close(fd); return nil }
        let rc = addr.withSockaddr { sa, len in Darwin.connect(fd, sa, len) }
        guard rc == 0 else { Darwin.close(fd); return nil }
        return TestSocketClient(fd: fd)
    }

    func setReceiveBuffer(_ bytes: Int32) {
        var value = bytes
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    func setReadTimeout(milliseconds: Int) {
        var tv = timeval(tv_sec: milliseconds / 1000, tv_usec: Int32((milliseconds % 1000) * 1000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Send a payload as a frame (payload + `LF`), looping over short writes.
    func send(_ payload: Data) async {
        var frame = payload
        frame.append(0x0A)
        let bytes = [UInt8](frame)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                var offset = 0
                bytes.withUnsafeBytes { raw in
                    while offset < bytes.count {
                        let n = Darwin.write(self.fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if n > 0 { offset += n } else if errno == EINTR { continue } else { break }
                    }
                }
                continuation.resume()
            }
        }
    }

    /// Read one frame's payload (up to the next `LF`). `nil` at EOF, on a read timeout, or on error.
    func recvLine() async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global().async {
                while true {
                    if let index = self.readBuffer.firstIndex(of: 0x0A) {
                        let line = self.readBuffer.subdata(in: self.readBuffer.startIndex..<index)
                        self.readBuffer.removeSubrange(self.readBuffer.startIndex...index)
                        continuation.resume(returning: line)
                        return
                    }
                    var chunk = [UInt8](repeating: 0, count: 8192)
                    let n = chunk.withUnsafeMutableBytes { Darwin.read(self.fd, $0.baseAddress, 8192) }
                    if n > 0 {
                        self.readBuffer.append(contentsOf: chunk[0..<n])
                    } else if n == 0 {
                        continuation.resume(returning: nil)   // EOF
                        return
                    } else {
                        if errno == EINTR { continue }
                        continuation.resume(returning: nil)   // timeout / error
                        return
                    }
                }
            }
        }
    }

    /// Wait until the server closes its end (`POLLHUP`), **without reading a byte**. Reading would drain
    /// the socket buffer and unstick a writer the test deliberately left stalled — the write deadline
    /// re-arms on every `EAGAIN`, so a draining client keeps a "stuck" writer alive forever and the reap
    /// never happens. Returns true on hangup, false if `timeoutMilliseconds` elapses first.
    ///
    /// Darwin only surfaces `POLLHUP` when `POLLIN` is requested, and buffered-but-unread bytes make
    /// `poll` return immediately with `POLLIN` set while the peer is merely stalled (not closed). So this
    /// polls in a short spin, distinguishing "stalled" (`POLLIN`, no `POLLHUP`) from "reaped" (`POLLHUP`),
    /// and naps between polls rather than busy-waiting.
    func awaitHangup(timeoutMilliseconds: Int) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let deadline = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
                while DispatchTime.now() < deadline {
                    var pfd = pollfd(fd: self.fd, events: Int16(POLLIN), revents: 0)
                    _ = poll(&pfd, 1, 50)
                    if (pfd.revents & Int16(POLLHUP)) != 0 {
                        continuation.resume(returning: true)
                        return
                    }
                    usleep(10_000)
                }
                continuation.resume(returning: false)
            }
        }
    }

    func close() { Darwin.close(fd) }
}

// MARK: - Encoding / decoding

func enc(_ request: WireRequest) -> Data {
    (try? ControlProtocolCodec.encode(request)) ?? Data()
}

func decodeResponse(_ data: Data?) -> WireResponse? {
    guard let data else { return nil }
    return try? ControlProtocolCodec.decode(WireResponse.self, from: data)
}

func decodeEvent(_ data: Data?) -> WireEvent? {
    guard let data else { return nil }
    return try? ControlProtocolCodec.decode(WireEvent.self, from: data)
}

// MARK: - Sockets

func setSendBuffer(_ fd: Int32, _ bytes: Int32) {
    var value = bytes
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &value, socklen_t(MemoryLayout<Int32>.size))
}

/// A connected `socketpair`: the server-side descriptor (raw) and the client end (wrapped).
func makePair() -> (server: Int32, client: TestSocketClient) {
    var fds: [Int32] = [0, 0]
    let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    #expect(rc == 0)
    return (fds[0], TestSocketClient(fd: fds[1]))
}

func makeServingTempDir() -> String {
    var template = Array("/tmp/acta-serving.XXXXXX".utf8CString)
    let result = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
    #expect(result != nil)
    let bytes = template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(bytes: bytes, encoding: .utf8) ?? ""
}

/// Bind a real server on a temp path and start it. Returns the socket path and a `cleanup` that shuts
/// the server down and removes the temp directory.
@available(macOS 15.0, *)
@MainActor
func makeServer(_ fake: FakeControlServing,
                cap: Int = ControlSocketServer.defaultConnectionCap,
                timeouts: ControlServingTimeouts = .default)
    throws -> (path: String, cleanup: () -> Void) {
    let dir = makeServingTempDir()
    let path = dir + "/control.sock"
    let bound = try ControlEndpoint(socketPath: path).bind()
    let dispatcher = ControlDispatcher(service: fake, confinement: .socket)
    let server = ControlSocketServer(bound: bound, handler: dispatcher, timeouts: timeouts,
                                     connectionCap: cap, log: servingTestLogger())
    server.start()
    return (path, {
        server.shutdown()
        try? FileManager.default.removeItem(atPath: dir)
    })
}
