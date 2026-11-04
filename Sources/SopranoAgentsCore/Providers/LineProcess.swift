import Darwin
import Foundation

/// What a `LineProcess` reports, in order: stdout lines, then exactly one `exited`.
public enum LineProcessEvent: Sendable, Hashable {
    /// One stdout line without its terminator (`\n`, or `\r\n`).
    case line(String)
    /// The process ended. `status` is the exit code, or 128 + signal number when killed.
    /// `stderr` holds the last 64 KB the process wrote there.
    case exited(status: Int32, stderr: String)
}

public enum LineProcessError: Error, LocalizedError, Sendable, Hashable {
    case alreadyStarted
    case notRunning
    case spawnFailed(executable: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: "The process was already started."
        case .notRunning: "The process is not running."
        case let .spawnFailed(executable, code): "\(executable): \(String(cString: strerror(code)))"
        }
    }
}

/// A child process spoken to in newline-delimited text (JSON lines) over stdio.
///
/// - Spawned with `posix_spawn` in its own process group, so `terminate()` reaches every
///   process the agent started (shells, dev servers): SIGTERM to the group, SIGKILL after 2 s.
/// - stdout is split into lines of any length (partial reads are buffered); stderr is drained
///   continuously (no pipe-buffer deadlock) and its last 64 KB kept for error messages.
/// - Writes go through one serial queue, so lines never interleave and the caller never blocks
///   on a full pipe. A closed stdin yields EPIPE, never SIGPIPE.
/// - `events` delivers lines in order and ends with `.exited` once the process is reaped and
///   stdout drained (waits at most 1 s for children that keep stdout open, then signals them).
public final class LineProcess: @unchecked Sendable {
    public struct Configuration: Sendable, Hashable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
        /// Working directory; nil = inherit.
        public var directory: String?

