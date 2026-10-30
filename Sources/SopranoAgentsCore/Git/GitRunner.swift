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
}

/// Runs the git CLI. The one place that builds git command lines, process
/// environments and pipes; everything else goes through `run` or `stream`.
///
/// Interface contract (implemented in Wave A, see docs/ARCHITECTURE.md):
/// - Every invocation is `git --no-pager -c core.quotepath=false -c color.ui=never
///   -c log.showSignature=false -c diff.noprefix=false -c diff.mnemonicPrefix=false
///   -C <directory> <arguments…>`; reads (`isRead: true`) add `--no-optional-locks`
///   and `GIT_OPTIONAL_LOCKS=0` so a refresh never contends with the user's own git.
/// - The environment is the app's environment plus `environmentOverrides`, plus
///   `GIT_TERMINAL_PROMPT=0` (never wait on a TTY), `GIT_EDITOR=true` (no editor
///   prompts; message-taking commands pass messages explicitly), and the askpass
///   variables from `askpassExecutable` when set (`GIT_ASKPASS`, `SSH_ASKPASS`,
///   `SSH_ASKPASS_REQUIRE=force`, `SOPRANO_AGENTS_ASKPASS=1`).
/// - `PATH` = `extraPath` + Homebrew/user tool directories + the inherited PATH, so
///   hooks find node, bun, etc. even though GUI apps start with a minimal PATH.
/// - stdout and stderr are drained concurrently (no pipe-buffer deadlock on large
///   output); cancellation of the calling Task terminates the process.
/// - Exit codes outside `acceptedExitCodes` throw `GitError` with both streams.
public struct GitRunner: Sendable {
    public var executable: URL
    public var environmentOverrides: [String: String]
    public var extraPath: [String]
    /// Executable git calls back for passwords/passphrases (the app binary in
    /// askpass mode). nil disables askpass (tests).
    public var askpassExecutable: URL?

    public init(
        executable: URL,
        environmentOverrides: [String: String] = [:],
        extraPath: [String] = [],
        askpassExecutable: URL? = nil
    ) {
        self.executable = executable
        self.environmentOverrides = environmentOverrides
        self.extraPath = extraPath
        self.askpassExecutable = askpassExecutable
    }

    /// `preferredPath` (settings `git.path`) if executable, else
    /// /opt/homebrew/bin/git, /usr/local/bin/git, then /usr/bin/git only when the
    /// Command Line Tools or Xcode provide a real git (avoids the install-dialog shim).
    public static func resolveExecutable(preferredPath: String?) -> URL? {
        let fileManager = FileManager.default
        if let preferredPath, !preferredPath.isEmpty {
            let path = (preferredPath as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
            where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // /usr/bin/git is a shim that pops an install dialog unless the
        // developer tools it forwards to exist.
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
        isRead: Bool = false,
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> GitResult {
        try await execute(
            arguments, in: directory, stdin: stdin, isRead: isRead,
            acceptedExitCodes: acceptedExitCodes, onProgress: nil
        )
    }

    /// Like `run`, reporting each stderr progress line as it arrives (git's
    /// `--progress` output splits on both "\r" and "\n"). For fetch/pull/push/clone.
    @discardableResult
    public func stream(
        _ arguments: [String],
        in directory: URL,
        acceptedExitCodes: Set<Int32> = [0],
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> GitResult {
        try await execute(
            arguments, in: directory, stdin: nil, isRead: false,
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
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
        ]
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
        isRead: Bool,
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        var environment = inherited
        for key in Self.repositoryLocationVariables { environment[key] = nil }
        environment.merge(environmentOverrides) { _, override in override }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "true"
        if isRead { environment["GIT_OPTIONAL_LOCKS"] = "0" }
        if let askpassExecutable {
            environment["GIT_ASKPASS"] = askpassExecutable.path
            environment["SSH_ASKPASS"] = askpassExecutable.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["SOPRANO_AGENTS_ASKPASS"] = "1"
        }
        let inheritedPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let path = (extraPath + Self.toolDirectories(home: home) + inheritedPath).filter { entry in
            !entry.isEmpty && seen.insert(entry).inserted
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    private func execute(
        _ arguments: [String],
        in directory: URL,
        stdin: Data?,
        isRead: Bool,
        acceptedExitCodes: Set<Int32>,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> GitResult {
        try Task.checkCancellation()
        let process = GitProcess(
            executable: executable,
            arguments: commandLine(arguments, in: directory, isRead: isRead),
            environment: environment(isRead: isRead),
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
