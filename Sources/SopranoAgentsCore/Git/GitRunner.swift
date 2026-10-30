import Foundation

/// Output of one git invocation.
public struct GitResult: Sendable, Hashable {
    public var stdout: Data
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: Data, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    /// stdout without surrounding whitespace and newlines.
    public var trimmed: String { stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Runs the git CLI. The one place that builds git command lines, process
/// environments and pipes; everything else goes through `run` or `stream`.
///
/// - Every invocation is `git --no-pager -c core.quotepath=false -c color.ui=never
///   -c log.showSignature=false -c diff.noprefix=false -c diff.mnemonicPrefix=false
///   -C <directory> <arguments…>`; reads (`isRead: true`) add `--no-optional-locks`
///   and `GIT_OPTIONAL_LOCKS=0` so a refresh never contends with the user's own git.
/// - The environment is the app's environment without repository-location
///   variables, plus `environmentOverrides`, plus the call's `environment`, plus
///   `GIT_TERMINAL_PROMPT=0` (never wait on a TTY) and `GIT_EDITOR=true` (no editor
///   prompts; message-taking commands pass messages explicitly).
/// - `PATH` = Homebrew/user tool directories + the inherited PATH, so hooks find
///   node, bun, etc. even though GUI apps start with a minimal PATH.
/// - stdout and stderr are drained concurrently (no pipe-buffer deadlock on large
///   output); cancellation of the calling Task terminates the process.
/// - Exit codes outside `acceptedExitCodes` throw `GitError` with both streams.
public struct GitRunner: Sendable {
    public var executable: URL
    /// Applied to every invocation (tests isolate HOME and the git config here).
    public var environmentOverrides: [String: String]

    public init(executable: URL, environmentOverrides: [String: String] = [:]) {
        self.executable = executable
        self.environmentOverrides = environmentOverrides
    }

    /// Homebrew's git (/opt/homebrew, /usr/local), then /usr/bin/git when the
    /// Command Line Tools or Xcode provide a real git behind the shim (otherwise it
    /// pops an install dialog).
    public static func resolveExecutable() -> URL? {
        let fileManager = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
            where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let developerToolGits = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        if developerToolGits.contains(where: fileManager.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: "/usr/bin/git")
        }
        return nil
    }

    /// Runs git to completion and returns its output.
    @discardableResult
    public func run(
        _ arguments: [String],
        in directory: URL,
        stdin: Data? = nil,
        environment: [String: String] = [:],
        isRead: Bool = false,
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> GitResult {
        try await execute(
            arguments, in: directory, stdin: stdin, environment: environment, isRead: isRead,
            acceptedExitCodes: acceptedExitCodes, onProgress: nil
        )
    }

    /// Like `run`, reporting each stderr line as it arrives (git's `--progress`
    /// output and hook output split on both "\r" and "\n"). For commit and push.
    @discardableResult
    public func stream(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String] = [:],
        acceptedExitCodes: Set<Int32> = [0],
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> GitResult {
        try await execute(
            arguments, in: directory, stdin: nil, environment: environment, isRead: false,
            acceptedExitCodes: acceptedExitCodes, onProgress: onProgress
        )
    }

    // MARK: Command line and environment

    /// Options every invocation starts with.
    static let baseOptions = [
        "--no-pager",
        "-c", "core.quotepath=false",
        "-c", "color.ui=never",
        "-c", "log.showSignature=false",
        "-c", "diff.noprefix=false",
        "-c", "diff.mnemonicPrefix=false",
    ]

    /// Tool directories GUI apps miss from their launchd PATH, so hooks find
    /// node, bun, cargo-installed tools, etc.
    static func toolDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
        ]
    }

    /// `toolDirectories` followed by `inheritedPath`, without duplicates.
    static func searchPath(inheritedPath: String?, home: String) -> [String] {
        let inherited = (inheritedPath ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (toolDirectories(home: home) + inherited).filter { entry in
            !entry.isEmpty && seen.insert(entry).inserted
        }
    }

    /// Variables that would point git at another repository than `-C`'s.
    private static let repositoryLocationVariables = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
    ]

    func commandLine(_ arguments: [String], in directory: URL, isRead: Bool) -> [String] {
        var line = Self.baseOptions
        if isRead { line.append("--no-optional-locks") }
        line += ["-C", directory.path]
        line += arguments
        return line
    }

    func environment(
        call: [String: String] = [:],
        isRead: Bool,
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        var environment = inherited
        for key in Self.repositoryLocationVariables { environment[key] = nil }
        environment.merge(environmentOverrides) { _, override in override }
        environment.merge(call) { _, override in override }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "true"
        if isRead { environment["GIT_OPTIONAL_LOCKS"] = "0" }
        environment["PATH"] = Self.searchPath(inheritedPath: environment["PATH"], home: home).joined(separator: ":")
        return environment
    }

    private func execute(
        _ arguments: [String],
        in directory: URL,
        stdin: Data?,
        environment callEnvironment: [String: String],
        isRead: Bool,
        acceptedExitCodes: Set<Int32>,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> GitResult {
        try Task.checkCancellation()
        let process = GitProcess(
            executable: executable,
            arguments: commandLine(arguments, in: directory, isRead: isRead),
            environment: environment(call: callEnvironment, isRead: isRead),
            directory: nil,
            input: stdin,
            onStderrLine: onProgress
        )
        let output = try await process.run()
        let result = GitResult(
            stdout: output.stdout,
            stderr: String(decoding: output.stderr, as: UTF8.self),
            exitCode: output.exitCode
        )
        guard acceptedExitCodes.contains(result.exitCode) else {
            throw GitError(
                arguments: arguments, exitCode: result.exitCode,
                stdout: result.stdoutString, stderr: result.stderr
            )
        }
        return result
    }
}
