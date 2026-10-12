import Darwin
import Foundation

/// Runs one child process at a time, in the foreground.
///
/// Bare tool names resolve through `PATH`, so tests can put stubs first.
/// Errors name only the tool, never its arguments or its stderr:
/// some arguments are passwords or key paths.
public enum Shell {
    public enum Output: Sendable, Equatable {
        case inherit
        case discard
        case standardError
        case file(String)
    }

    public enum Errors: Sendable, Equatable {
        case inherit
        case discard
        case merge
    }

    /// Runs a command and returns its exit status.
    /// A status after an uncaught signal is 128 plus the signal number, as in a shell.
    /// `errors` defaults to the same destination as `output`.
    @discardableResult
    public static func run(
        _ arguments: [String],
        output: Output = .inherit,
        errors: Output? = nil,
        environment: [String: String] = [:],
        directory: String? = nil,
        input: Data? = nil
    ) throws -> Int32 {
        let out = try open(output)
        defer { out.map { _ = close($0) } }
        let err = try errors.map(open) ?? out.map(dup)
        defer { err.map { _ = close($0) } }
        let stdin = try inputPipe(input)
        return try wait(start(arguments, stdin: stdin, stdout: out, stderr: err, environment: environment, directory: directory))
    }

    /// Runs a command and returns its standard output.
    public static func capture(
        _ arguments: [String],
        errors: Errors = .inherit,
        environment: [String: String] = [:],
        directory: String? = nil,
        input: Data? = nil
    ) throws -> (status: Int32, output: Data) {
        var ends: [Int32] = [0, 0]
        try require(pipe(&ends) == 0, "Could not create a pipe.")
        let (reader, writer) = (ends[0], ends[1])
        let err: Int32? = switch errors {
        case .inherit: nil
        case .discard: try open(.discard)
        case .merge: dup(writer)
        }
        let stdin = try inputPipe(input)
        let status: Int32
        let data: Data
        do {
            let pid = try start(arguments, stdin: stdin, stdout: writer, stderr: err, environment: environment, directory: directory)
            close(writer)
            err.map { _ = close($0) }
            data = FileHandle(fileDescriptor: reader, closeOnDealloc: true).readDataToEndOfFile()
            status = try wait(pid)
        } catch {
            close(writer)
            close(reader)
            err.map { _ = close($0) }
            throw error
        }
        return (status, data)
    }

    /// Captures standard output and fails when the command fails.
    public static func checked(_ arguments: [String], errors: Errors = .inherit, environment: [String: String] = [:], input: Data? = nil) throws -> Data {
        let result = try capture(arguments, errors: errors, environment: environment, input: input)
        try require(result.status == 0, "\(tool(arguments)) failed (\(result.status)).")
        return result.output
    }

    /// Captured standard output as text without trailing newlines, as `$(...)` gives.
    public static func text(_ arguments: [String], errors: Errors = .inherit, environment: [String: String] = [:]) throws -> String {
        trimmingTrailingNewlines(String(decoding: try checked(arguments, errors: errors, environment: environment), as: UTF8.self))
    }

    /// Runs a command in the foreground and fails when it fails.
    public static func foreground(_ arguments: [String], environment: [String: String] = [:], directory: String? = nil, input: Data? = nil) throws {
        let status = try run(arguments, environment: environment, directory: directory, input: input)
        try require(status == 0, "\(tool(arguments)) exited \(status).")
    }

    /// Finds a bare tool name in `PATH`.
    public static func which(_ name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        if name.contains("/") { return name }
        for directory in (path ?? "/usr/bin:/bin").split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue, access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }

    static func tool(_ arguments: [String]) -> String {
        URL(fileURLWithPath: arguments.first ?? "command").lastPathComponent
    }

    private static func open(_ output: Output) throws -> Int32? {
        let path: String
        switch output {
        case .inherit: return nil
        case .standardError: return dup(2)
        case .discard: path = "/dev/null"
        case .file(let file): path = file
        }
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        try require(descriptor >= 0, "Cannot write \(URL(fileURLWithPath: path).lastPathComponent).")
        return descriptor
    }

    /// Returns the read end of a pipe that a background thread fills with `input`.
    private static func inputPipe(_ input: Data?) throws -> Int32? {
        guard let input else { return nil }
        var ends: [Int32] = [0, 0]
        try require(pipe(&ends) == 0, "Could not create a pipe.")
        let (reader, writer) = (ends[0], ends[1])
        // A child that exits early must not stop this process with SIGPIPE.
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        Thread.detachNewThread {
            input.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(writer, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(writer)
        }
        return reader
    }

    /// Spawns a child and registers it so a signal can stop it.
    /// The descriptor `stdin` belongs to this call.
    private static func start(_ arguments: [String], stdin: Int32?, stdout: Int32?, stderr: Int32?, environment: [String: String], directory: String?) throws -> pid_t {
        defer { stdin.map { _ = close($0) } }
        precondition(!arguments.isEmpty, "A command needs a tool.")
        var merged = ProcessInfo.processInfo.environment
        merged.merge(environment) { $1 }
        guard let executable = which(arguments[0], path: merged["PATH"]) else {
            throw ToolingFailure("\(arguments[0]) was not found in PATH.")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (target, source) in [(Int32(0), stdin), (1, stdout), (2, stderr)] {
            if let source {
                posix_spawn_file_actions_adddup2(&actions, source, target)
            } else {
                posix_spawn_file_actions_addinherit_np(&actions, target)
            }
        }
        if let directory { posix_spawn_file_actions_addchdir(&actions, directory) }

        return try Signals.state.withLock { state throws -> pid_t in
            if case .cancelled(let status) = state.phase { throw Interrupted(status: status) }
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            var defaults = sigset_t()
            sigfillset(&defaults)
            sigdelset(&defaults, SIGKILL)
            sigdelset(&defaults, SIGSTOP)
            if state.phase == .finishing {
                // Cleanup children ignore the signals that the cleanup ignores.
                for number in [SIGINT, SIGTERM, SIGHUP] { sigdelset(&defaults, number) }
            }
            var mask = sigset_t()
            sigemptyset(&mask)
            posix_spawnattr_setsigdefault(&attributes, &defaults)
            posix_spawnattr_setsigmask(&attributes, &mask)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

            let argv = arguments.map { strdup($0) } + [nil]
            let envp = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            var pid: pid_t = 0
            let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            try require(result == 0, "\(tool(arguments)) could not start (\(String(cString: strerror(result)))).")
            state.child = pid
            return pid
        }
    }

    private static func wait(_ pid: pid_t) throws -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR {
                status = 1 << 8
                break
            }
        }
        let signal = status & 0x7f
        let exit = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        try Signals.state.withLock { state in
            state.child = nil
            if case .cancelled(let pending) = state.phase { throw Interrupted(status: pending) }
        }
        return exit
    }
}

public func trimmingTrailingNewlines(_ text: String) -> String {
    var text = Substring(text)
    while let last = text.last, last == "\n" || last == "\r\n" { text = text.dropLast() }
    return String(text)
}
