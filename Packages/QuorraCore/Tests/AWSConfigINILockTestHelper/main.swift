import Darwin
import Foundation
import AWSConfigINI

do {
    try AWSConfigINILockTestHelper.run()
} catch {
    fputs("AWSConfigINILockTestHelper: \(error)\n", stderr)
    Darwin.exit(1)
}

private enum AWSConfigINILockTestHelper {
    static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            throw HelperError.usage
        }

        let mode = arguments[1]
        let url = URL(fileURLWithPath: arguments[2])

        switch mode {
        case "hold-lock":
            guard arguments.count == 5, let seconds = TimeInterval(arguments[4]) else {
                throw HelperError.usage
            }
            try holdLock(on: url, readyURL: URL(fileURLWithPath: arguments[3]), seconds: seconds)

        case "increment":
            guard arguments.count == 4, let seconds = TimeInterval(arguments[3]) else {
                throw HelperError.usage
            }
            try incrementCounter(at: url, holdSeconds: seconds)

        default:
            throw HelperError.usage
        }
    }

    private static func holdLock(on url: URL, readyURL: URL, seconds: TimeInterval) throws {
        let fd = try openLockFile(for: url)
        defer { Darwin.close(fd) }

        var lock = wholeFileLock(type: F_WRLCK)
        let result = withUnsafeMutablePointer(to: &lock) { ptr in
            Darwin.fcntl(fd, F_SETLK, ptr)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try Data("ready".utf8).write(to: readyURL)
        Thread.sleep(forTimeInterval: seconds)

        var unlock = wholeFileLock(type: F_UNLCK)
        _ = withUnsafeMutablePointer(to: &unlock) { ptr in
            Darwin.fcntl(fd, F_SETLK, ptr)
        }
    }

    private static func incrementCounter(at url: URL, holdSeconds: TimeInterval) throws {
        try AWSConfigINIDocument.update(at: url, flavor: .config) { doc in
            let current = doc.section("state")?.key("counter")?.intValue() ?? 0
            Thread.sleep(forTimeInterval: holdSeconds)
            doc.update("state") { section in
                section.setKey("counter", value: String(current + 1))
            }
        }
    }

    private static func openLockFile(for url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path + ".lock", O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
        return fd
    }

    private static func wholeFileLock(type: Int32) -> flock {
        var lock = flock()
        lock.l_type = Int16(type)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        return lock
    }

    private enum HelperError: Error {
        case usage
    }
}
