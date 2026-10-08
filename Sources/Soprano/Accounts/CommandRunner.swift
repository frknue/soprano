import Foundation

/// Output of a finished command.
struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }

    /// The last non-empty stderr line, else stdout's: what a CLI says when it fails.
    var failureMessage: String {
        for stream in [stderr, stdout] {
            let lines = CommandRunner.strippingTerminalCodes(stream)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let last = lines.last { return last }
        }
        return "exited with status \(status)"
    }

    /// `failureMessage`, except that `env`'s "not found" (status 127) names
    /// the missing CLI instead.
    func failureMessage(running command: String) -> String {
        status == 127 ? "\(command) is not installed or not on the login shell's PATH." : failureMessage
    }
}

enum CommandError: LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): return "Could not start the command: \(reason)"
        case .timedOut: return "The command took too long and was stopped."
        case .cancelled: return "Cancelled."
        }
    }
}

/// Runs the agent CLIs (`claude`, `codex`, `omp`) the way agent panes start
/// them — through the user's interactive login shell, so PATH and environment
/// match — and plain executables such as `/usr/bin/security`.
struct CommandRunner: Sendable {
    /// The login shell agent panes use.
    var shell: String = DefaultAgents.terminal.command

    /// Marks where the rc files' output ends and the command's begins on
    /// stderr (ASCII record separator): prompt themes complain on stderr when
    /// there is no terminal, and that must not pass for the command's error.
    static let commandStartMarker = "\u{1E}"

    /// Runs `arguments` through `shell -lic`. `environment` is applied with
    /// `exec env` *after* the rc files ran, so a profile that exports, say,
    /// `CODEX_HOME` cannot redirect a managed login.
    func runCLI(
        _ arguments: [String],
        environment overrides: [String: String] = [:],
        timeout: TimeInterval,
        keepStandardInputOpen: Bool = false,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let assignments = overrides.keys.sorted().map { "\($0)=\(overrides[$0] ?? "")" }
        let command = (assignments + arguments).map(Self.shellQuoted).joined(separator: " ")
        let script = "printf '\\036' >&2; exec env \(command)"
        let result = try await run(
            executable: shell,
            arguments: ["-lic", script],
            environment: Self.backgroundEnvironment(),
            keepStandardInputOpen: keepStandardInputOpen,
            timeout: timeout,
            onOutputLine: onOutputLine
        )
        guard let marker = result.stderr.range(of: Self.commandStartMarker, options: .backwards) else {
            return result
        }
        return CommandResult(
            status: result.status,
            stdout: result.stdout,
            stderr: String(result.stderr[marker.upperBound...])
        )
    }

    /// Runs `executable` directly. `input`, when given, is written to stdin and
    /// stdin is then closed; `keepStandardInputOpen` leaves stdin open until the
    /// command ends, for CLIs that treat end-of-input as "cancel".
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        input: Data? = nil,
        keepStandardInputOpen: Bool = false,
        timeout: TimeInterval,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let execution = CommandExecution(
            executable: executable,
            arguments: arguments,
            environment: environment,
            input: input,
            keepStandardInputOpen: keepStandardInputOpen,
            timeout: timeout,
            onOutputLine: onOutputLine
        )
        return try await withTaskCancellationHandler {
            try await execution.start()
        } onCancel: {
            execution.cancel()
        }
    }

    /// Soprano's own environment minus its pane variables: a background login
    /// must not report agent events or look like it runs inside a pane.
    static func backgroundEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("SOPRANO_") && key != "TERM_PROGRAM"
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Removes ANSI escape sequences (colors, cursor moves) from CLI output.
    static func strippingTerminalCodes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}(\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|[@-Z\\\\-_])",
            with: "",
            options: .regularExpression
        )
    }

    /// The first `https://` URL in a line of CLI output.
    static func firstURL(in line: String) -> URL? {
        let text = strippingTerminalCodes(line)
        guard let range = text.range(of: "https://[^\\s\"'<>]+", options: .regularExpression) else {
            return nil
        }
        return URL(string: String(text[range]))
    }
}

