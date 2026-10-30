import Foundation

/// The stacked git action: [feature branch] → commit → push → pull request.
extension LiveGitService {
    static let noRemoteMessage = "Cannot push because no git remote is configured for this repository."
    static let detachedMessage = "Detached HEAD: create and check out a branch to enable push and pull request actions."
    static let notPushedMessage = "Current branch has not been pushed. Push before creating a PR."
    static let missingGitHubCLIMessage = "Creating a pull request needs the GitHub CLI (gh). Install it with Homebrew and run gh auth login."
    static let upToDateMessage = "Branch is up to date. No action needed."
    static let noChangesMessage = "No changes to commit."
    static let defaultCommitSubject = "Update project files"
    static let defaultPullRequestTitle = "Update project changes"

    /// What the commit step stages: a name-status summary and the patch.
    struct CommitContext: Sendable {
        var summary: String
        var patch: String
    }

    struct CommitMessage: Sendable {
        var subject: String
        var body: String
    }

    public func runAction(
        _ request: GitActionRequest,
        writer: any SourceControlWriter,
        progress: @escaping @Sendable (GitActionProgress) -> Void
    ) async throws -> GitActionResult {
        let directory = URL(fileURLWithPath: request.cwd)
        guard await isRepository(request.cwd) else { throw GitSetupError.notARepository(request.cwd) }
        let action = request.action
        let wantsCommit = [.commit, .commitAndPush, .commitPushAndPullRequest].contains(action)
        let wantsPullRequest = [.createPullRequest, .commitPushAndPullRequest].contains(action)
        var branch = try await currentBranch(in: directory)

        var commitSHA: String?
        var commitSubject: String?
        var noChanges = false
        if wantsCommit {
            let context = try await commitContext(in: directory, filePaths: request.filePaths)
            if let context {
                var message: CommitMessage?
                if request.featureBranch {
                    progress(GitActionProgress(label: "Preparing feature branch..."))
                    let (suggested, branchHint) = try await suggestMessage(
                        request: request, context: context, branch: branch, includeBranch: true, writer: writer, progress: progress
                    )
                    message = suggested
                    let name = try await availableBranchName(Self.sanitizeFeatureBranchName(branchHint ?? suggested.subject), in: directory)
                    try await git(["switch", "-c", name], in: directory)
                    branch = name
                }
                let resolved: CommitMessage
                if let message {
                    resolved = message
                } else {
                    resolved = try await suggestMessage(
                        request: request, context: context, branch: branch, includeBranch: false, writer: writer, progress: progress
                    ).0
                }
                commitSHA = try await commit(resolved, filePaths: request.filePaths, in: directory, progress: progress)
                commitSubject = resolved.subject
            } else {
                noChanges = true
            }
        }

        var upstream: Upstream?
        if let branch { upstream = try await self.upstream(of: branch, in: directory) }
        var wantsPush = [.push, .commitAndPush, .commitPushAndPullRequest].contains(action)
        if action == .createPullRequest {
            let ahead = upstream == nil ? 0 : try await count("@{upstream}..HEAD", in: directory)
            wantsPush = upstream == nil || ahead > 0
        }

        var pushedBranch: String?
        var upToDate = false
        if wantsPush {
            guard let branch else { throw GitActionError(Self.detachedMessage) }
            if try await push(branch: branch, upstream: upstream, in: directory, progress: progress) {
                pushedBranch = branch
            } else {
                upToDate = true
            }
        }

        var pullRequest: (info: PullRequestInfo, created: Bool)?
        if wantsPullRequest {
            guard let branch else { throw GitActionError(Self.detachedMessage) }
            pullRequest = try await createPullRequest(branch: branch, in: directory, writer: writer, progress: progress)
        }

        if let pullRequest {
            let verb = pullRequest.created ? "Created" : "Opened"
            return GitActionResult(
                title: "\(verb) PR #\(pullRequest.info.number)",
                detail: Self.truncated(pullRequest.info.title),
                pullRequestURL: pullRequest.info.url
            )
        }
        if let pushedBranch {
            let head = try await git(["log", "-1", "--format=%h%x00%s", "--abbrev=7", "HEAD"], in: directory, isRead: true).trimmed
            let parts = head.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            let sha = String(parts.first ?? "")
            let subject = commitSubject ?? parts.dropFirst().first.map(String.init)
            return GitActionResult(title: "Pushed \(sha) to \(pushedBranch)", detail: subject.map(Self.truncated))
        }
        if let commitSHA {
            return GitActionResult(title: "Committed \(commitSHA.prefix(7))", detail: commitSubject.map(Self.truncated))
        }
        return GitActionResult(title: "Done", detail: noChanges ? Self.noChangesMessage : upToDate ? Self.upToDateMessage : nil)
    }

