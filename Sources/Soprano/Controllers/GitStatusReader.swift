import Foundation

/// Reads explorer decorations and file lists from git. Every call blocks on a
/// child process, so callers run it off the main thread.
enum GitStatusReader {
    /// The git executable to run, or nil when none is installed. `/usr/bin/git`
    /// is only a shim: without developer tools it pops an install dialog
    /// instead of running, so it is used only when the tools it forwards to
    /// exist.
    static let executableURL: URL? = {
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
    }()

    /// Decorations for the working tree at `root`: per-path status from
    /// `git status` and ignored paths from `git ls-files`.
    static func snapshot(root: String) -> GitStatusSnapshot {
        guard let statusData = run(
            ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
            in: root
        ) else {
            return .empty
        }
        let ignoredData = run(
            ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"],
            in: root
        ) ?? Data()
        return GitStatusSnapshot(
            entries: GitStatusSnapshot.parseStatus(statusData),
            ignoredPaths: GitStatusSnapshot.parseIgnored(ignoredData)
        )
    }

    /// Root-relative paths of every tracked or untracked, non-ignored file,
    /// or nil when `root` is not a git working tree.
    static func listFiles(root: String) -> [String]? {
        guard let data = run(
            ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate"],
            in: root
        ) else {
            return nil
        }
        return data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Runs git in `directory`, returning stdout on a zero exit status.
    private static func run(_ arguments: [String], in directory: String) -> Data? {
        guard let executableURL else { return nil }
        let process = Process()
        process.executableURL = executableURL
        // Reading must never take the index lock or rewrite the index: either
        // would race the user's own git commands and wake the file watcher.
        process.arguments = ["--no-optional-locks", "-C", directory] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
