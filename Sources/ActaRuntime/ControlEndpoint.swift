import ActaKit
import Darwin
import Foundation

/// A Darwin `sockaddr_un` for an `AF_UNIX` path, encoded once and validated at construction.
///
/// ⚠️ Every subtlety of the Darwin address is captured here so `bind`/`connect` never has to think about
/// it: the storage is **zero-initialised**, `sun_len` is set, an **embedded NUL** is rejected (it would
/// silently truncate the path the kernel binds), the **UTF-8 byte length** (not the character count) plus
/// the terminating NUL must fit `sun_path`, and the address length passed to the syscall is the exact
/// `offsetof(sun_path) + utf8ByteCount + 1` — never `MemoryLayout<sockaddr_un>.size`, which would send the
/// kernel trailing garbage as part of the name.
public struct ControlSocketAddress {
    /// `sun_len`, `sun_family` are each one byte on Darwin, so `sun_path` begins at offset 2. This is
    /// frozen ABI; it is written out rather than derived so the arithmetic reads plainly.
    static let sunPathOffset = 2

    private var storage = sockaddr_un()
    /// The exact address length for the syscall: `offsetof(sun_path) + utf8ByteCount + 1`.
    public let length: socklen_t

    public init(path: String) throws {
        let bytes = Array(path.utf8)
        if bytes.contains(0) { throw ControlEndpoint.BindError.embeddedNul }
        // `sun_path` capacity is 104 on Darwin; the path plus its terminating NUL must fit.
        let capacity = MemoryLayout.size(ofValue: storage.sun_path)
        guard bytes.count + 1 <= capacity else { throw ControlEndpoint.BindError.pathTooLong }

        let total = ControlSocketAddress.sunPathOffset + bytes.count + 1
        storage.sun_family = sa_family_t(AF_UNIX)
        storage.sun_len = UInt8(total)
        withUnsafeMutablePointer(to: &storage.sun_path) { tuple in
            tuple.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for i in 0..<bytes.count { dst[i] = bytes[i] }
                dst[bytes.count] = 0
            }
        }
        self.length = socklen_t(total)
    }

    /// The value written into `sun_len`.
    public var sunLen: UInt8 { storage.sun_len }

    /// Call `body` with a correctly-typed `sockaddr` pointer and the exact length.
    public func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        var copy = storage
        return withUnsafePointer(to: &copy) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}

/// The exact filesystem identity of a bound socket: its device and inode. Teardown unlinks **only** when
/// the name at the path still resolves to this same object, so a socket a *different* server rebound in
/// the meantime is never removed.
struct SocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

/// A listening `AF_UNIX` socket the app owns, plus the verified directory descriptor and the identity
/// needed to remove it safely. `remove()` is the orderly-shutdown teardown; it is idempotent.
public final class BoundSocket {
    /// The listening descriptor. Task 2 drives `accept`/read/write on it.
    public let fileDescriptor: Int32
    /// The verified private directory the socket lives in, kept open so teardown can `unlinkat` relative
    /// to it rather than re-resolving a path that could have been swapped.
    let directoryFD: Int32
    let socketName: String
    /// The absolute socket path (for callers that log it or `stat` it).
    public let path: String
    let identity: SocketIdentity
    private var removed = false

    init(fileDescriptor: Int32, directoryFD: Int32, socketName: String, path: String,
         identity: SocketIdentity) {
        self.fileDescriptor = fileDescriptor
        self.directoryFD = directoryFD
        self.socketName = socketName
        self.path = path
        self.identity = identity
    }

    /// Orderly teardown: `unlinkat` the socket **only if it is still the exact device/inode this server
    /// created** (never a regular file, a symlink, or a socket a later server rebound), then close the
    /// listening and directory descriptors. Idempotent.
    public func remove() {
        guard !removed else { return }
        removed = true
        var st = stat()
        if fstatat(directoryFD, socketName, &st, AT_SYMLINK_NOFOLLOW) == 0,
           Int(st.st_mode) & Int(S_IFMT) == Int(S_IFSOCK),
           st.st_dev == identity.device, st.st_ino == identity.inode {
            _ = unlinkat(directoryFD, socketName, 0)
        }
        close(fileDescriptor)
        close(directoryFD)
    }
}

