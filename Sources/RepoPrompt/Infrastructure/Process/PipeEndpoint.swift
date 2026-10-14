import Darwin
import Foundation
import os

enum PipeEndpointError: Error, Equatable {
    case devNullUnavailable(errno: Int32)
    case duplicateFailed(errno: Int32)
    case noSigPipeFailed(errno: Int32)

    var errnoValue: Int32 {
        switch self {
        case let .devNullUnavailable(errno), let .duplicateFailed(errno), let .noSigPipeFailed(errno):
            errno
        }
    }
}

/// One end of a child's pipe, owned by the single thread that reads or writes it.
///
/// Only the owner calls `close()`, so the descriptor number stays allocated while the owner may
/// still issue a syscall on it. Any other thread stops the owner's I/O with `retire()`, which
/// replaces the pipe with `/dev/null` under the same number: a blocked `read` wakes and returns 0,
/// a blocked `write` wakes and fails with `EPIPE`, and later syscalls reach `/dev/null` instead of
/// a descriptor the process opened in the meantime. A syscall issued while `dup2` runs can fail
/// with `EBADF`. Dropping the parent's reference to the pipe also gives the child EOF on stdin or
/// `EPIPE` on its output.
///
/// An output endpoint also tracks its backlog: the bytes the pipe held when the drain recorded it,
/// against the bytes the owner has read since.
///
/// The lock covers only `dup2`, `fcntl`, `ioctl`, `close`, and the backlog counters, none of which
/// waits on the child.
final class PipeEndpoint: @unchecked Sendable {
    enum Role {
        /// The parent's write end of the child's stdin.
        case input
        /// The parent's read end of the child's stdout or stderr.
        case output
    }

    private enum State {
        case open
        case retired
        case closed
    }

    let fd: Int32
    private let devNull: Int32
    private let lock = NSLock()
    private var state = State.open
    private var backlog: Int?
    private var backlogBytesRead = 0

    private static let logger = Logger(subsystem: "com.repoprompt.process", category: "PipeEndpoint")
    private static let devNullLock = NSLock()
    /// Opened on first adoption and never closed: every retired endpoint is a duplicate of it.
    private nonisolated(unsafe) static var sharedDevNull: Int32 = -1

    /// `_IOR('f', 127, int)`; Swift does not import the `FIONREAD` macro.
    private static let fionread = UInt(IOC_OUT)
        | (UInt(MemoryLayout<Int32>.size & Int(IOCPARM_MASK)) << 16)
        | (UInt(UInt8(ascii: "f")) << 8)
        | 127

    /// Takes ownership of a duplicate of `handle`'s descriptor and closes `handle`.
    ///
    /// The endpoint owns a duplicate because `ProcessLauncher` creates its handles with
    /// `closeOnDealloc: true`, so a borrowed number would be closed under the owner when the last
    /// copy of the handle is released. Call this before any other thread can see `handle`. When
    /// adoption throws, `handle` is left open for the caller to close.
    init(adopting handle: FileHandle, role: Role) throws {
        devNull = try Self.openSharedDevNull()
        let duplicate = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw PipeEndpointError.duplicateFailed(errno: errno)
        }
        // A write after the child closes stdin must fail with EPIPE instead of raising SIGPIPE,
        // which the XCTest process does not ignore.
        if role == .input, !FDWriteSupport.configureNoSigPipe(fd: duplicate) {
            let failure = errno
            Darwin.close(duplicate)
            throw PipeEndpointError.noSigPipeFailed(errno: failure)
        }
        fd = duplicate
        handle.closeFile()
    }

    var isOpen: Bool {
        lock.withLock { state == .open }
    }

    /// Stops the owner's I/O from any thread without releasing the descriptor number.
    func retire() {
        let failure = lock.withLock { () -> (syscall: String, errno: Int32)? in
            guard state == .open else { return nil }
            var result: Int32
            repeat {
                result = dup2(devNull, fd)
            } while result == -1 && errno == EINTR
            guard result != -1 else {
                return ("dup2", errno)
            }
            // The pipe is already gone from this number, so the endpoint is retired even if the
            // next call fails.
            state = .retired
            // dup2 clears close-on-exec, and a child spawned now must not inherit the descriptor.
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else { return ("fcntl(F_SETFD, FD_CLOEXEC)", errno) }
            return nil
        }
        if let failure {
            let descriptor = fd
            Self.logger.error(
                "\(failure.syscall, privacy: .public) on pipe descriptor \(descriptor, privacy: .public) failed: errno \(failure.errno, privacy: .public)"
            )
        }
    }

    /// Releases the descriptor number. Only the owner calls this, after its last syscall.
    func close() {
        lock.withLock {
            guard state != .closed else { return }
            Darwin.close(fd)
            state = .closed
        }
    }

    /// The pipe's unread byte count, or nil once the endpoint is retired or closed. `FIONREAD`
    /// fails with `ENODEV` on a retired descriptor.
    func bufferedByteCount() -> Int? {
        lock.withLock { unreadBytesLocked() }
    }

    /// Records the pipe's unread bytes as its backlog, which the owner's later reads count against.
    /// Does nothing once the endpoint is retired or closed.
    func recordBacklog() {
        lock.withLock {
            backlog = unreadBytesLocked()
            backlogBytesRead = 0
        }
    }

    /// Asked by the owner before each read. Only a read that begins after the backlog was recorded
    /// counts toward it: an earlier read may have taken its bytes from the pipe before the backlog
    /// was measured. Missing such a read makes the count err high, never low.
    func nextReadCountsTowardBacklog() -> Bool {
        lock.withLock { backlog != nil }
    }

    /// Called by the owner after a read that returned `count` bytes.
    func recordRead(_ count: Int, countsTowardBacklog: Bool) {
        guard countsTowardBacklog else { return }
        lock.withLock { backlogBytesRead += count }
    }

    /// Backlog bytes the owner has not read yet: 0 once it has read them all, and nil when no
    /// backlog was recorded.
    var unreadBacklog: Int? {
        lock.withLock { backlog.map { max($0 - backlogBytesRead, 0) } }
    }

    private func unreadBytesLocked() -> Int? {
        guard state == .open else { return nil }
        var count: Int32 = 0
        guard ioctl(fd, Self.fionread, &count) != -1 else { return nil }
        return Int(count)
    }

    private static func openSharedDevNull() throws -> Int32 {
        try devNullLock.withLock {
            if sharedDevNull >= 0 { return sharedDevNull }
            let descriptor = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw PipeEndpointError.devNullUnavailable(errno: errno)
            }
            sharedDevNull = descriptor
            return descriptor
        }
    }
}
