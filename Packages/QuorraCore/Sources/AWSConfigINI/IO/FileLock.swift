// FileLock.swift — fcntl advisory file lock wrapper.
//
// M05: Decision D08 — fcntl advisory file lock around read-modify-write.
// Plan §11.2 task 1.
//
// Design notes:
//
// - Lock target is a sibling `.lock` file (e.g. `~/.aws/config.lock`), not the
//   data file itself. This avoids holding a lock on the file we're about to
//   atomically replace via rename(2). fcntl locks are released when the *process*
//   closes the last fd to the file, so if we locked the data file and then called
//   rename(2) over it, the file descriptor would point to the unlinked inode and
//   the new file would be unprotected. The sibling `.lock` file is the
//   permanent coordination point.
//
// - Lock files are intentionally *not* cleaned up after use. The lock file is a
//   synchronization point, not a data file; it's cheap to leave on disk.
//   Cleaning it up reintroduces a TOCTOU window (check-unlink-recreate race).
//   Decision: do not unlink. Plan §11, "Lock file naming" note.
//
// - Acquisition strategy: poll with F_SETLK (non-blocking) at 50 ms intervals
//   until the timeout is exceeded. This avoids F_SETLKW (blocking) which would
//   require integrating with Swift Concurrency cancellation — much harder.
//   CLAUDE.md "Apple-doc grounding" recommends this approach.
//
// - Darwin-specific `flock` struct field layout on macOS (sys/fcntl.h):
//     l_start:  off_t  (Int64) — starting offset for lock
//     l_len:    off_t  (Int64) — number of bytes to lock (0 = to EOF)
//     l_pid:    pid_t  (Int32) — set by F_GETLK; unused for F_SETLK
//     l_type:   Int16         — F_WRLCK / F_RDLCK / F_UNLCK
//     l_whence: Int16         — SEEK_SET / SEEK_CUR / SEEK_END
//   This layout differs from Linux's struct flock64. We use the Darwin form.
//
// - The lock covers the whole file (l_start = 0, l_len = 0, l_whence = SEEK_SET).

import Darwin
import Foundation

/// Namespace for the fcntl advisory file lock.
///
/// All operations work on a *sibling* `.lock` file at `<url>.lock` so that the
/// advisory lock is decoupled from the data file being atomically replaced.
enum FileLock {

    /// Polling interval while waiting to acquire the lock.
    /// 50 ms balances responsiveness against CPU cost.
    private static let pollInterval: TimeInterval = 0.05

    /// Acquires an exclusive fcntl write lock on `<url>.lock`, calls `block`,
    /// then releases the lock.
    ///
    /// - Parameters:
    ///   - url: The data file URL. The lock file is `url.path + ".lock"`.
    ///   - timeout: Maximum time to wait for lock acquisition. Default 5 s.
    ///   - block: The closure to run while the lock is held. May throw an
    ///     `AWSConfigINIError`; that error propagates as-is.
    /// - Returns: The value returned by `block`.
    /// - Throws:
    ///   - `AWSConfigINIError.lockTimeout(url)` if the lock cannot be acquired
    ///     within `timeout`.
    ///   - `AWSConfigINIError.ioError(url, underlying:)` if the lock file
    ///     cannot be opened.
    ///   - Any `AWSConfigINIError` thrown by `block` (re-thrown as-is).
    ///
    /// D20: typed throws across the public API.
    static func exclusive<T>(
        on url: URL,
        timeout: TimeInterval = 5.0,
        _ block: () throws(AWSConfigINIError) -> T
    ) throws(AWSConfigINIError) -> T {
        let lockPath = url.path + ".lock"

        // Open (or create) the sibling lock file.
        // O_CREAT|O_WRONLY|O_CLOEXEC: create if absent, write-only (we only
        // need an fd to lock on), close-on-exec so child processes don't
        // inherit it. Mode 0o644 gives owner read/write, group/other read.
        // Darwin open(2): returns -1 on error and sets errno.
        let fd = Darwin.open(lockPath, O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
            throw .ioError(url, underlying: err)
        }
        defer { Darwin.close(fd) }

        // Build the write-lock request.
        // Whole-file advisory exclusive (write) lock:
        //   l_type   = F_WRLCK (exclusive write lock)
        //   l_whence = SEEK_SET (offset relative to start of file)
        //   l_start  = 0       (start at beginning)
        //   l_len    = 0       (lock to EOF)
        //   l_pid    = 0       (unused for F_SETLK)
        //
        // Darwin sys/fcntl.h: struct flock { off_t l_start; off_t l_len;
        //   pid_t l_pid; short l_type; short l_whence; }
        var fl = flock()
        fl.l_type   = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start  = 0
        fl.l_len    = 0
        fl.l_pid    = 0

        // Poll until acquired or timeout.
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            // F_SETLK: non-blocking attempt. Returns -1 with errno == EAGAIN
            // (or EACCES on some systems) if the lock is held by another process.
            let result = withUnsafeMutablePointer(to: &fl) { ptr in
                Darwin.fcntl(fd, F_SETLK, ptr)
            }
            if result == 0 {
                // Lock acquired.
                break
            }
            let e = errno
            if e == EAGAIN || e == EACCES {
                // Lock is held by another process. Check timeout.
                if Date() >= deadline {
                    throw .lockTimeout(url)
                }
                // Sleep for the poll interval. Thread.sleep is acceptable here
                // because this is a synchronous API — callers are expected to
                // call from a non-main thread or a background Task.
                Foundation.Thread.sleep(forTimeInterval: pollInterval)
                // Reset l_type after the sleep (Darwin preserves it, but be explicit).
                fl.l_type = Int16(F_WRLCK)
            } else {
                // Unexpected error (bad fd, not supported, etc.).
                let err = POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
                throw .ioError(url, underlying: err)
            }
        }

        // Lock is held. Build unlock request for the defer.
        var unlockFl = flock()
        unlockFl.l_type   = Int16(F_UNLCK)
        unlockFl.l_whence = Int16(SEEK_SET)
        unlockFl.l_start  = 0
        unlockFl.l_len    = 0
        unlockFl.l_pid    = 0

        defer {
            // Release the lock regardless of whether block throws.
            // Errors from F_SETLK(F_UNLCK) are ignored — if the fd is closed
            // the kernel releases the lock automatically anyway.
            withUnsafeMutablePointer(to: &unlockFl) { ptr in
                _ = Darwin.fcntl(fd, F_SETLK, ptr)
            }
        }

        return try block()
    }
}
