import CryptoKit
import Foundation

/// Status, branches and worktrees.
extension LiveGitService {
    /// The branch's upstream, from `branch.<name>.remote` / `.merge` with an existing tracking ref.
    struct Upstream: Sendable, Hashable {
        var remote: String
        /// Branch name on the remote (`merge` without `refs/heads/`).
        var branch: String
    }

    // MARK: Status

    public func status(cwd: String) async throws -> GitStatusSummary {
        guard await isRepository(cwd) else { return .notARepository }
        let directory = URL(fileURLWithPath: cwd)
        async let filesTask = workingTreeFiles(in: directory)
        let branch = try await currentBranch(in: directory)
        let remotes = try await remotes(in: directory)
        let primaryRemote = Self.primaryRemote(remotes)
        async let pullRequestTask = pullRequest(in: directory, branch: branch, hasRemote: primaryRemote != nil)
        let defaultBranch = try await defaultBranch(in: directory, remote: primaryRemote)
        var upstream: Upstream?
        if let branch { upstream = try await self.upstream(of: branch, in: directory) }
        var ahead = 0
        var behind = 0
        if upstream != nil {
            let counts = try await git(
                ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: directory, isRead: true
            ).trimmed.split(whereSeparator: \.isWhitespace)
            ahead = counts.first.flatMap { Int($0) } ?? 0
            behind = counts.dropFirst().first.flatMap { Int($0) } ?? 0
        } else if primaryRemote != nil, await headExists(in: directory) {
            // No upstream: commits not on any remote yet.
            ahead = Int(try await git(
                ["rev-list", "--count", "HEAD", "--not", "--remotes"], in: directory, isRead: true
            ).trimmed) ?? 0
        }
        return GitStatusSummary(
            isRepository: true,
            branch: branch,
            isDefaultBranch: branch != nil && branch == defaultBranch,
            hasRemote: primaryRemote != nil,
            hasUpstream: upstream != nil,
            ahead: ahead,
            behind: behind,
            files: try await filesTask,
            pullRequest: await pullRequestTask
        )
    }

    /// Uncommitted changes against HEAD, untracked files included (respecting .gitignore).
    func workingTreeFiles(in directory: URL) async throws -> [ChangedFileStat] {
        try await withScratchIndex(in: directory, seed: .head) { environment, headExists in
            try await stageAll(in: directory, pathspec: nil, environment: environment)
            let base = headExists ? "HEAD" : try await emptyTree(in: directory)
            let result = try await git(
                ["diff", "--cached", "--numstat", "-z"] + Self.diffOptions + [base, "--"],
                in: directory, environment: environment, isRead: true
            )
            return Self.parseNumstat(result.stdout)
        }
    }

    func pullRequest(in directory: URL, branch: String?, hasRemote: Bool) async -> PullRequestInfo? {
        guard let gh, branch != nil, hasRemote else { return nil }
        return await gh.pullRequestForCurrentBranch(in: directory, timeout: pullRequestLookupTimeout)
    }

