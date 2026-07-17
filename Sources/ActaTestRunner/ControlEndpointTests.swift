import Testing
import Foundation
import Darwin
import ActaRuntime

// The secure Unix-socket endpoint (Plan 2, Task 1). These drive a **real socket on a temporary short
// path** — `/tmp/...` rather than `NSTemporaryDirectory()`, whose `/var/folders/...` prefix would blow
// the 104-byte `sun_path` budget — so the bind, the stale-socket recovery and the "never remove a
// non-socket" guarantee are exercised against the kernel, not a fake.

// MARK: - Helpers

/// A fresh `0700` directory under `/tmp` (short enough for `sun_path`). `mkdtemp` creates it at `0700`,
/// which is exactly the private-directory mode the endpoint verifies.
private func makeTempDir() -> String {
    var template = Array("/tmp/acta-endpoint.XXXXXX".utf8CString)
    let result = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
    #expect(result != nil)
    // Drop the trailing NUL (and the CChar array's own terminator) before decoding.
    let bytes = template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func cleanup(_ dir: String) {
    try? FileManager.default.removeItem(atPath: dir)
}

/// Bind a raw socket to `path` and close it **without** unlinking — leaving a socket file with no
/// listener, so a later `connect` gets `ECONNREFUSED`: a stale socket.
private func createStaleSocket(at path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(fd >= 0)
    let addr = try? ControlSocketAddress(path: path)
    #expect(addr != nil)
    let rc = addr!.withSockaddr { sa, len in bind(fd, sa, len) }
    #expect(rc == 0)
    close(fd)
}

private func mode(of path: String, followSymlinks: Bool = true) -> Int? {
    var st = stat()
    let rc = followSymlinks ? stat(path, &st) : lstat(path, &st)
    return rc == 0 ? Int(st.st_mode) : nil
}

// MARK: - The address encoding

@Test
func addressLengthIsExactByteCountPlusHeaderAndNUL() throws {
    let path = "/tmp/acta-endpoint.abcdef/control.sock"
    let address = try ControlSocketAddress(path: path)
    let bytes = Array(path.utf8).count
    // offsetof(sun_path)=2, plus the bytes, plus the terminating NUL.
    #expect(Int(address.length) == 2 + bytes + 1)
    #expect(Int(address.sunLen) == 2 + bytes + 1)
}

@Test
func addressRejectsEmbeddedNUL() {
    #expect(throws: ControlEndpoint.BindError.embeddedNul) {
        _ = try ControlSocketAddress(path: "/tmp/ctl\u{0}.sock")
    }
}

@Test
func addressBoundsOnByteLengthNotCharacterCount() throws {
    // 103 path bytes + NUL == 104 == sun_path capacity: the largest that fits.
    let ok = String(repeating: "a", count: 103)
    #expect(Array(ok.utf8).count == 103)
    _ = try ControlSocketAddress(path: ok)
    // One more byte overflows.
    #expect(throws: ControlEndpoint.BindError.pathTooLong) {
        _ = try ControlSocketAddress(path: String(repeating: "a", count: 104))
    }
    // 52 two-byte characters = 104 bytes: rejected on BYTE length, though it is only 52 characters —
    // proving the bound is byte-based, not character-based.
    let nonAscii = String(repeating: "é", count: 52)
    #expect(nonAscii.count == 52)
    #expect(Array(nonAscii.utf8).count == 104)
    #expect(throws: ControlEndpoint.BindError.pathTooLong) {
        _ = try ControlSocketAddress(path: nonAscii)
    }
    // The same 52 characters as single-byte ASCII fit, confirming the difference is the byte length.
    _ = try ControlSocketAddress(path: String(repeating: "a", count: 52))
}

// MARK: - Bind + listen

@Test
func endpointBindsListensAndVerifiesPermissions() throws {
    let dir = makeTempDir()
    defer { cleanup(dir) }
    let ep = ControlEndpoint(socketPath: dir + "/control.sock")
    let bound = try ep.bind()
    #expect(bound.fileDescriptor >= 0)
    // The socket is a socket at 0600...
    let m = mode(of: bound.path, followSymlinks: false)
    #expect(m != nil)
    #expect(m! & Int(S_IFMT) == Int(S_IFSOCK))
    #expect(m! & 0o777 == 0o600)
    // ...inside a 0700 parent.
    #expect(mode(of: dir).map { $0 & 0o777 } == 0o700)
    // Orderly teardown removes its own socket.
    bound.remove()
    #expect(mode(of: bound.path, followSymlinks: false) == nil)
}

@Test
func aLiveServerIsNeverUnlinked() throws {
    let dir = makeTempDir()
    let ep = ControlEndpoint(socketPath: dir + "/control.sock")
    let live = try ep.bind()
    defer { live.remove(); cleanup(dir) }
    // A second bind sees a LIVE server (connect succeeds) and refuses without touching the socket.
    #expect(throws: ControlEndpoint.BindError.addressInUse) {
        _ = try ep.bind()
    }
    #expect(mode(of: live.path, followSymlinks: false) != nil)
}

@Test
func aStaleSocketIsUnlinkedAndRebound() throws {
    let dir = makeTempDir()
    defer { cleanup(dir) }
    let path = dir + "/control.sock"
    createStaleSocket(at: path)
    #expect(mode(of: path, followSymlinks: false).map { $0 & Int(S_IFMT) } == Int(S_IFSOCK))
    let bound = try ControlEndpoint(socketPath: path).bind()
    defer { bound.remove() }
    #expect(bound.fileDescriptor >= 0)
    // The rebound socket is again a 0600 socket.
    let m = mode(of: path, followSymlinks: false)
    #expect(m! & Int(S_IFMT) == Int(S_IFSOCK))
    #expect(m! & 0o777 == 0o600)
}

@Test
func aRegularFileAtThePathIsNeverRemoved() throws {
    let dir = makeTempDir()
    defer { cleanup(dir) }
    let path = dir + "/control.sock"
    #expect(FileManager.default.createFile(atPath: path, contents: Data("x".utf8)))
    #expect(throws: (any Error).self) {
        _ = try ControlEndpoint(socketPath: path).bind()
    }
    // The regular file survives untouched.
    #expect(mode(of: path, followSymlinks: false).map { $0 & Int(S_IFMT) } == Int(S_IFREG))
}

@Test
func aSymlinkAtThePathIsNeverRemoved() throws {
    let dir = makeTempDir()
    defer { cleanup(dir) }
    let path = dir + "/control.sock"
    let target = dir + "/real"
    #expect(FileManager.default.createFile(atPath: target, contents: Data()))
    #expect(symlink(target, path) == 0)
    #expect(throws: (any Error).self) {
        _ = try ControlEndpoint(socketPath: path).bind()
    }
    // The symlink itself survives (lstat sees the link, not its target).
    #expect(mode(of: path, followSymlinks: false).map { $0 & Int(S_IFMT) } == Int(S_IFLNK))
}