    // MARK: Commit

    /// The staged summary and patch the commit would contain, built in a scratch copy of
    /// the index; nil when there is nothing to commit.
    func commitContext(in directory: URL, filePaths: [String]?) async throws -> CommitContext? {
        try await withScratchIndex(in: directory, seed: filePaths == nil ? .realIndex : .head) { environment, _ in
            let pathspec = filePaths.map { $0.map(GitOutput.topLiteral) }
            if pathspec?.isEmpty != true {
                try await stageAll(in: directory, pathspec: pathspec, environment: environment)
            }
            let summary = try await git(
                ["diff", "--cached", "--name-status", "--no-color"], in: directory, environment: environment, isRead: true
            ).trimmed
            guard !summary.isEmpty else { return nil }
            let patch = try await git(
                ["diff", "--no-ext-diff", "--no-color", "--cached", "--patch", "--minimal"],
                in: directory, environment: environment, isRead: true
            ).stdoutString
            return CommitContext(summary: summary, patch: patch)
        }
    }

    /// The request's own message, else one from `writer` (with a branch fragment when asked).
    func suggestMessage(
        request: GitActionRequest,
        context: CommitContext,
        branch: String?,
        includeBranch: Bool,
        writer: any SourceControlWriter,
        progress: @Sendable (GitActionProgress) -> Void
    ) async throws -> (CommitMessage, String?) {
        if let custom = request.commitMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return (Self.splitMessage(custom), nil)
        }
        progress(GitActionProgress(label: "Generating commit message..."))
        let generated = try await writer.commitMessage(
            branch: branch,
            stagedSummary: Self.limitSection(context.summary, 8_000),
            stagedPatch: Self.limitSection(context.patch, 50_000),
            includeBranch: includeBranch
        )
        let message = CommitMessage(
            subject: Self.normalizedSubject(generated.subject),
            body: generated.body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return (message, includeBranch ? generated.branch : nil)
    }

    /// Stages (only `filePaths` when given) and commits; returns the new HEAD.
    func commit(
        _ message: CommitMessage,
        filePaths: [String]?,
        in directory: URL,
        progress: @escaping @Sendable (GitActionProgress) -> Void
    ) async throws -> String {
        progress(GitActionProgress(label: "Committing..."))
        if let filePaths {
            if await headExists(in: directory) {
                try await git(["reset", "--quiet"], in: directory, accepting: [0, 1])
            } else {
                try await git(["read-tree", "--empty"], in: directory)
            }
            if !filePaths.isEmpty {
                try await git(["add", "-A", "--"] + filePaths.map(GitOutput.topLiteral), in: directory)
            }
        } else {
            try await git(["add", "-A"], in: directory)
        }
        var arguments = ["commit", "-m", message.subject]
        if !message.body.isEmpty { arguments += ["-m", message.body] }
        try await git().stream(arguments, in: directory) { line in
            progress(GitActionProgress(label: "Committing...", outputLine: String(line.prefix(500))))
        }
        return try await git(["rev-parse", "HEAD"], in: directory, isRead: true).trimmed
    }

