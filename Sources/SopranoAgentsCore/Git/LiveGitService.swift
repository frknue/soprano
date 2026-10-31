import Foundation

/// `GitService` backed by the git CLI (through `GitRunner`) and, for pull
/// requests, the GitHub CLI. Checkpoints, status and the working-tree diff
/// stage into a scratch index, so the user's index and HEAD are never touched.
public struct LiveGitService: GitService {
    /// nil when no git executable exists; every call then fails with `GitSetupError.gitNotFound`.
    let runner: GitRunner?
    /// nil when gh is not installed; pull request lookup is skipped and creation fails.
    let gh: GitHubCLI?
    /// Deadline for `gh pr view` during status refreshes.
    let pullRequestLookupTimeout: Duration

    public init() {
        self.init(
            runner: GitRunner.resolveExecutable().map { GitRunner(executable: $0) },
            gh: GitHubCLI.locate()
        )
    }

    init(runner: GitRunner?, gh: GitHubCLI?, pullRequestLookupTimeout: Duration = .seconds(4)) {
        self.runner = runner
        self.gh = gh
        self.pullRequestLookupTimeout = pullRequestLookupTimeout
    }

    // MARK: Constants

    /// Unified diffs larger than this are cut and end with `truncatedMarker`.
    static let maximumDiffBytes = 10_000_000
    static let truncatedMarker = "\n\n[truncated]"

    /// Identity of checkpoint commits.
    static let checkpointIdentity = [
        "GIT_AUTHOR_NAME": "Soprano Agents",
        "GIT_AUTHOR_EMAIL": "soprano-agents@users.noreply.github.com",
        "GIT_COMMITTER_NAME": "Soprano Agents",
        "GIT_COMMITTER_EMAIL": "soprano-agents@users.noreply.github.com",
    ]

    /// Options for commands that read or write the scratch index.
    static let scratchIndexOptions = [
        "-c", "core.fsmonitor=false",
        "-c", "core.splitIndex=false",
        "-c", "splitIndex.sharedIndexExpire=never",
    ]

    static let diffOptions = ["--no-color", "--no-ext-diff", "--no-textconv", "-M"]

    // MARK: Plumbing

    func git() throws -> GitRunner {
        guard let runner else { throw GitSetupError.gitNotFound }
        return runner
    }

    @discardableResult
    func git(
        _ arguments: [String],
        in directory: URL,
        stdin: Data? = nil,
        environment: [String: String] = [:],
        isRead: Bool = false,
        accepting codes: Set<Int32> = [0]
    ) async throws -> GitResult {
        try await git().run(
            arguments, in: directory, stdin: stdin, environment: environment,
            isRead: isRead, acceptedExitCodes: codes
        )
    }

    /// Whether `git <arguments>` exits 0 (any failure, including a missing git, is false).
    func succeeds(_ arguments: [String], in directory: URL) async -> Bool {
        guard let result = try? await git(arguments, in: directory, isRead: true, accepting: [0, 1, 128]) else {
            return false
        }
        return result.exitCode == 0
    }

    func headExists(in directory: URL) async -> Bool {
        await succeeds(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: directory)
    }

    /// The id of the empty tree in this repository's hash algorithm.
    func emptyTree(in directory: URL) async throws -> String {
        try await git(["hash-object", "-t", "tree", "--stdin"], in: directory, stdin: Data(), isRead: true).trimmed
    }

    /// The commit `ref` points to, nil when missing.
    func resolveCommit(_ ref: String, in directory: URL) async -> String? {
        guard let result = try? await git(
            ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: directory, isRead: true, accepting: [0, 1, 128]
        ), result.exitCode == 0 else { return nil }
        let commit = result.trimmed
        return commit.isEmpty ? nil : commit
    }

    // MARK: Scratch index

    enum IndexSeed {
        /// The real index (keeps its stat cache), reset to HEAD; empty without HEAD.
        case head
        /// The real index as it is (what the user staged).
        case realIndex
    }

