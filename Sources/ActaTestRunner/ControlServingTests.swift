import ActaControlProtocol
import ActaKit
import ActaRuntime
import Darwin
import Foundation
import Testing

// The connection-serving layer (Plan 2, Task 2): a real socket (or a real `socketpair`) driven against
// a **real confined dispatcher over a `FakeControlServing`** — no controller, no TCC, no wall clock.
// These prove the descriptor work: one request → one response → close; `watch` streaming with
// coalescing when the output stalls; a peer disconnect that neither kills the process nor leaks a
// watcher; deadlines; the connection cap; the `EAGAIN`/short-write path against a genuinely saturated
// socket buffer; and cancellation of a pending readiness wait.
//
// The client and fixtures live in `ControlServingTestSupport`. `Scripts/test.sh` treats an abnormal
// runner exit (a `SIGPIPE` regression) as a failure via `exec` under `set -e`, so the "peer disconnect
// does not kill" test has teeth.

// MARK: - Request → one response → close

@available(macOS 15.0, *)
@MainActor
@Test
func aRequestGetsExactlyOneResponseThenTheConnectionCloses() async throws {
    let fake = FakeControlServing()
    fake.currentState = ControlState(operation: .recording(elapsedSeconds: 9), title: "Weekly sync")
    let (path, cleanup) = try makeServer(fake)
    defer { cleanup() }

    guard let client = TestSocketClient.connect(to: path) else {
        Issue.record("could not connect"); return
    }
    defer { client.close() }

    await client.send(enc(WireRequest(id: "s1", command: .status)))
    let response = decodeResponse(await client.recvLine())
    #expect(response?.id == "s1")
    if case .result(.state(let state)) = response?.payload {
        #expect(state.operation.kind == .recording)
        #expect(state.title == "Weekly sync")
    } else {
        Issue.record("expected a state result, got \(String(describing: response?.payload))")
    }
    // Exactly one response, then the server closes: the next read is a clean EOF.
    #expect(await client.recvLine() == nil)
}

// MARK: - A slow client does not block a second

@available(macOS 15.0, *)
@MainActor
@Test
func aSlowClientDoesNotBlockASecond() async throws {
    let fake = FakeControlServing()
    fake.currentState = ControlState(operation: .idle, title: "Prompt")
    let (path, cleanup) = try makeServer(fake)
    defer { cleanup() }

    // A first client connects and says nothing — it sits in the read/idle wait.
    guard let slow = TestSocketClient.connect(to: path) else { Issue.record("connect"); return }
    defer { slow.close() }

    // A second client gets a prompt answer regardless.
    guard let fast = TestSocketClient.connect(to: path) else { Issue.record("connect"); return }
    defer { fast.close() }
    await fast.send(enc(WireRequest(id: "f", command: .status)))
    let response = decodeResponse(await fast.recvLine())
    #expect(response?.id == "f")
    #expect(response?.payload != nil)
}

// MARK: - watch: coalescing when the output is stalled

@available(macOS 15.0, *)
@MainActor
@Test
func watchCoalescesToTheNewestStateWhenTheOutputIsStalled() async {
    let fake = FakeControlServing()
    fake.currentState = ControlState(operation: .idle)
    let dispatcher = ControlDispatcher(service: fake, confinement: .socket)

    // A `socketpair` with a tiny send/receive budget, so a handful of unread events genuinely stalls the
    // writer — the output is *stalled*, not merely produced fast.
    let (serverFD, client) = makePair()
    setSendBuffer(serverFD, 1024)
    client.setReceiveBuffer(1024)
    ControlSocketOptions.configureConnection(serverFD)
    let io = ControlConnectionIO(fd: serverFD, label: "test.watch")
    let connection = ControlConnection(io: io, handler: dispatcher, timeouts: .default, log: servingTestLogger())
    let task = Task { await connection.serve() }
    defer { task.cancel(); client.close() }

    await client.send(enc(WireRequest(id: "w", command: .watch)))
    #expect(decodeEvent(await client.recvLine())?.event.sequence == 1)

    // Stop reading, then push many states by. The dispatcher's `bufferingNewest(1)` collapses them while
    // the transport is blocked on a full socket.
    for i in 1...200 {
        fake.emit(ControlState(operation: .recording(elapsedSeconds: i),
                               title: i == 200 ? "Newest" : "s\(i)"))
    }

    client.setReadTimeout(milliseconds: 500)
    var events: [WatchEvent] = []
    while let event = decodeEvent(await client.recvLine()) {
        events.append(event.event)
        if event.event.state.title == "Newest" { break }
    }
    // The newest arrived, and the vast majority were coalesced away — an unbounded replay of 200 states
    // would be a process holding unbounded memory for a client that stopped reading.
    #expect(events.last?.state.title == "Newest")
    #expect(events.count < 200)
}

// MARK: - EAGAIN / short write against a saturated buffer

