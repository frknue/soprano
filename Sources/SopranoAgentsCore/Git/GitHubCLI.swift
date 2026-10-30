import Foundation

/// The GitHub CLI (`gh`) for pull request lookup and creation. Every call has a
/// deadline so a hung network or auth prompt never blocks git status.
struct GitHubCLI: Sendable {
    var executable: URL
    var environmentOverrides: [String: String] = [:]

    /// `gh` from the tool directories GUI apps miss, then the inherited PATH.
    static func locate(
        inheritedPath: String? = ProcessInfo.processInfo.environment["PATH"],
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> GitHubCLI? {
        let fileManager = FileManager.default
        for directory in GitRunner.searchPath(inheritedPath: inheritedPath, home: home) {
            let path = (directory as NSString).appendingPathComponent("gh")
            if fileManager.isExecutableFile(atPath: path) {
                return GitHubCLI(executable: URL(fileURLWithPath: path))
            }
        }
        return nil
    }

    /// Runs gh in `directory`; throws `GitSetupError.timedOut` after `timeout`
    /// (terminating gh) and `GitError` on a non-zero exit.
    func run(_ arguments: [String], in directory: URL, timeout: Duration) async throws -> GitResult {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(environmentOverrides) { _, override in override }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["NO_COLOR"] = "1"
        environment["PATH"] = GitRunner.searchPath(
            inheritedPath: environment["PATH"],
            home: FileManager.default.homeDirectoryForCurrentUser.path
        ).joined(separator: ":")
        let process = GitProcess(
            executable: executable, arguments: arguments, environment: environment,
            directory: directory, input: nil, onStderrLine: nil
        )
        let output = try await withThrowingTaskGroup(of: GitProcessOutput?.self) { group in
            group.addTask { try await process.run() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let output = first else {
                throw GitSetupError.timedOut("gh \(arguments.first ?? "")")
            }
            return output
        }
        let result = GitResult(
            stdout: output.stdout,
            stderr: String(decoding: output.stderr, as: UTF8.self),
            exitCode: output.exitCode
        )
        guard result.exitCode == 0 else {
            throw GitError(arguments: arguments, exitCode: result.exitCode, stdout: result.stdoutString, stderr: result.stderr)
        }
        return result
    }

    /// The pull request gh associates with the current branch of `directory`, nil when none.
    func pullRequestForCurrentBranch(in directory: URL, timeout: Duration) async -> PullRequestInfo? {
        guard let result = try? await run(
            ["pr", "view", "--json", "number,title,url,state,isDraft"], in: directory, timeout: timeout
        ) else { return nil }
        return Self.parsePullRequest(result.stdout)
    }

    static func parsePullRequest(_ data: Data) -> PullRequestInfo? {
        struct View: Decodable {
            var number: Int
            var title: String
            var url: String
            var state: String
            var isDraft: Bool?
        }
        guard let view = try? JSONDecoder().decode(View.self, from: data) else { return nil }
        let state: PullRequestInfo.State
        switch view.state.uppercased() {
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default: state = view.isDraft == true ? .draft : .open
        }
        return PullRequestInfo(number: view.number, title: view.title, url: view.url, state: state)
    }
}