    /// Current branch name, nil when detached. Unborn branches count.
    func currentBranch(in directory: URL) async throws -> String? {
        let result = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory, isRead: true, accepting: [0, 1])
        let name = result.trimmed
        return result.exitCode == 0 && !name.isEmpty ? name : nil
    }

    func remotes(in directory: URL) async throws -> [String] {
        GitOutput.trimmedLines(try await git(["remote"], in: directory, isRead: true).stdout)
    }

    /// `origin` when configured, else the first remote.
    static func primaryRemote(_ remotes: [String]) -> String? {
        remotes.contains("origin") ? "origin" : remotes.first
    }

    func config(_ key: String, in directory: URL) async throws -> String? {
        let result = try await git(["config", "--get", key], in: directory, isRead: true, accepting: [0, 1])
        let value = result.trimmed
        return result.exitCode == 0 && !value.isEmpty ? value : nil
    }

    func upstream(of branch: String, in directory: URL) async throws -> Upstream? {
        guard let remote = try await config("branch.\(branch).remote", in: directory),
              let merge = try await config("branch.\(branch).merge", in: directory),
              await succeeds(["rev-parse", "--verify", "--quiet", "\(branch)@{upstream}"], in: directory)
        else { return nil }
        let name = merge.hasPrefix("refs/heads/") ? String(merge.dropFirst("refs/heads/".count)) : merge
        return Upstream(remote: remote, branch: name)
    }

    /// The remote's HEAD branch (`refs/remotes/<remote>/HEAD`), else `main`, else `master`
    /// (local or on the remote).
    func defaultBranch(in directory: URL, remote: String?) async throws -> String? {
        if let remote {
            let result = try await git(
                ["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"], in: directory, isRead: true, accepting: [0, 1, 128]
            )
            let name = result.trimmed
            if result.exitCode == 0, name.hasPrefix("\(remote)/") {
                return String(name.dropFirst(remote.count + 1))
            }
        }
        var patterns = ["refs/heads/main", "refs/heads/master"]
        if let remote { patterns += ["refs/remotes/\(remote)/main", "refs/remotes/\(remote)/master"] }
        let refs = Set(GitOutput.trimmedLines(
            try await git(["for-each-ref", "--format=%(refname)"] + patterns, in: directory, isRead: true).stdout
        ))
        for name in ["main", "master"] where refs.contains("refs/heads/\(name)") || refs.contains("refs/remotes/\(remote ?? "")/\(name)") {
            return name
        }
        return nil
    }

    // MARK: Branches

    public func branches(cwd: String) async throws -> [GitBranchRef] {
        let directory = URL(fileURLWithPath: cwd)
        let current = try await currentBranch(in: directory)
        let remotes = try await remotes(in: directory)
        let primaryRemote = Self.primaryRemote(remotes)
        let defaultBranch = try await defaultBranch(in: directory, remote: primaryRemote)
        let worktrees = try await worktreeBranches(in: directory)
        let toplevel = try await git(["rev-parse", "--show-toplevel"], in: directory, isRead: true).trimmed
        let here = Self.canonicalPath(toplevel)

        let listing = try await git(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname)%00%(symref)", "refs/heads", "refs/remotes"],
            in: directory, isRead: true
        )
        var locals: [GitBranchRef] = []
        var remoteRefs: [GitBranchRef] = []
        for line in GitOutput.trimmedLines(listing.stdout) {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard let refname = fields.first, fields.count < 2 || fields[1].isEmpty else { continue }
            if refname.hasPrefix("refs/heads/") {
                let name = String(refname.dropFirst("refs/heads/".count))
                let worktree = worktrees[name].flatMap { Self.canonicalPath($0) == here ? nil : $0 }
                locals.append(GitBranchRef(
                    name: name, isCurrent: name == current, isDefault: name == defaultBranch,
                    worktreePath: name == current ? nil : worktree
                ))
            } else if refname.hasPrefix("refs/remotes/") {
                let name = String(refname.dropFirst("refs/remotes/".count))
                remoteRefs.append(GitBranchRef(
                    name: name, isRemote: true,
                    isDefault: primaryRemote.map { name == "\($0)/\(defaultBranch ?? "")" } ?? false
                ))
            }
        }
        // An unborn branch has no ref yet but is still the current one.
        if let current, !locals.contains(where: { $0.name == current }) {
            locals.append(GitBranchRef(name: current, isCurrent: true, isDefault: current == defaultBranch))
        }
        let rank: (GitBranchRef) -> Int = { $0.isCurrent ? 0 : $0.isDefault ? 1 : 2 }
        let sortedLocals = locals.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        let sortedRemotes = remoteRefs.enumerated().sorted {
            ($0.element.isDefault ? 0 : 1, $0.offset) < ($1.element.isDefault ? 0 : 1, $1.offset)
        }.map(\.element)
        return sortedLocals + sortedRemotes
    }

    /// Branch name → worktree path, from `git worktree list --porcelain`.
    func worktreeBranches(in directory: URL) async throws -> [String: String] {
        let output = try await git(["worktree", "list", "--porcelain"], in: directory, isRead: true).stdoutString
        var result: [String: String] = [:]
        var path: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let path {
                result[String(line.dropFirst("branch refs/heads/".count))] = path
            } else if line.isEmpty {
                path = nil
            }
        }
        return result
    }

    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func createBranch(cwd: String, name: String, checkout: Bool) async throws {
        let directory = URL(fileURLWithPath: cwd)
        if checkout {
            try await git(["switch", "-c", name], in: directory)
        } else {
            try await git(["branch", "--", name], in: directory)
        }
    }

    /// Switches to a local branch; a remote branch (`origin/feature`) switches to its
    /// local counterpart, creating it to track the remote one when missing.
    public func switchBranch(cwd: String, name: String) async throws {
        let directory = URL(fileURLWithPath: cwd)
        if await succeeds(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: directory) {
            try await git(["switch", name], in: directory)
            return
        }
        let remotes = try await remotes(in: directory)
        if await succeeds(["show-ref", "--verify", "--quiet", "refs/remotes/\(name)"], in: directory),
           let remote = remotes.filter({ name.hasPrefix("\($0)/") }).max(by: { $0.count < $1.count }) {
            let local = String(name.dropFirst(remote.count + 1))
            if await succeeds(["show-ref", "--verify", "--quiet", "refs/heads/\(local)"], in: directory) {
                try await git(["switch", local], in: directory)
            } else {
                try await git(["switch", "-c", local, "--track", name], in: directory)
            }
            return
        }
        try await git(["switch", name], in: directory)
    }

    public func renameBranch(cwd: String, from: String, to: String) async throws {
        try await git(["branch", "-m", "--", from, to], in: URL(fileURLWithPath: cwd))
    }

    // MARK: Worktrees

    /// `<directory>/<basename(projectRoot)>/<branch with "/" → "-">`; a folder name over 40
    /// characters becomes its first 23 characters, "-", and 16 hex digits of SHA-256(branch).
    public static func worktreePath(directory: String, projectRoot: String, branch: String) -> String {
        var folder = branch.replacingOccurrences(of: "/", with: "-")
        if folder.count > 40 {
            let digest = SHA256.hash(data: Data(branch.utf8)).map { String(format: "%02x", $0) }.joined()
            folder = String(folder.prefix(23)) + "-" + String(digest.prefix(16))
        }
        let project = URL(fileURLWithPath: projectRoot).lastPathComponent
        return ((directory as NSString).appendingPathComponent(project) as NSString).appendingPathComponent(folder)
    }

    public func createWorktree(projectRoot: String, baseBranch: String, newBranch: String, directory: String) async throws -> String {
        let expanded = (directory as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), (expanded as NSString).standardizingPath != "/" else {
            throw GitActionError(
                "The worktree location \"\(directory)\" must be an absolute folder on this machine, not a drive root. Change it in Settings → Worktrees."
            )
        }
        let root = URL(fileURLWithPath: projectRoot)
        let path = Self.worktreePath(directory: expanded, projectRoot: projectRoot, branch: newBranch)
        try await git(["branch", "--no-track", "--", newBranch, baseBranch], in: root)
        do {
            try await git(["worktree", "add", "--", path, newBranch], in: root)
        } catch {
            await rollBackWorktree(path: path, branch: newBranch, in: root)
            throw error
        }
        _ = try? await git(["config", "branch.\(newBranch).soprano-agents-merge-base", baseBranch], in: root)
        let worktree = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".gitmodules").path) {
            do {
                try await git(["submodule", "init"], in: worktree)
                try await git(["submodule", "update", "--init", "--recursive"], in: worktree)
            } catch {
                // A half-set-up worktree must not exist: a later turn would run the agent in it.
                await rollBackWorktree(path: path, branch: newBranch, in: root)
                throw error
            }
        }
        return path
    }

    /// Removes a worktree `createWorktree` left half set up, and its branch. Runs in a task of its
    /// own: Stop or quit cancels the setup task, and git refuses to start in a cancelled one.
    private func rollBackWorktree(path: String, branch: String, in root: URL) async {
        await Task.detached { [self] in
            if FileManager.default.fileExists(atPath: path) {
                _ = try? await git(["worktree", "remove", "--force", "--", path], in: root)
            }
            _ = try? await git(["worktree", "prune"], in: root)
            _ = try? await git(["branch", "-D", "--", branch], in: root)
        }.value
    }

    public func removeWorktree(projectRoot: String, path: String, force: Bool) async throws {
        let root = URL(fileURLWithPath: projectRoot)
        if FileManager.default.fileExists(atPath: path) {
            try await git(["worktree", "remove"] + (force ? ["--force"] : []) + ["--", path], in: root)
        } else {
            try await git(["worktree", "prune"], in: root)
        }
    }
}