/// Binds the app's Unix control socket **safely**: the right flavor-specific path, inside a verified
/// `0700` current-UID-owned directory, under a `flock`-held initialization lock, with exact
/// stale-socket recovery that never severs a live server and never removes a non-socket.
///
/// **The trust boundary is the filesystem and only that.** A `0600` socket in a `0700` user-private
/// directory *is* the boundary: no other UID can enter the directory, and same-UID processes are trusted
/// (they can already act as the user). The inspect→unlink of a stale socket is deliberately **not**
/// atomic; it is safe *only* under that model — the verified `0700` parent excludes other UIDs, so the
/// only actor that could race the unlink is a same-UID process, which is trusted.
public struct ControlEndpoint {
    public enum BindError: Error, Equatable, Sendable {
        /// The path's UTF-8 byte length + NUL exceeds `sun_path`.
        case pathTooLong
        /// The path contained an embedded NUL.
        case embeddedNul
        /// The private directory could not be created.
        case directoryCreateFailed(errno: Int32)
        /// The path's parent is not a real, current-UID-owned `0700` directory (a symlink, a foreign
        /// owner, or not a directory at all).
        case directoryNotPrivate
        /// The initialization lock could not be acquired.
        case lockUnavailable
        /// The lock file is not a current-UID-owned regular file with a restrictive mode.
        case lockFileInvalid
        /// The path is occupied by a **live** server, or by an object that must not be removed.
        case addressInUse
        /// `bind` failed for a reason other than a recoverable stale socket.
        case bindFailed(errno: Int32)
        /// `listen` failed.
        case listenFailed(errno: Int32)
        /// The bound socket did not pass its post-bind type/owner/mode verification.
        case verificationFailed
    }

    /// The listen backlog, matched to Task 2's connection cap.
    private static let listenBacklog: Int32 = 16

    /// The absolute socket path.
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// The production endpoint: `~/Library/Application Support/<bundle-id>/control.sock`, flavor-specific
    /// through `Bundle.main.bundleIdentifier` (falling back to `AppInfo.bundleID` outside a bundle, as
    /// `BuildFlavor.logSubsystem` does).
    public static func live() -> ControlEndpoint {
        let id = Bundle.main.bundleIdentifier ?? AppInfo.bundleID
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(id)/control.sock")
        return ControlEndpoint(socketPath: url.path)
    }

    var directoryPath: String { (socketPath as NSString).deletingLastPathComponent }
    var socketName: String { (socketPath as NSString).lastPathComponent }
    /// A sibling lock file guarding the whole init sequence.
    private var lockName: String { "control.lock" }

    /// Create/verify the directory, hold the init lock, (stale-)bind, `chmod 0600`, verify and `listen`.
    /// Returns a `BoundSocket` on success; throws a `BindError` otherwise, leaving no descriptor open.
    public func bind() throws -> BoundSocket {
        // Validate + encode the address first, before any filesystem side effect.
        let address = try ControlSocketAddress(path: socketPath)

        let dirFD = try openPrivateDirectory()
        var handedOff = false
        defer { if !handedOff { close(dirFD) } }

        // Hold the initialization lock across the WHOLE probe → unlink → bind → chmod → verify → listen
        // sequence; release only after `listen()`.
        let lockFD = try acquireInitLock(dirFD: dirFD)
        defer { close(lockFD) }

        let sockFD = try bindSocket(dirFD: dirFD, address: address)
        do {
            // The bind→chmod window may briefly leave the socket at the process umask; acceptable ONLY
            // because the `0700` parent excludes other UIDs. Do not rely on `chmod` being atomic with
            // `bind`.
            guard fchmodat(dirFD, socketName, 0o600, 0) == 0 else {
                throw BindError.bindFailed(errno: errno)
            }
            let identity = try verifyBoundSocket(dirFD: dirFD)
            guard listen(sockFD, ControlEndpoint.listenBacklog) == 0 else {
                throw BindError.listenFailed(errno: errno)
            }
            handedOff = true
            return BoundSocket(fileDescriptor: sockFD, directoryFD: dirFD,
                               socketName: socketName, path: socketPath, identity: identity)
        } catch {
            removeOwnSocket(dirFD: dirFD)
            close(sockFD)
            throw error
        }
    }

    // MARK: - Directory