@available(macOS 15.0, *)
@MainActor
@Test
func aLargeResponseSurvivesAGenuinelySaturatedSocketBuffer() async {
    let fake = FakeControlServing()
    fake.currentState = ControlState(recordings: (0..<300).map { fixtureRecording("rec\($0)") })
    let dispatcher = ControlDispatcher(service: fake, confinement: .socket)

    let (serverFD, client) = makePair()
    setSendBuffer(serverFD, 1024)
    client.setReceiveBuffer(1024)
    ControlSocketOptions.configureConnection(serverFD)
    let io = ControlConnectionIO(fd: serverFD, label: "test.big")
    let connection = ControlConnection(io: io, handler: dispatcher, timeouts: .default, log: servingTestLogger())
    let task = Task { await connection.serve() }
    defer { task.cancel(); client.close() }

    await client.send(enc(WireRequest(id: "l", command: .list)))
    // The response dwarfs the 1 KiB buffers, so the server's write hits `EAGAIN` and must await
    // writability while the client drains — the whole frame still arrives intact.
    let response = decodeResponse(await client.recvLine())
    guard case .result(.recordings(let recordings)) = response?.payload else {
        Issue.record("expected a recordings result, got \(String(describing: response?.payload))")
        return
    }
    #expect(recordings.count == 300)
}

// MARK: - A read/idle deadline fires

@available(macOS 15.0, *)
@MainActor
@Test
func aReadIdleDeadlineClosesASilentConnection() async {
    let fake = FakeControlServing()
    let dispatcher = ControlDispatcher(service: fake, confinement: .socket)

    let (serverFD, client) = makePair()
    ControlSocketOptions.configureConnection(serverFD)
    let io = ControlConnectionIO(fd: serverFD, label: "test.idle")
    let timeouts = ControlServingTimeouts(readIdle: .milliseconds(100), write: .seconds(5))
    let connection = ControlConnection(io: io, handler: dispatcher, timeouts: timeouts, log: servingTestLogger())
    let task = Task { await connection.serve() }
    defer { task.cancel(); client.close() }

    // Say nothing. The idle deadline elapses and the server closes — the client sees EOF.
    #expect(await client.recvLine() == nil)
}

// MARK: - A write deadline fires

@available(macOS 15.0, *)
@MainActor
@Test
func aWriteDeadlineClosesAStuckWriter() async {
    let fake = FakeControlServing()
    fake.currentState = ControlState(recordings: (0..<300).map { fixtureRecording("rec\($0)") })
    let dispatcher = ControlDispatcher(service: fake, confinement: .socket)

    let (serverFD, client) = makePair()
    setSendBuffer(serverFD, 1024)
    client.setReceiveBuffer(1024)
    ControlSocketOptions.configureConnection(serverFD)
    let io = ControlConnectionIO(fd: serverFD, label: "test.writedeadline")
    // A short write deadline, a generous read/idle one — so the connection dies on the write, not the read.
    let timeouts = ControlServingTimeouts(readIdle: .seconds(5), write: .milliseconds(150))
    let connection = ControlConnection(io: io, handler: dispatcher, timeouts: timeouts, log: servingTestLogger())
    let task = Task { await connection.serve() }
    defer { task.cancel(); client.close() }

    // Ask for a response far larger than the 1 KiB buffers, then never drain it. The write stalls on
    // `EAGAIN`, the write deadline elapses, and the server gives up and closes — rather than pinning the
    // slot forever on a client that stopped reading.
    await client.send(enc(WireRequest(id: "l", command: .list)))
    // Observe the server-side close as a `POLLHUP` WITHOUT reading. The write deadline re-arms on every
    // `EAGAIN`, so any read here would drain the buffer, unstick the stalled writer, and let the whole
    // frame through — the test would then race the reap against its own drain (and flake under parallel
    // load). Not reading keeps the writer genuinely stuck, so only the deadline can end it. The window is
    // generous: a regression that never fired the write deadline leaves the writer parked forever and
    // this times out to `false`.
    #expect(await client.awaitHangup(timeoutMilliseconds: 3000))
}

// MARK: - Decode-error mappings

@available(macOS 15.0, *)
@MainActor
@Test
func aMalformedFrameClosesWithoutAReply() async throws {
    let fake = FakeControlServing()
    fake.currentState = ControlState(operation: .idle)
    let (path, cleanup) = try makeServer(fake)
    defer { cleanup() }

    guard let client = TestSocketClient.connect(to: path) else { Issue.record("connect"); return }
    defer { client.close() }

    // A well-framed but non-JSON payload has no id to address a reply to, so the server closes silently.
    await client.send(Data("this is not json".utf8))
    #expect(await client.recvLine() == nil)
}

