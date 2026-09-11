import ActaControlProtocol
import ActaKit
import ActaRuntime
import Darwin
import Foundation
import Testing

// The app-side lifecycle owner (Plan 2, Task 3): `ControlSocketHost` in-process, over a temp path and a
// **fake** `ControlRequestHandling` (a `.socket` dispatcher over `FakeControlServing`) — no
// `ControlAPI.shared`, no controller, no TCC. These prove the wiring the `AppDelegate` leans on:
// `start()` binds and serves; `teardown()` synchronously closes and unlinks *its own* socket and nothing
// else; and a `start()` against a path a live server already owns refuses.

@available(macOS 15.0, *)
@MainActor
private func makeHost(_ fake: FakeControlServing, at path: String) -> ControlSocketHost {
    let dispatcher = ControlDispatcher(service: fake, confinement: .socket)
    return ControlSocketHost(endpoint: ControlEndpoint(socketPath: path), handler: dispatcher,
                             log: servingTestLogger())
}

// MARK: - start() binds and serves through the fake handler

@available(macOS 15.0, *)
@MainActor
@Test
func hostStartBindsAndServesThroughTheHandler() async throws {
    let dir = makeServingTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/control.sock"

    let fake = FakeControlServing()
    fake.currentState = ControlState(operation: .recording(elapsedSeconds: 3), title: "Standup")
    let host = makeHost(fake, at: path)
    try host.start()
    defer { host.teardown() }

    guard let client = TestSocketClient.connect(to: path) else { Issue.record("connect"); return }
    defer { client.close() }
    await client.send(enc(WireRequest(id: "s", command: .status)))
    let response = decodeResponse(await client.recvLine())
    #expect(response?.id == "s")
    if case .result(.state(let state)) = response?.payload {
        #expect(state.operation.kind == .recording)
        #expect(state.title == "Standup")
    } else {
        Issue.record("expected a state result, got \(String(describing: response?.payload))")
    }
}

// MARK: - teardown() closes and unlinks its own socket

@available(macOS 15.0, *)
@MainActor
@Test
func hostTeardownUnlinksItsOwnSocket() throws {
    let dir = makeServingTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/control.sock"

    let host = makeHost(FakeControlServing(), at: path)
    try host.start()
    #expect(pathIsSocket(path))

    // Synchronous: by the time `teardown()` returns, the socket the host created is gone.
    host.teardown()
    #expect(!FileManager.default.fileExists(atPath: path))

    // Idempotent.
    host.teardown()
}

// MARK: - teardown() unlinks nothing when it no longer owns the path

@available(macOS 15.0, *)
@MainActor
@Test
func hostTeardownLeavesADifferentObjectAtThePathAlone() throws {
    let dir = makeServingTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/control.sock"

    let host = makeHost(FakeControlServing(), at: path)
    try host.start()

    // Something else takes over the path in the meantime — a plain file standing in for a socket a
    // *different* server rebound. Teardown must not remove it: the device/inode identity no longer
    // matches what this host bound.
    _ = unlink(path)
    #expect(FileManager.default.createFile(atPath: path, contents: Data("not ours".utf8)))

    host.teardown()
    #expect(FileManager.default.fileExists(atPath: path))
    let contents = try? String(contentsOfFile: path, encoding: .utf8)
    #expect(contents == "not ours")
}

// MARK: - start() refuses when a live server owns the path

@available(macOS 15.0, *)
@MainActor
@Test
func hostStartRefusesWhenAnotherLiveServerOwnsThePath() throws {
    let dir = makeServingTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/control.sock"

    let first = makeHost(FakeControlServing(), at: path)
    try first.start()
    defer { first.teardown() }

    // A second host over the same live path must refuse — never sever the first.
    let second = makeHost(FakeControlServing(), at: path)
    #expect(throws: ControlEndpoint.BindError.addressInUse) { try second.start() }
    // The first server is untouched and still serving.
    #expect(pathIsSocket(path))
}

// MARK: - Helpers

/// Whether the object at `path` is a socket (following no symlinks).
private func pathIsSocket(_ path: String) -> Bool {
    var st = stat()
    guard lstat(path, &st) == 0 else { return false }
    return Int(st.st_mode) & Int(S_IFMT) == Int(S_IFSOCK)
}