/// One process run. A class so the cancellation handler, the pipe readers,
/// and the termination handler — each on its own thread — share one state,
/// guarded by `lock`.
private final class CommandExecution: @unchecked Sendable {
    private enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private let process = Process()
    private let input: Data?
    private let keepStandardInputOpen: Bool
    private let timeout: TimeInterval
    private let onOutputLine: (@Sendable (String) -> Void)?

    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var partialLines: [Stream: Data] = [:]
    private var openStreams = 2
    private var hasLaunched = false
    private var hasTerminated = false
    private var isFinished = false
    private var stopReason: CommandError?
    private var standardInput: Pipe?

    init(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        input: Data?,
        keepStandardInputOpen: Bool,
        timeout: TimeInterval,
        onOutputLine: (@Sendable (String) -> Void)?
    ) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        self.input = input
        self.keepStandardInputOpen = keepStandardInputOpen
        self.timeout = timeout
        self.onOutputLine = onOutputLine
    }

    func start() async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let cancelledEarly = stopReason != nil
            lock.unlock()
            if cancelledEarly {
                finish()
                return
            }
            launch()
        }
    }

    func cancel() {
        stop(.cancelled)
    }

    private func launch() {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if input != nil || keepStandardInputOpen {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            lock.lock()
            standardInput = inputPipe
            lock.unlock()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.read(handle, from: .stdout)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.read(handle, from: .stderr)
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
            stopReason = .launchFailed(error.localizedDescription)
            hasTerminated = true
            openStreams = 0
            lock.unlock()
            finish()
            return
        }

        lock.lock()
        hasLaunched = true
        let stoppedDuringLaunch = stopReason != nil
        lock.unlock()
        if stoppedDuringLaunch {
            terminate()
            return
        }

        if let input, let handle = standardInput?.fileHandleForWriting {
            try? handle.write(contentsOf: input)
            if !keepStandardInputOpen {
                try? handle.close()
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.stop(.timedOut)
        }
    }

    private func read(_ handle: FileHandle, from stream: Stream) {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            streamDidClose(stream)
            return
        }
        lock.lock()
        if stream == .stdout { stdout.append(data) } else { stderr.append(data) }
        var buffer = (partialLines[stream] ?? Data()) + data
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        partialLines[stream] = buffer
        lock.unlock()
        if let onOutputLine {
            lines.forEach(onOutputLine)
        }
    }

    private func streamDidClose(_ stream: Stream) {
        lock.lock()
        let remainder = partialLines.removeValue(forKey: stream)
        openStreams -= 1
        let done = openStreams <= 0 && hasTerminated
        lock.unlock()
        if let remainder, !remainder.isEmpty {
            onOutputLine?(String(decoding: remainder, as: UTF8.self))
        }
        if done { finish() }
    }

    private func processDidTerminate() {
        lock.lock()
        hasTerminated = true
        let done = openStreams <= 0
        try? standardInput?.fileHandleForWriting.close()
        lock.unlock()
        if done {
            finish()
        } else {
            // A child the command spawned (a browser opener, say) can hold the
            // pipes open after the command itself exited; don't wait for it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.finish()
            }
        }
    }

    private func stop(_ reason: CommandError) {
        lock.lock()
        guard !isFinished, stopReason == nil else {
            lock.unlock()
            return
        }
        stopReason = reason
        let launched = hasLaunched
        lock.unlock()
        // Before launch, `start` or `launch` sees the reason and never runs it.
        if launched { terminate() }
    }

    /// SIGTERM, then SIGKILL for a command that ignores it.
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
        let reason = stopReason
        let status = hasTerminated && process.processIdentifier != 0 ? process.terminationStatus : -1
        let result = CommandResult(
            status: status,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
        lock.unlock()
        if let reason {
            continuation.resume(throwing: reason)
        } else {
            continuation.resume(returning: result)
        }
    }
}