@available(macOS 15.0, *)
@MainActor
@Test
func aVersionMismatchGetsAnUnsupportedVersionError() async throws {
    let fake = FakeControlServing()
    fake.currentState = ControlState(operation: .idle)
    let (path, cleanup) = try makeServer(fake)
    defer { cleanup() }

    guard let client = TestSocketClient.connect(to: path) else { Issue.record("connect"); return }
    defer { client.close() }

    // A syntactically valid request carrying a future protocol version: the id survives, so it earns an
    // addressed `unsupported_version` error rather than a silent close.
    await client.send(enc(WireRequest(id: "v", command: .status, version: 999)))
    let response = decodeResponse(await client.recvLine())
    #expect(response?.id == "v")
    guard case .error(let wireError) = response?.payload else {
        Issue.record("expected an error, got \(String(describing: response?.payload))"); return
    }
    #expect(wireError.code == WireError.Code.unsupportedVersion)
    // Nothing was dispatched to the service — the mismatch is rejected before reaching it.
    #expect(fake.calls.isEmpty)
}

// MARK: - Cancelling a pending readiness wait closes the fd

@available(macOS 15.0, *)
@MainActor
@Test
func cancellingAPendingReadinessWaitClosesTheDescriptor() async {
    let fake = FakeControlServing()
    let dispatcher = ControlDispatcher(service: fake, confinement: .socket)

    let (serverFD, client) = makePair()
    ControlSocketOptions.configureConnection(serverFD)
    let io = ControlConnectionIO(fd: serverFD, label: "test.cancel")
    let connection = ControlConnection(io: io, handler: dispatcher, timeouts: .default, log: servingTestLogger())
    let task = Task { await connection.serve() }
    defer { client.close() }

    // The serve task is parked in the readable wait (no request sent, no blocked `accept`). Cancelling it
    // must wake the wait, unwind, and close the descriptor — the client then sees EOF.
    try? await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()
    #expect(await client.recvLine() == nil)
}

// MARK: - A peer disconnect mid-write does not kill the process

@available(macOS 15.0, *)
@MainActor
@Test
func aPeerDisconnectMidWriteDoesNotKillTheProcess() async throws {
    let fake = FakeControlServing()
    fake.currentState = ControlState(recordings: (0..<300).map { fixtureRecording("rec\($0)") })
    let (path, cleanup) = try makeServer(fake)
    defer { cleanup() }

    // A client asks for a large response and then vanishes without reading it. The server's write finds a
    // dead peer — `EPIPE`, not `SIGPIPE`, because `SO_NOSIGPIPE` is set — and the process survives.
    if let doomed = TestSocketClient.connect(to: path) {
        await doomed.send(enc(WireRequest(id: "l", command: .list)))
        doomed.close()
    }

    // The proof the process lived: a fresh request still gets served.
    try? await Task.sleep(nanoseconds: 100_000_000)
    guard let survivor = TestSocketClient.connect(to: path) else { Issue.record("connect"); return }
    defer { survivor.close() }
    await survivor.send(enc(WireRequest(id: "ok", command: .status)))
    #expect(decodeResponse(await survivor.recvLine())?.id == "ok")
}

// MARK: - A disconnect cancels the watcher

@available(macOS 15.0, *)
@MainActor
@Test
func aWatchDisconnectTearsDownTheUpstreamSubscription() async throws {
    let fake = FakeControlServing()
    fake.currentState = ControlState(operation: .idle)
    let (path, cleanup) = try makeServer(fake)
    defer { cleanup() }

    guard let watcher = TestSocketClient.connect(to: path) else { Issue.record("connect"); return }
    await watcher.send(enc(WireRequest(id: "w", command: .watch)))
    #expect(decodeEvent(await watcher.recvLine())?.event.sequence == 1)
    await waitUntil("the watch subscription to be live") { fake.subscriberCount == 1 }

    // The client goes away. The disconnect monitor sees the EOF, ends the watch, and the upstream
    // subscription is let go — no pump left running for a reader that no longer exists.
    watcher.close()
    await waitUntil("the upstream subscription to be released") { fake.subscriberCount == 0 }
    #expect(fake.subscriberCount == 0)
}

// MARK: - The connection cap

@available(macOS 15.0, *)
@MainActor
@Test
func excessConnectionsAreRejectedAtTheCap() async throws {
    let fake = FakeControlServing()
    fake.currentState = ControlState(operation: .idle)
    let (path, cleanup) = try makeServer(fake, cap: 1)
    defer { cleanup() }

    // One long-lived watcher fills the single slot.
    guard let held = TestSocketClient.connect(to: path) else { Issue.record("connect"); return }
    defer { held.close() }
    await held.send(enc(WireRequest(id: "w", command: .watch)))
    #expect(decodeEvent(await held.recvLine())?.event.sequence == 1)
    await waitUntil("the slot to be held") { fake.subscriberCount == 1 }

    // A second connection is over the cap: accepted then immediately closed, so its request goes
    // unanswered and it sees EOF.
    guard let rejected = TestSocketClient.connect(to: path) else { Issue.record("connect"); return }
    defer { rejected.close() }
    await rejected.send(enc(WireRequest(id: "x", command: .status)))
    #expect(await rejected.recvLine() == nil)
}