    func availableBranchName(_ base: String, in directory: URL) async throws -> String {
        var candidate = base
        var suffix = 2
        while await succeeds(["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], in: directory) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: Push

    /// Pushes HEAD to `<remote>/<branch>` and records the upstream; false when already up to date.
    func push(
        branch: String,
        upstream: Upstream?,
        in directory: URL,
        progress: @escaping @Sendable (GitActionProgress) -> Void
    ) async throws -> Bool {
        let remotes = try await remotes(in: directory)
        guard let remote = upstream.map(\.remote).flatMap({ remotes.contains($0) ? $0 : nil }) ?? Self.primaryRemote(remotes) else {
            throw GitActionError(Self.noRemoteMessage)
        }
        let tracksSameName = upstream?.remote == remote && upstream?.branch == branch
        if tracksSameName, try await count("@{upstream}..HEAD", in: directory) == 0 {
            return false
        }
        progress(GitActionProgress(label: "Pushing..."))
        let result = try await git().stream(
            ["push", "--progress", "--", remote, "HEAD:refs/heads/\(branch)"], in: directory
        ) { line in
            progress(GitActionProgress(label: "Pushing...", outputLine: String(line.prefix(500))))
        }
        if !tracksSameName {
            try await git(["config", "branch.\(branch).remote", remote], in: directory)
            try await git(["config", "branch.\(branch).merge", "refs/heads/\(branch)"], in: directory)
        }
        return !result.stderr.contains("Everything up-to-date")
    }

    func count(_ range: String, in directory: URL) async throws -> Int {
        Int(try await git(["rev-list", "--count", range], in: directory, isRead: true).trimmed) ?? 0
    }

    // MARK: Pull request

    func createPullRequest(
        branch: String,
        in directory: URL,
        writer: any SourceControlWriter,
        progress: @escaping @Sendable (GitActionProgress) -> Void
    ) async throws -> (info: PullRequestInfo, created: Bool) {
        guard let upstream = try await upstream(of: branch, in: directory) else {
            throw GitActionError(Self.notPushedMessage)
        }
        guard let gh else { throw GitActionError(Self.missingGitHubCLIMessage) }
        if let existing = await gh.pullRequestForCurrentBranch(in: directory, timeout: .seconds(15)),
           existing.state == .open || existing.state == .draft {
            return (existing, false)
        }

        let base = try await pullRequestBase(branch: branch, upstream: upstream, in: directory)
        let baseRef = await succeeds(["show-ref", "--verify", "--quiet", "refs/remotes/\(upstream.remote)/\(base)"], in: directory)
            ? "\(upstream.remote)/\(base)" : base
        let commits = try await git(["log", "--oneline", "\(baseRef)..HEAD"], in: directory, isRead: true).stdoutString
        let stat = try await git(["diff", "--no-color", "--stat", "\(baseRef)...HEAD"], in: directory, isRead: true).stdoutString
        let patch = try await git(
            ["diff", "--no-color", "--no-ext-diff", "--patch", "--minimal", "\(baseRef)...HEAD"], in: directory, isRead: true
        ).stdoutString

        progress(GitActionProgress(label: "Generating PR content..."))
        let generated = try await writer.pullRequest(
            baseBranch: base,
            headBranch: upstream.branch,
            commits: Self.limitSection(commits, 20_000),
            diffStat: Self.limitSection(stat, 20_000),
            diffPatch: Self.limitSection(patch, 60_000)
        )
        let title = Self.firstLine(generated.title) ?? Self.defaultPullRequestTitle

        progress(GitActionProgress(label: "Creating pull request..."))
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-agents-pr-body-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).md")
        try Data(generated.body.utf8).write(to: bodyFile)
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        let result = try await gh.run(
            ["pr", "create", "--base", base, "--head", upstream.branch, "--title", title, "--body-file", bodyFile.path],
            in: directory, timeout: .seconds(120)
        )
        let url = GitOutput.trimmedLines(result.stdout).last { $0.hasPrefix("http") } ?? result.trimmed
        let number = url.split(separator: "/").last.flatMap { Int($0) } ?? 0
        return (PullRequestInfo(number: number, title: title, url: url, state: .open), true)
    }

    /// `branch.<b>.soprano-agents-merge-base` (set for new worktrees) → the upstream branch when
    /// it differs → the default branch → `main`.
    func pullRequestBase(branch: String, upstream: Upstream, in directory: URL) async throws -> String {
        if let recorded = try await config("branch.\(branch).soprano-agents-merge-base", in: directory) {
            let remotePrefix = "\(upstream.remote)/"
            return recorded.hasPrefix(remotePrefix) ? String(recorded.dropFirst(remotePrefix.count)) : recorded
        }
        if upstream.branch != branch { return upstream.branch }
        return try await defaultBranch(in: directory, remote: upstream.remote) ?? "main"
    }

    // MARK: Text

    /// First line = subject, the rest (trimmed) = body.
    static func splitMessage(_ message: String) -> CommitMessage {
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let subject = String(lines.first ?? "").trimmingCharacters(in: .whitespaces)
        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return CommitMessage(subject: subject, body: body)
    }

    /// First line, no trailing period, at most 72 characters; empty → "Update project files".
    static func normalizedSubject(_ subject: String) -> String {
        guard var line = firstLine(subject) else { return defaultCommitSubject }
        while line.hasSuffix(".") { line.removeLast() }
        line = String(line.prefix(72)).trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? defaultCommitSubject : line
    }

    static func firstLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map {
            String($0).trimmingCharacters(in: .whitespaces)
        } ?? ""
        return line.isEmpty ? nil : line
    }

    /// Lowercase, runs of characters outside `[a-z0-9/_-]` → "-", at most 64 characters,
    /// "update" when empty, `feature/` prefixed when it has no namespace.
    static func sanitizeFeatureBranchName(_ raw: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in raw.lowercased().unicodeScalars {
            let allowed = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "/" || scalar == "_" || scalar == "-"
            if allowed {
                result.unicodeScalars.append(scalar)
                lastWasDash = scalar == "-"
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        result = String(result.trimmingCharacters(in: CharacterSet(charactersIn: "-/")).prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
        if result.isEmpty { result = "update" }
        return result.contains("/") ? result : "feature/\(result)"
    }

    static func limitSection(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + truncatedMarker : text
    }

    static func truncated(_ text: String) -> String {
        text.count > 72 ? String(text.prefix(69)) + "..." : text
    }
}
