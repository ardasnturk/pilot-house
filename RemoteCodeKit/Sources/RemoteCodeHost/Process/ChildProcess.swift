import Foundation
import RemoteCodeKit
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// How a child process ended.
public enum ExitStatus: Sendable, Equatable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    public var description: String {
        switch self {
        case .exited(let code): "exit code \(code)"
        case .signaled(let signal): "signal \(signal)"
        }
    }

    public var isSuccess: Bool { self == .exited(0) }
}

public enum ChildProcessError: Error, Sendable, Equatable, CustomStringConvertible {
    case spawnFailed(errno: Int32)
    case pipeFailed(errno: Int32)
    case stdinClosed
    case writeFailed(errno: Int32)

    public var description: String {
        switch self {
        case .spawnFailed(let code): "Could not start the process (\(String(cString: strerror(code))))"
        case .pipeFailed(let code): "Could not create a pipe (\(String(cString: strerror(code))))"
        case .stdinClosed: "The process input is closed"
        case .writeFailed(let code): "Writing to the process failed (\(String(cString: strerror(code))))"
        }
    }
}

/// A child process started with `posix_spawn` in its **own process group**,
/// with piped stdin/stdout/stderr.
///
/// Signals go to the whole group (like Ctrl-C in a terminal), so tools that
/// Claude runs are interrupted together with the CLI. The working directory is
/// applied by a tiny `/bin/sh` trampoline (`cd -- "$1" && exec "$@"`) because
/// `posix_spawn_file_actions_addchdir` is not uniformly available; `exec`
/// keeps the PID, so signals still reach the real program.
public final class ChildProcess: Sendable {
    public let pid: pid_t
    /// Raw stdout chunks; finishes at EOF.
    public let stdout: AsyncStream<Data>
    /// Raw stderr chunks; finishes at EOF.
    public let stderr: AsyncStream<Data>

    private let stdinDescriptor: Mutex<Int32?>
    private let exitState = Mutex<(status: ExitStatus?, waiters: [CheckedContinuation<ExitStatus, Never>])>((nil, []))
    private let writeQueue = DispatchQueue(label: "com.ardasenturk.Pilothouse.child.stdin")

    private init(pid: pid_t, stdin: Int32, stdout: AsyncStream<Data>, stderr: AsyncStream<Data>) {
        self.pid = pid
        stdinDescriptor = Mutex(stdin)
        self.stdout = stdout
        self.stderr = stderr
    }

    deinit {
        stdinDescriptor.withLock { descriptor in
            if let fd = descriptor { close(fd) }
            descriptor = nil
        }
    }

    // MARK: Spawning

    /// Starts `executable` with `arguments` in `workingDirectory`.
    /// `environment` replaces the inherited environment completely.
    public static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws -> ChildProcess {
        #if !canImport(Darwin)
        // Linux has no per-descriptor SIGPIPE switch; never die on a closed pipe.
        signal(SIGPIPE, SIG_IGN)
        #endif

        let stdinPipe = try makePipe()
        let stdoutPipe = try makePipe()
        let stderrPipe = try makePipe()
        let allDescriptors = [stdinPipe.read, stdinPipe.write, stdoutPipe.read, stdoutPipe.write, stderrPipe.read, stderrPipe.write]
        for fd in allDescriptors {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        #if canImport(Darwin)
        _ = fcntl(stdinPipe.write, F_SETNOSIGPIPE, 1)
        #endif

        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var fileActions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&fileActions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe.read, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.write, STDERR_FILENO)

        var flags = Int32(POSIX_SPAWN_SETPGROUP) | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        // Close every descriptor not explicitly mapped above.
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD, SIGUSR1, SIGUSR2] {
            sigaddset(&defaultSignals, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let trampoline = #"cd -- "$1" || exit 126; shift; exec "$@""#
        let argv = ["/bin/sh", "-c", trampoline, "remotecode-launch", workingDirectory, executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let result = withCStringArray(argv) { argvPointers in
            withCStringArray(envp) { envPointers in
                posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, argvPointers, envPointers)
            }
        }
        close(stdinPipe.read)
        close(stdoutPipe.write)
        close(stderrPipe.write)
        guard result == 0 else {
            close(stdinPipe.write)
            close(stdoutPipe.read)
            close(stderrPipe.read)
            throw ChildProcessError.spawnFailed(errno: result)
        }

        let process = ChildProcess(
            pid: pid,
            stdin: stdinPipe.write,
            stdout: readStream(stdoutPipe.read, name: "stdout"),
            stderr: readStream(stderrPipe.read, name: "stderr")
        )
        process.startWaiter()
        return process
    }

    // MARK: Control

    /// Writes `data` to stdin. Writes are performed in call order on a private
    /// queue so a slow reader never blocks the caller's executor.
    public func write(_ data: Data) async throws {
        guard let fd = stdinDescriptor.withLock({ $0 }) else { throw ChildProcessError.stdinClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                continuation.resume(with: Result { try Self.writeAll(data, to: fd) })
            }
        }
    }