    /// Create the private directory if absent (`0700`), then open it with `O_DIRECTORY | O_NOFOLLOW`
    /// (rejecting a symlink) and `fstat` to confirm a real, current-UID-owned directory, normalising its
    /// mode to `0700`.
    private func openPrivateDirectory() throws -> Int32 {
        let parent = (directoryPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if mkdir(directoryPath, 0o700) != 0 && errno != EEXIST {
            throw BindError.directoryCreateFailed(errno: errno)
        }
        let fd = open(directoryPath, O_DIRECTORY | O_NOFOLLOW | O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw BindError.directoryNotPrivate }
        var st = stat()
        guard fstat(fd, &st) == 0,
              Int(st.st_mode) & Int(S_IFMT) == Int(S_IFDIR),
              st.st_uid == getuid() else {
            close(fd)
            throw BindError.directoryNotPrivate
        }
        if Int(st.st_mode) & 0o777 != 0o700, fchmod(fd, 0o700) != 0 {
            close(fd)
            throw BindError.directoryNotPrivate
        }
        guard fstat(fd, &st) == 0, Int(st.st_mode) & 0o777 == 0o700 else {
            close(fd)
            throw BindError.directoryNotPrivate
        }
        return fd
    }

    // MARK: - Init lock

    /// Open the lock file relative to the verified directory with `O_NOFOLLOW`, confirm it is a
    /// current-UID regular file with a restrictive mode, and hold `flock(LOCK_EX)` (blocking — a dead
    /// holder's lock is auto-released), re-validating after acquisition.
    private func acquireInitLock(dirFD: Int32) throws -> Int32 {
        let fd = openat(dirFD, lockName, O_RDONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BindError.lockFileInvalid }
        func valid() -> Bool {
            var st = stat()
            guard fstat(fd, &st) == 0 else { return false }
            return Int(st.st_mode) & Int(S_IFMT) == Int(S_IFREG)
                && st.st_uid == getuid()
                && Int(st.st_mode) & 0o077 == 0
        }
        guard valid() else { close(fd); throw BindError.lockFileInvalid }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            close(fd)
            throw BindError.lockUnavailable
        }
        guard valid() else { close(fd); throw BindError.lockFileInvalid }
        return fd
    }

    // MARK: - Bind + stale recovery

    /// `bind`, recovering from a **stale** socket exactly: on `EADDRINUSE`, a short `connect` decides.
    /// A successful connect means a live server (refuse, unlink nothing). Only a connect that fails
    /// **specifically** with `ECONNREFUSED` — never a timeout, `EACCES`, `EINPROGRESS` or the unknown —
    /// permits inspecting the path and unlinking it, and even then **only if it is a current-UID socket**
    /// (never a regular file or a symlink), after which `bind` is retried exactly once.
    private func bindSocket(dirFD: Int32, address: ControlSocketAddress) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BindError.bindFailed(errno: errno) }
        setCloexec(fd)
        do {
            if try attemptBind(fd, address) { return fd }
            // Occupied. Decide live vs. stale.
            switch probe(address) {
            case .refused:
                var st = stat()
                guard fstatat(dirFD, socketName, &st, AT_SYMLINK_NOFOLLOW) == 0,
                      Int(st.st_mode) & Int(S_IFMT) == Int(S_IFSOCK),
                      st.st_uid == getuid() else {
                    // Not a socket we own — never remove it.
                    throw BindError.addressInUse
                }
                guard unlinkat(dirFD, socketName, 0) == 0 else {
                    throw BindError.bindFailed(errno: errno)
                }
                if try attemptBind(fd, address) { return fd }
                throw BindError.bindFailed(errno: errno)
            case .alive, .other:
                throw BindError.addressInUse
            }
        } catch {
            close(fd)
            throw error
        }
    }

    /// `true` on a clean bind, `false` on `EADDRINUSE` (occupied — the caller decides), throws otherwise.
    private func attemptBind(_ fd: Int32, _ address: ControlSocketAddress) throws -> Bool {
        let rc = address.withSockaddr { sa, len in Darwin.bind(fd, sa, len) }
        if rc == 0 { return true }
        let e = errno
        if e == EADDRINUSE { return false }
        throw BindError.bindFailed(errno: e)
    }

    private enum ProbeResult { case alive, refused, other }

    /// A short, non-blocking `connect` to classify the occupant.
    private func probe(_ address: ControlSocketAddress) -> ProbeResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .other }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = address.withSockaddr { sa, len in connect(fd, sa, len) }
        if rc == 0 { return .alive }
        return errno == ECONNREFUSED ? .refused : .other
    }

    // MARK: - Verify + cleanup

    /// After `chmod`, verify the bound object's **type, owner and mode**, and capture its device/inode
    /// so orderly shutdown can unlink exactly this object and no other.
    private func verifyBoundSocket(dirFD: Int32) throws -> SocketIdentity {
        var st = stat()
        guard fstatat(dirFD, socketName, &st, AT_SYMLINK_NOFOLLOW) == 0,
              Int(st.st_mode) & Int(S_IFMT) == Int(S_IFSOCK),
              st.st_uid == getuid(),
              Int(st.st_mode) & 0o777 == 0o600 else {
            throw BindError.verificationFailed
        }
        return SocketIdentity(device: st.st_dev, inode: st.st_ino)
    }

    /// Best-effort cleanup on a mid-bind failure: remove the socket only if it is a current-UID socket
    /// (the same guard teardown uses), never a foreign object.
    private func removeOwnSocket(dirFD: Int32) {
        var st = stat()
        if fstatat(dirFD, socketName, &st, AT_SYMLINK_NOFOLLOW) == 0,
           Int(st.st_mode) & Int(S_IFMT) == Int(S_IFSOCK),
           st.st_uid == getuid() {
            _ = unlinkat(dirFD, socketName, 0)
        }
    }

    private func setCloexec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
}