        public init(executable: String, arguments: [String], environment: [String: String], directory: String? = nil) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.directory = directory
        }
    }

    public static let stderrLimit = 64 * 1024
    /// Delay between SIGTERM and SIGKILL in `terminate()`.
    public static let killGrace: TimeInterval = 2

    public let configuration: Configuration
    public let events: AsyncStream<LineProcessEvent>

    private enum State {
        case idle
        case running
        case exited
    }

    private let continuation: AsyncStream<LineProcessEvent>.Continuation
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "SopranoAgents.LineProcess.stdin")
    private let stdoutClosed = DispatchSemaphore(value: 0)
    private let stderrClosed = DispatchSemaphore(value: 0)
    private var state = State.idle
    private var pid: pid_t = 0
    private var stdinFD: Int32 = -1
    private var stderrTailData = Data()
    private var isTerminating = false

    public init(_ configuration: Configuration) {
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream(of: LineProcessEvent.self, bufferingPolicy: .unbounded)
    }

    public var processIdentifier: pid_t? {
        lock.withLock { state == .idle ? nil : pid }
    }

    public var isRunning: Bool {
        lock.withLock { state == .running }
    }

    public var stderrTail: String {
        lock.withLock { String(decoding: stderrTailData, as: UTF8.self) }
    }

    /// Spawns the process. Throws when it cannot be started (missing executable or directory).
    public func start() throws {
        try lock.withLock {
            guard state == .idle else { throw LineProcessError.alreadyStarted }
            let (childPID, input, output, error) = try spawn()
            pid = childPID
            stdinFD = input
            state = .running
            startReader(fd: output, isStdout: true)
            startReader(fd: error, isStdout: false)
            startReaper(pid: childPID)
        }
    }

    /// Writes `line` plus a newline to stdin. Throws when the process is not running.
    public func send(_ line: String) throws {
        var data = Data(line.utf8)
        data.append(0x0A)
        // Enqueued under the lock, so a concurrent `closeInput` queues its close after this write.
        try lock.withLock {
            guard state == .running, stdinFD >= 0 else { throw LineProcessError.notRunning }
            let fd = stdinFD
            writeQueue.async { [data] in Self.writeAll(data, to: fd) }
        }
    }

    /// Closes stdin after every queued write (EOF for the child).
    public func closeInput() {
        lock.withLock {
            let fd = stdinFD
            stdinFD = -1
            guard fd >= 0 else { return }
            writeQueue.async { Darwin.close(fd) }
        }
    }

    /// Closes stdin, sends SIGTERM to the process group, SIGKILL after `killGrace` (also to
    /// children that outlive the leader). Idempotent.
    public func terminate() {
        let target = lock.withLock { () -> pid_t? in
            guard state == .running, !isTerminating else { return nil }
            isTerminating = true
            return pid
        }
        guard let target else { return }
        closeInput()
        kill(-target, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) { [self] in
            // The group id cannot be reused while a member is left; once the leader is reaped,
            // a live process with its pid means the group is gone and that id is someone else's.
            if lock.withLock({ state == .exited }), kill(target, 0) == 0 || errno != ESRCH { return }
            kill(-target, SIGKILL)
        }
    }

    // MARK: - Spawning

    private func spawn() throws -> (pid_t, Int32, Int32, Int32) {
        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0 else { throw LineProcessError.spawnFailed(executable: configuration.executable, errno: errno) }
        guard pipe(&outPipe) == 0 else {
            Self.closeAll(inPipe)
            throw LineProcessError.spawnFailed(executable: configuration.executable, errno: errno)
        }
        guard pipe(&errPipe) == 0 else {
            Self.closeAll(inPipe + outPipe)
            throw LineProcessError.spawnFailed(executable: configuration.executable, errno: errno)
        }
        for fd in [inPipe[1], outPipe[0], errPipe[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        if let directory = configuration.directory {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (pgid = pid); only the three stdio descriptors are inherited;
        // signal mask cleared and the common signals reset to their default dispositions.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([configuration.executable] + configuration.arguments).map { strdup($0) } + [nil]
        let envp = configuration.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var childPID: pid_t = 0
        let result = posix_spawn(&childPID, configuration.executable, &actions, &attributes, argv, envp)
        Self.closeAll([inPipe[0], outPipe[1], errPipe[1]])
        guard result == 0 else {
            Self.closeAll([inPipe[1], outPipe[0], errPipe[0]])
            throw LineProcessError.spawnFailed(executable: configuration.executable, errno: result)
        }
        return (childPID, inPipe[1], outPipe[0], errPipe[0])
    }

    // MARK: - Reading

    private func startReader(fd: Int32, isStdout: Bool) {
        let thread = Thread { [self] in
            if isStdout { readLines(fd: fd) } else { drainStderr(fd: fd) }
            Darwin.close(fd)
            (isStdout ? stdoutClosed : stderrClosed).signal()
        }
        thread.name = isStdout ? "LineProcess.stdout" : "LineProcess.stderr"
        thread.start()
    }

    private func readLines(fd: Int32) {
        var buffer = Data()
        var scanFrom = 0
        let chunkSize = 64 * 1024
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 1)
        defer { chunk.deallocate() }
        while true {
            let count = read(fd, chunk, chunkSize)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(chunk.assumingMemoryBound(to: UInt8.self), count: count)
            var lineStart = buffer.startIndex
            var index = buffer.startIndex + scanFrom
            while let newline = buffer[index...].firstIndex(of: 0x0A) {
                emitLine(buffer[lineStart..<newline])
                lineStart = newline + 1
                index = lineStart
            }
            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
            scanFrom = buffer.count
        }
        if !buffer.isEmpty { emitLine(buffer[...]) }
    }

    private func emitLine(_ bytes: Data) {
        var slice = bytes
        if slice.last == 0x0D { slice = slice.dropLast() }
        continuation.yield(.line(String(decoding: slice, as: UTF8.self)))
    }

    private func drainStderr(fd: Int32) {
        let chunkSize = 16 * 1024
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 1)
        defer { chunk.deallocate() }
        while true {
            let count = read(fd, chunk, chunkSize)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            lock.withLock {
                stderrTailData.append(chunk.assumingMemoryBound(to: UInt8.self), count: count)
                if stderrTailData.count > Self.stderrLimit {
                    stderrTailData.removeSubrange(0..<(stderrTailData.count - Self.stderrLimit))
                }
            }
        }
    }

    private func startReaper(pid childPID: pid_t) {
        let thread = Thread { [self] in
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) == -1, errno == EINTR {}
            let exitStatus = Self.decode(waitStatus: status)
            lock.withLock { state = .exited }
            // Nobody reads stdin any more; a caller that never terminates must not leak it.
            closeInput()
            if stdoutClosed.wait(timeout: .now() + 1) == .timedOut {
                // Children still hold stdout open: end them so the reader finishes.
                kill(-childPID, SIGTERM)
                _ = stdoutClosed.wait(timeout: .now() + 1)
            }
            _ = stderrClosed.wait(timeout: .now() + 0.2)
            continuation.yield(.exited(status: exitStatus, stderr: stderrTail))
            continuation.finish()
        }
        thread.name = "LineProcess.reaper"
        thread.start()
    }

    // MARK: - Helpers

    static func decode(waitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    private static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                remaining -= written
                pointer += written
            }
        }
    }

    private static func closeAll(_ fds: [Int32]) {
        for fd in fds where fd >= 0 { Darwin.close(fd) }
    }
}

extension LineProcess {
    public struct Output: Sendable, Hashable {
        /// stdout lines joined with "\n".
        public var stdout: String
        public var stderr: String
        public var status: Int32
    }

    /// Runs a process to completion: writes `input` to stdin (then EOF) and collects stdout.
    /// Terminates it and throws `ProviderError.timedOut(label)` after `timeout`; cancelling
    /// the calling task terminates it and throws `CancellationError`.
    public static func run(_ configuration: Configuration, input: String? = nil, timeout: TimeInterval, label: String) async throws -> Output {
        let process = LineProcess(configuration)
        try process.start()
        if let input { try? process.send(input) }
        process.closeInput()
        let timedOut = TimeoutFlag()
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            timedOut.fire()
            process.terminate()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            var lines: [String] = []
            for await event in process.events {
                switch event {
                case let .line(line):
                    lines.append(line)
                case let .exited(status, stderr):
                    if timedOut.fired { throw ProviderError.timedOut(label) }
                    try Task.checkCancellation()
                    return Output(stdout: lines.joined(separator: "\n"), stderr: stderr, status: status)
                }
            }
            // The stream also ends early when the calling task is cancelled.
            try Task.checkCancellation()
            throw ProviderError.timedOut(label)
        } onCancel: {
            process.terminate()
        }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var fired: Bool { lock.withLock { value } }
    func fire() { lock.withLock { value = true } }
}