    /// Runs `body` with `GIT_INDEX_FILE` pointing at a scratch index under the
    /// common git directory, seeded per `seed`, and removes it afterwards.
    func withScratchIndex<T: Sendable>(
        in directory: URL,
        seed: IndexSeed,
        _ body: (_ environment: [String: String], _ headExists: Bool) async throws -> T
    ) async throws -> T {
        let commonDirectory = try await git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory, isRead: true
        ).trimmed
        let headExists = await headExists(in: directory)
        let scratch = (commonDirectory as NSString).appendingPathComponent("soprano-agents-index-\(UUID().uuidString)")
        let fileManager = FileManager.default
        defer {
            try? fileManager.removeItem(atPath: scratch)
            try? fileManager.removeItem(atPath: scratch + ".lock")
        }
        let environment = ["GIT_INDEX_FILE": scratch]
        let realIndex = try await git(
            ["rev-parse", "--path-format=absolute", "--git-path", "index"], in: directory, isRead: true
        ).trimmed
        if fileManager.fileExists(atPath: realIndex) {
            // A copy keeps git's stat cache, so `add -A` only rehashes changed files.
            try? fileManager.copyItem(atPath: realIndex, toPath: scratch)
        }
        if seed == .head {
            if headExists {
                try await git(Self.scratchIndexOptions + ["read-tree", "--reset", "HEAD"], in: directory, environment: environment)
            } else {
                try await git(Self.scratchIndexOptions + ["read-tree", "--empty"], in: directory, environment: environment)
            }
        }
        return try await body(environment, headExists)
    }

    /// `git add -A` into the scratch index (`pathspec` nil = the whole repository).
    /// Untracked nested repositories without a commit make `add` fail; they are excluded and the add retried.
    func stageAll(in directory: URL, pathspec: [String]?, environment: [String: String]) async throws {
        let arguments = Self.scratchIndexOptions + ["add", "-A", "--"] + (pathspec ?? [":/"])
        do {
            try await git(arguments, in: directory, environment: environment)
        } catch let error as GitError {
            let listing = try await git(
                ["ls-files", "--others", "--exclude-standard", "--directory", "--full-name", "-z", "--"] + (pathspec ?? [":/"]),
                in: directory, environment: environment, isRead: true
            )
            let root = try await git(["rev-parse", "--show-toplevel"], in: directory, isRead: true).trimmed
            let nested = GitOutput.nulFields(listing.stdout).filter { $0.hasSuffix("/") }.prefix(64).filter { entry in
                let path = (root as NSString).appendingPathComponent(entry)
                return FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
            }
            guard !nested.isEmpty else { throw error }
            let exclusions = nested.map { ":(top,exclude,literal)\($0)" }
            try await git(arguments + exclusions, in: directory, environment: environment)
        }
    }

    // MARK: Repository

    public func isRepository(_ cwd: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: cwd),
              let result = try? await git(
                  ["rev-parse", "--is-inside-work-tree"], in: URL(fileURLWithPath: cwd), isRead: true, accepting: [0, 128]
              )
        else { return false }
        return result.exitCode == 0 && result.trimmed == "true"
    }

    public func repositoryRoot(_ cwd: String) async -> String? {
        guard FileManager.default.fileExists(atPath: cwd),
              let result = try? await git(
                  ["rev-parse", "--show-toplevel"], in: URL(fileURLWithPath: cwd), isRead: true, accepting: [0, 128]
              ),
              result.exitCode == 0
        else { return nil }
        let root = result.trimmed
        return root.isEmpty ? nil : root
    }

    public func checkedOutBranch(_ cwd: String) async -> String? {
        guard FileManager.default.fileExists(atPath: cwd),
              let result = try? await git(
                  ["symbolic-ref", "--quiet", "--short", "HEAD"], in: URL(fileURLWithPath: cwd), isRead: true, accepting: [0, 1, 128]
              ),
              result.exitCode == 0
        else { return nil }
        let branch = result.trimmed
        return branch.isEmpty ? nil : branch
    }

    // MARK: Checkpoints

    public func captureCheckpoint(cwd: String, ref: String) async throws {
        let directory = URL(fileURLWithPath: cwd)
        try await withScratchIndex(in: directory, seed: .head) { environment, headExists in
            try await stageAll(in: directory, pathspec: ["."], environment: environment)
            let tree = try await git(Self.scratchIndexOptions + ["write-tree"], in: directory, environment: environment).trimmed
            var arguments = ["commit-tree", tree]
            if headExists { arguments += ["-p", "HEAD"] }
            arguments += ["-m", "soprano-agents checkpoint \(ref)"]
            let commit = try await git(
                arguments, in: directory, environment: environment.merging(Self.checkpointIdentity) { $1 }
            ).trimmed
            try await git(["update-ref", ref, commit], in: directory)
        }
    }

    public func checkpointExists(cwd: String, ref: String) async -> Bool {
        await resolveCommit(ref, in: URL(fileURLWithPath: cwd)) != nil
    }

    public func changedFiles(cwd: String, fromRef: String, toRef: String) async throws -> [ChangedFileStat] {
        let result = try await git(
            ["diff", "--numstat", "-z"] + Self.diffOptions + ["\(fromRef)^{commit}", "\(toRef)^{commit}", "--"],
            in: URL(fileURLWithPath: cwd), isRead: true
        )
        return Self.parseNumstat(result.stdout)
    }

    public func diff(cwd: String, fromRef: String, toRef: String, ignoreWhitespace: Bool) async throws -> String {
        let result = try await git(
            ["diff", "--patch"] + Self.diffOptions + (ignoreWhitespace ? ["--ignore-all-space"] : [])
                + ["\(fromRef)^{commit}", "\(toRef)^{commit}", "--"],
            in: URL(fileURLWithPath: cwd), isRead: true
        )
        return Self.cappedPatch(result.stdout)
    }

    public func workingTreeDiff(cwd: String, ignoreWhitespace: Bool) async throws -> String {
        let directory = URL(fileURLWithPath: cwd)
        return try await withScratchIndex(in: directory, seed: .head) { environment, headExists in
            try await stageAll(in: directory, pathspec: nil, environment: environment)
            let base = headExists ? "HEAD" : try await emptyTree(in: directory)
            let result = try await git(
                ["diff", "--cached", "--patch"] + Self.diffOptions + (ignoreWhitespace ? ["--ignore-all-space"] : [])
                    + [base, "--"],
                in: directory, environment: environment, isRead: true
            )
            return Self.cappedPatch(result.stdout)
        }
    }

    public func restoreCheckpoint(cwd: String, ref: String) async throws {
        let directory = URL(fileURLWithPath: cwd)
        guard let commit = await resolveCommit(ref, in: directory) else {
            throw GitActionError("The checkpoint \(ref) no longer exists.")
        }
        let tracked = try await git(["ls-files", "--cached", "--with-tree=\(commit)", "-z", "--", "."], in: directory, isRead: true)
        if !tracked.stdout.isEmpty {
            try await git(["restore", "--source", commit, "--worktree", "--staged", "--", "."], in: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clean = try await git(["clean", "-fd", "--", "."], in: directory, accepting: [0, 1])
        if clean.exitCode != 0, !clean.stderr.contains("failed to remove ./") {
            throw GitError(arguments: ["clean"], exitCode: clean.exitCode, stdout: clean.stdoutString, stderr: clean.stderr)
        }
        if await headExists(in: directory) {
            try await git(["reset", "--quiet", "--", "."], in: directory, accepting: [0, 1])
        }
    }

    public func deleteRefs(cwd: String, refs: [String]) async throws {
        guard !refs.isEmpty else { return }
        let commands = refs.map { "delete \($0)\n" }.joined()
        try await git(["update-ref", "--stdin"], in: URL(fileURLWithPath: cwd), stdin: Data(commands.utf8))
    }

    // MARK: Parsing

    /// `git diff --numstat -z`: "add\tdel\tpath\0", renames "add\tdel\t\0old\0new\0",
    /// binary files "-\t-\t…" (counted as 0). Sorted by path.
    static func parseNumstat(_ data: Data) -> [ChangedFileStat] {
        let fields = GitOutput.nulFields(data)
        var stats: [ChangedFileStat] = []
        var index = 0
        while index < fields.count {
            let parts = fields[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            index += 1
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            if path.isEmpty {
                guard index + 1 < fields.count else { break }
                path = fields[index + 1]
                index += 2
            }
            stats.append(ChangedFileStat(path: path, additions: Int(parts[0]) ?? 0, deletions: Int(parts[1]) ?? 0))
        }
        return stats.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The patch as text, cut on a UTF-8 boundary after `maximumDiffBytes`.
    static func cappedPatch(_ data: Data, limit: Int = maximumDiffBytes) -> String {
        guard data.count > limit else { return String(decoding: data, as: UTF8.self) }
        var end = data.startIndex + limit
        // Never split a multi-byte character: back up over continuation bytes.
        while end > data.startIndex, data[end] & 0xC0 == 0x80 { end -= 1 }
        return String(decoding: data[data.startIndex..<end], as: UTF8.self) + truncatedMarker
    }
}
