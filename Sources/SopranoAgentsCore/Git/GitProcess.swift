import Foundation

/// What one finished git process produced.
struct GitProcessOutput: Sendable {
    var stdout: Data
    var stderr: Data
    var exitCode: Int32
}

/// One git process run. A class so the cancellation handler, the two pipe
/// readers, the stdin writer and the termination handler (each on its own
/// thread) share one state, guarded by `lock`. Modeled on Soprano's
/// `CommandExecution`.
final class GitProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input: Data?
    /// Called with each stderr line, split on "\r" and "\n" (git progress).
    private let onStderrLine: (@Sendable (String) -> Void)?

    private var continuation: CheckedContinuation<GitProcessOutput, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var partialStderrLine = Data()
    private var openStreams = 2
    private var hasLaunched = false
    private var hasTerminated = false
    private var isFinished = false
    private var isCancelled = false
    private var launchError: String?
    /// Last time either pipe delivered data; the post-exit idle check waits
    /// for the pipes to go quiet instead of cutting off output still arriving.
    private var lastActivity = DispatchTime.now()

    /// How long the pipes must stay quiet after git exited before a child
    /// process still holding them open is no longer waited for.
    static let pipeIdleTimeout: Double = 0.5

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        directory: URL?,
        input: Data?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        self.input = input
        self.onStderrLine = onStderrLine
    }

    /// Launches the process and waits for it and both of its output streams.
    /// Cancelling the calling task terminates the process and throws
    /// `CancellationError`.
    func run() async throws -> GitProcessOutput {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let cancelledEarly = isCancelled
                lock.unlock()
                if cancelledEarly {
                    finish()
                } else {
                    launch()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        lock.lock()
        guard !isFinished, !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let launched = hasLaunched && !hasTerminated
        lock.unlock()
        // Before launch, `run` or `launch` sees the flag and never starts git.
        if launched { terminate() }
    }

    private func launch() {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let inputPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            // A git that exits before reading all of stdin must not kill the
            // app with SIGPIPE; the write fails with EPIPE instead.
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inputPipe = nil
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.read(handle, isStdout: true)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.read(handle, isStdout: false)
        }
        process.terminationHandler = { [weak self] _ in
            self?.processDidTerminate()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            launchError = error.localizedDescription
            hasTerminated = true
            openStreams = 0
            lock.unlock()
            finish()
            return
        }

        lock.lock()
        hasLaunched = true
        let cancelledDuringLaunch = isCancelled
        lock.unlock()
        if cancelledDuringLaunch { terminate() }

        if let input, let inputPipe {
            // Written off the caller's thread: a large patch fills the pipe
            // buffer until git reads it, while the readers drain its output.
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = inputPipe.fileHandleForWriting
                try? handle.write(contentsOf: input)
                try? handle.close()
            }
        }
    }

    private func read(_ handle: FileHandle, isStdout: Bool) {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            streamDidClose(isStdout: isStdout)
            return
        }
        var lines: [String] = []
        lock.lock()
        lastActivity = .now()
        if isStdout {
            stdout.append(data)
        } else {
            stderr.append(data)
            if onStderrLine != nil {
                partialStderrLine.append(data)
                lines = Self.takeLines(from: &partialStderrLine)
            }
        }
        lock.unlock()
        if let onStderrLine {
            lines.forEach(onStderrLine)
        }
    }

    /// Removes complete lines (ended by "\r" or "\n") from `buffer`, skipping
    /// empty ones.
    static func takeLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        var lineStart = buffer.startIndex
        for index in buffer.indices where buffer[index] == 0x0A || buffer[index] == 0x0D {
            if index > lineStart {
                lines.append(String(decoding: buffer[lineStart..<index], as: UTF8.self))
            }
            lineStart = buffer.index(after: index)
        }
        buffer = Data(buffer[lineStart...])
        return lines
    }

    private func streamDidClose(isStdout: Bool) {
        lock.lock()
        var remainder = Data()
        if !isStdout {
            remainder = partialStderrLine
            partialStderrLine = Data()
        }
        openStreams -= 1
        let done = openStreams <= 0 && hasTerminated
        lock.unlock()
        if let onStderrLine, !remainder.isEmpty {
            onStderrLine(String(decoding: remainder, as: UTF8.self))
        }
        if done { finish() }
    }

    private func processDidTerminate() {
        lock.lock()
        hasTerminated = true
        let done = openStreams <= 0
        lock.unlock()
        if done {
            finish()
        } else {
            // A child git spawned (an ssh ControlMaster, a hook's daemon) can
            // hold the pipes open after git itself exited; stop waiting once
            // they have been quiet for a while, but never while data still flows.
            scheduleIdleCheck()
        }
    }

    private func scheduleIdleCheck() {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.pipeIdleTimeout) { [weak self] in
            self?.checkIdlePipes()
        }
    }

    private func checkIdlePipes() {
        lock.lock()
        let quietFor = Double(DispatchTime.now().uptimeNanoseconds - lastActivity.uptimeNanoseconds) / 1_000_000_000
        let shouldFinish = !isFinished && quietFor >= Self.pipeIdleTimeout
        let shouldWait = !isFinished && !shouldFinish
        lock.unlock()
        if shouldFinish {
            finish()
        } else if shouldWait {
            scheduleIdleCheck()
        }
    }

    /// SIGTERM, then SIGKILL for a process that ignores it.
    private func terminate() {
        let processIdentifier = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if kill(processIdentifier, 0) == 0 {
                kill(processIdentifier, SIGKILL)
            }
        }
    }

    private func finish() {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        let launchError = launchError
        let cancelled = isCancelled
        // The termination handler can fire before `run()` returns and sets
        // `hasLaunched`; a terminated process without a launch error is real.
        let status = hasTerminated && launchError == nil ? process.terminationStatus : -1
        let output = GitProcessOutput(stdout: stdout, stderr: stderr, exitCode: status)
        // A final progress line without a newline is still a line.
        let remainder = partialStderrLine
        partialStderrLine = Data()
        lock.unlock()
        if let onStderrLine, !remainder.isEmpty {
            onStderrLine(String(decoding: remainder, as: UTF8.self))
        }
        if let launchError {
            continuation.resume(throwing: GitSetupError.launchFailed(launchError))
        } else if cancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume(returning: output)
        }
    }
}
