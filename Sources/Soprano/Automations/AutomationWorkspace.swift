import Darwin
import Foundation

/// The git worktree an automation run works in: a new branch from the base,
/// checked out under Soprano's Application Support folder. A run that leaves
/// it untouched gets it removed; one with changes or commits keeps it.
enum AutomationWorktree {
    struct Checkout: Equatable, Sendable {
        var worktree: AutomationRun.Worktree
        /// The run's folder inside the worktree: the same place in the
        /// repository the automation's folder names.
        var workingDirectory: String
    }

    enum Failure: LocalizedError, Equatable {
        case gitUnavailable
        case notARepository(String)
        case unknownBase(String)
        case gitFailed(String)

        var errorDescription: String? {
            switch self {
            case .gitUnavailable:
                "Git isn't installed, so the run can't get a worktree."
            case .notARepository(let folder):
                "\(ConfigFile.abbreviatingHome(folder)) is not inside a Git repository, so the run can't get a worktree."
            case .unknownBase(let base):
                "The base branch \"\(base)\" doesn't exist in the repository."
            case .gitFailed(let message):
                "Git couldn't create the worktree: \(message)"
            }
        }
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        AutomationStore.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("worktrees", isDirectory: true)
    }

    /// `automation/<id>-<yyyyMMdd-HHmm>`, unique among the repository's
    /// branches.
    static func branchName(automationId: String, date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "automation/\(automationId)-\(formatter.string(from: date))"
    }

    /// Creates the worktree. Without a `baseBranch`, the run starts from the
    /// remote's default branch as last fetched (`origin/HEAD`), and from the
    /// checkout's `HEAD` in a repository without a remote.
    static func create(
        from folder: String,
        automationId: String,
        baseBranch: String?,
        date: Date,
        under directory: URL
    ) throws -> Checkout {
        guard Git.executableURL != nil else { throw Failure.gitUnavailable }
        guard let root = GitBranchMonitor.repositoryRoot(startingAt: folder) else {
            throw Failure.notARepository(folder)
        }
        let base = baseBranch ?? defaultBase(in: root)
        guard let baseCommit = try? Git.output(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: root),
              !baseCommit.isEmpty
        else { throw Failure.unknownBase(base) }

        var branch = branchName(automationId: automationId, date: date)
        var suffix = 2
        while (try? Git.output(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root)) != nil {
            branch = branchName(automationId: automationId, date: date) + "-\(suffix)"
            suffix += 1
        }
        let repository = URL(fileURLWithPath: root).lastPathComponent
        let parent = directory.appendingPathComponent(repository, isDirectory: true)
        let leaf = branch.split(separator: "/").last.map(String.init) ?? branch
        var path = parent.appendingPathComponent(leaf, isDirectory: true).path
        suffix = 2
        while FileManager.default.fileExists(atPath: path) {
            path = parent.appendingPathComponent("\(leaf)-\(suffix)", isDirectory: true).path
            suffix += 1
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            _ = try Git.output(["worktree", "add", "--no-track", "-b", branch, path, baseCommit], in: root)
        } catch let error as Git.Failure {
            throw Failure.gitFailed(error.message)
        }

        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let resolvedFolder = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        let relative = resolvedFolder.hasPrefix(resolvedRoot + "/")
            ? String(resolvedFolder.dropFirst(resolvedRoot.count + 1))
            : ""
        return Checkout(
            worktree: AutomationRun.Worktree(path: path, branch: branch, repository: root, baseCommit: baseCommit),
            workingDirectory: relative.isEmpty ? path : URL(fileURLWithPath: path).appendingPathComponent(relative).path
        )
    }

    private static func defaultBase(in root: String) -> String {
        if let remoteHead = try? Git.output(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root),
           !remoteHead.isEmpty {
            return remoteHead
        }
        return "HEAD"
    }

    /// Whether the run left the worktree as it found it: no changes, no
    /// untracked files, no commits past its base.
    static func isUntouched(_ worktree: AutomationRun.Worktree) -> Bool {
        guard let status = try? Git.output(["status", "--porcelain", "--untracked-files=all"], in: worktree.path),
              status.isEmpty,
              let head = try? Git.output(["rev-parse", "HEAD"], in: worktree.path)
        else { return false }
        return head == worktree.baseCommit
    }

    /// Removes the worktree and its branch.
    static func remove(_ worktree: AutomationRun.Worktree) {
        _ = try? Git.output(["worktree", "remove", "--force", worktree.path], in: worktree.repository)
        _ = try? Git.output(["branch", "-D", worktree.branch], in: worktree.repository)
    }
}