    /// Closes stdin (the CLI sees end-of-input).
    public func closeStdin() {
        let fd = stdinDescriptor.withLock { descriptor -> Int32? in
            defer { descriptor = nil }
            return descriptor
        }
        guard let fd else { return }
        // Close on the write queue so queued writes finish first.
        writeQueue.async { close(fd) }
    }

    /// Sends `signal` to the process group (falls back to the process itself).
    public func send(signal: Int32) {
        if kill(-pid, signal) != 0 {
            kill(pid, signal)
        }
    }

    /// SIGTERM, then SIGKILL if the process is still alive after `grace` seconds.
    @discardableResult
    public func terminate(grace: Double = 5) async -> ExitStatus {
        send(signal: SIGTERM)
        if let status = await waitForExit(timeout: grace) { return status }
        send(signal: SIGKILL)
        return await waitForExit()
    }

    public var exitStatus: ExitStatus? {
        exitState.withLock { $0.status }
    }

    /// Suspends until the process exits.
    public func waitForExit() async -> ExitStatus {
        await withCheckedContinuation { continuation in
            let status = exitState.withLock { state -> ExitStatus? in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }

    /// Waits at most `timeout` seconds; `nil` if still running.
    public func waitForExit(timeout: Double) async -> ExitStatus? {
        try? await withTimeout(seconds: timeout) { await self.waitForExit() }
    }

    // MARK: Internals

    private func startWaiter() {
        let pid = self.pid
        let thread = Thread { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 {
                if errno != EINTR {
                    status = 0x7F00  // unknown; report as exit 127
                    break
                }
            }
            let termination: ExitStatus
            let signalNumber = status & 0x7F
            if signalNumber == 0 {
                termination = .exited((status >> 8) & 0xFF)
            } else {
                termination = .signaled(signalNumber)
            }
            guard let self else { return }
            let waiters = self.exitState.withLock { state -> [CheckedContinuation<ExitStatus, Never>] in
                state.status = termination
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume(returning: termination) }
        }
        thread.name = "remotecode.waitpid.\(pid)"
        thread.start()
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw ChildProcessError.pipeFailed(errno: errno) }
        return (descriptors[0], descriptors[1])
    }

    private static func readStream(_ fd: Int32, name: String) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    continuation.yield(Data(buffer[0..<count]))
                } else if count == 0 || errno != EINTR {
                    break
                }
            }
            close(fd)
            continuation.finish()
        }
        thread.name = "remotecode.\(name)"
        thread.start()
        return stream
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                #if canImport(Darwin)
                let written = Darwin.write(fd, pointer, remaining)
                #else
                let written = Glibc.write(fd, pointer, remaining)
                #endif
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw ChildProcessError.writeFailed(errno: errno)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }
}

/// Calls `body` with a NULL-terminated array of C strings.
func withCStringArray<T>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> T) -> T {
    let pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    return body(pointers + [nil])
}

/// Splits a byte stream into newline-terminated UTF-8 lines.
public struct LineSplitter: Sendable {
    private var pending = Data()
    /// Lines longer than this are dropped (protects against runaway output).
    public var maximumLineLength = 64 * 1024 * 1024

    public init() {}

    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
        }
        if pending.count > maximumLineLength { pending = Data() }
        return lines
    }

    /// Returns any trailing text without a newline.
    public mutating func flush() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

extension AsyncStream where Element == Data {
    /// Adapts a byte stream into lines.
    public func lines() -> AsyncStream<String> {
        let source = self
        return AsyncStream<String> { continuation in
            let task = Task {
                var splitter = LineSplitter()
                for await chunk in source {
                    for line in splitter.append(chunk) { continuation.yield(line) }
                }
                if let rest = splitter.flush() { continuation.yield(rest) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Output of `runToCompletion`.
public struct ProcessOutput: Sendable {
    public var status: ExitStatus?
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}

extension ChildProcess {
    /// Runs a short-lived command and collects its output. The process group is
    /// killed if it outlives `timeout`. stdin is closed immediately.
    ///
    /// Output collection gives up two seconds after the process exits, so a
    /// daemon that inherited the pipes (e.g. a shell plugin) cannot hang it.
    public static func runToCompletion(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String = NSHomeDirectory(),
        timeout: Double = 10
    ) async throws -> ProcessOutput {
        let process = try spawn(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory)
        process.closeStdin()
        let stdout = DataAccumulator()
        let stderr = DataAccumulator()
        let readers = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await chunk in process.stdout { stdout.append(chunk) } }
                group.addTask { for await chunk in process.stderr { stderr.append(chunk) } }
            }
        }
        var timedOut = false
        var status = await process.waitForExit(timeout: timeout)
        if status == nil {
            timedOut = true
            process.send(signal: SIGKILL)
            status = await process.waitForExit()
        }
        _ = try? await withTimeout(seconds: 2) { await readers.value }
        return ProcessOutput(
            status: status,
            stdout: stdout.data,
            stderr: stderr.data,
            timedOut: timedOut
        )
    }
}

/// Thread-safe growing byte buffer.
final class DataAccumulator: Sendable {
    private let storage = Mutex(Data())
    func append(_ chunk: Data) { storage.withLock { $0.append(chunk) } }
    var data: Data { storage.withLock { $0 } }
}
