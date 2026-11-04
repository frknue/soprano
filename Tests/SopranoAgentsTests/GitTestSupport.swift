import AppKit
@testable import SopranoAgentsCore

/// A temporary directory with an isolated git configuration (HOME, global config, no
/// system config), for tests that run real git. Never reads the user's config or repositories.
struct GitSandbox: Sendable {
    let directory: URL
    let runner: GitRunner

    init() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("sa-git-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // /var → /private/var, so paths compare equal to git's realpath output.
        let resolved = URL(fileURLWithPath: LiveGitService.canonicalPath(directory.path), isDirectory: true)
        let config = """
        [user]
        \tname = Test Author
        \temail = test@example.com
        [init]
        \tdefaultBranch = main
        [commit]
        \tgpgsign = false
        [tag]
        \tgpgsign = false
        [core]
        \tautocrlf = false
        [advice]
        \tdetachedHead = false
        [protocol "file"]
        \tallow = always

        """
        try config.write(to: resolved.appendingPathComponent("gitconfig"), atomically: true, encoding: .utf8)
        self.directory = resolved
        self.runner = GitRunner(
            executable: GitRunner.resolveExecutable()!,
            environmentOverrides: [
                "HOME": resolved.path,
                "XDG_CONFIG_HOME": resolved.appendingPathComponent(".config").path,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": resolved.appendingPathComponent("gitconfig").path,
                "LC_ALL": "C",
            ]
        )
    }

    /// The service under test; gh is never used.
    var service: LiveGitService { LiveGitService(runner: runner, gh: nil) }

    func url(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: true)
    }

    /// `git init` of `name` inside the sandbox.
    func repository(_ name: String = "repo") async throws -> GitScript {
        let root = url(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await runner.run(["init", "--quiet"], in: root)
        return GitScript(root: root, runner: runner)
    }

    /// A bare repository to push to.
    func bareRemote(_ name: String = "remote.git") async throws -> URL {
        let root = url(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await runner.run(["init", "--quiet", "--bare"], in: root)
        return root
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Small helpers for setting up files and history in a sandbox repository.
struct GitScript: Sendable {
    let root: URL
    let runner: GitRunner

    var path: String { root.path }

    @discardableResult
    func git(_ arguments: String...) async throws -> GitResult {
        try await runner.run(arguments, in: root)
    }

    /// Trimmed stdout of a git command.
    func output(_ arguments: String...) async throws -> String {
        try await runner.run(arguments, in: root).trimmed
    }

    func write(_ path: String, _ contents: String) throws {
        try write(path, Data(contents.utf8))
    }

    func write(_ path: String, _ data: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func delete(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
    }

    /// Writes `files`, stages everything and commits.
    @discardableResult
    func commit(_ message: String, _ files: [String: String] = [:]) async throws -> String {
        for (path, contents) in files { try write(path, contents) }
        try await git("add", "-A")
        try await git("commit", "--quiet", "-m", message)
        return try await output("rev-parse", "HEAD")
    }

    /// `git status --porcelain` plus the index tree and HEAD: everything a checkpoint must not change.
    func userState() async throws -> String {
        let status = try await output("status", "--porcelain=v1", "--untracked-files=all")
        let index = try await output("ls-files", "--stage")
        let head = try await runner.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root, acceptedExitCodes: [0, 1]).trimmed
        return "\(status)\n--\n\(index)\n--\n\(head)"
    }
}

/// A `SourceControlWriter` with canned answers that records what it was asked.
final class FakeSourceControlWriter: SourceControlWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _stagedSummaries: [String] = []
    private var _stagedPatches: [String] = []
    let subject: String
    let body: String
    let branch: String?

    init(subject: String, body: String = "", branch: String? = nil) {
        self.subject = subject
        self.body = body
        self.branch = branch
    }

    var stagedSummaries: [String] { lock.withLock { _stagedSummaries } }
    var stagedPatches: [String] { lock.withLock { _stagedPatches } }

    func commitMessage(branch: String?, stagedSummary: String, stagedPatch: String, includeBranch: Bool) async throws -> (subject: String, body: String, branch: String?) {
        lock.withLock {
            _stagedSummaries.append(stagedSummary)
            _stagedPatches.append(stagedPatch)
        }
        return (subject, body, includeBranch ? self.branch : nil)
    }

    func pullRequest(baseBranch: String, headBranch: String, commits: String, diffStat: String, diffPatch: String) async throws -> (title: String, body: String) {
        ("Unused", "")
    }
}

/// Collects progress labels reported by a git action.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _labels: [String] = []

    var labels: [String] { lock.withLock { _labels } }

    func record(_ progress: GitActionProgress) {
        lock.withLock {
            if _labels.last != progress.label { _labels.append(progress.label) }
        }
    }
}