/// Runs git for the automation helpers; output is trimmed stdout.
enum Git {
    struct Failure: Error, Equatable {
        let message: String
    }

    static var executableURL: URL? { GitStatusReader.executableURL }

    static func output(_ arguments: [String], in directory: String) throws -> String {
        guard let executableURL else { throw Failure(message: "git is not installed") }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: message.isEmpty ? "git exited with \(process.terminationStatus)" : message)
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A scheduled run's precheck: a shell command in the automation's folder
/// whose exit status decides whether the run starts.
enum AutomationPrecheck {
    struct Outcome: Equatable, Sendable {
        var exitCode: Int32
        var timedOut: Bool
        /// The end of what it printed, stdout and stderr together.
        var output: String

        var passed: Bool { exitCode == 0 && !timedOut }

        var summary: String {
            let reason = timedOut ? "The precheck timed out." : "The precheck exited with code \(exitCode)."
            return output.isEmpty ? reason : "\(reason)\n\n\(output)"
        }
    }

    /// Characters of output kept with a skipped run.
    static let outputLimit = 4_000

    /// Runs `command` through the user's login shell so it finds what their
    /// terminal finds (`gh`, `jq`). Blocks; call it off the main thread.
    static func run(
        _ command: String,
        in folder: String,
        timeout: TimeInterval,
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collected = OutputBuffer()
        let reachedEnd = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                reachedEnd.signal()
            } else {
                collected.append(chunk)
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return Outcome(exitCode: 127, timedOut: false, output: error.localizedDescription)
        }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        // The output ends with the command unless something it started in
        // the background still holds the pipe; that is not waited for, or
        // it would hold every automation's setup until it was done.
        _ = reachedEnd.wait(timeout: .now() + 0.5)
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        let text = collected.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            output: String(text.suffix(outputLimit))
        )
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Claude Code asks whether to trust a folder the first time it starts in
/// one, and waits for the answer even with `--dangerously-skip-permissions`.
/// A run nobody watches records its folder as trusted the way that dialog
/// does — the `projects.<path>.hasTrustDialogAccepted` key Claude Code's own
/// message points to — under the lock Claude Code takes for the file.
enum ClaudeWorkspaceTrust {
    /// `~/.claude.json`, or `.claude.json` in `CLAUDE_CONFIG_DIR`.
    static func configURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let directory = environment["CLAUDE_CONFIG_DIR"], !directory.isEmpty {
            return URL(fileURLWithPath: SopranoConfig.expandPath(directory), isDirectory: true)
                .appendingPathComponent(".claude.json", isDirectory: false)
        }
        return home.appendingPathComponent(".claude.json", isDirectory: false)
    }

    /// Marks `folder` trusted. False when there is no config to write (Claude
    /// Code never ran), it can't be read, or Claude Code holds its lock for
    /// longer than `lockTimeout`.
    @discardableResult
    static func trust(_ folder: String, configURL: URL, lockTimeout: TimeInterval = 2) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configURL.path) else { return false }
        // Claude Code's lock is a directory beside the file: creating it is
        // the atomic step that claims it.
        let lock = URL(fileURLWithPath: configURL.path + ".lock", isDirectory: true)
        let deadline = Date().addingTimeInterval(lockTimeout)
        while (try? fileManager.createDirectory(at: lock, withIntermediateDirectories: false)) == nil {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { try? fileManager.removeItem(at: lock) }

        guard let data = try? Data(contentsOf: configURL),
              var config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        var projects = config["projects"] as? [String: Any] ?? [:]
        var changed = false
        // Claude Code keys projects by resolved path; the path as given covers
        // a lookup that doesn't resolve.
        for path in Set([folder, resolved(folder)]) {
            var project = projects[path] as? [String: Any] ?? [:]
            guard project["hasTrustDialogAccepted"] as? Bool != true else { continue }
            project["hasTrustDialogAccepted"] = true
            projects[path] = project
            changed = true
        }
        guard changed else { return true }
        config["projects"] = projects
        guard let updated = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        ) else { return false }
        let permissions = (try? fileManager.attributesOfItem(atPath: configURL.path))?[.posixPermissions]
        do {
            try updated.write(to: configURL, options: .atomic)
        } catch {
            return false
        }
        if let permissions {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: configURL.path)
        }
        return true
    }

    private static func resolved(_ path: String) -> String {
        guard let pointer = realpath(path, nil) else { return path }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
