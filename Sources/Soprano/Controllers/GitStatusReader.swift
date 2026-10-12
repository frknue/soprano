import Foundation

/// Reads explorer decorations, Source Control changes, and diffs from git.
/// Every call blocks on a child process, so callers run it off the main thread.
enum GitStatusReader {
    /// Larger diffs are not shown, like files over the editor's size limit.
    static let maximumDiffBytes = 8 * 1024 * 1024
    /// Untracked files get their lines counted for the Source Control list,
    /// but only this many, and only files up to `maximumCountedFileBytes`.
    static let maximumCountedUntrackedFiles = 500
    static let maximumCountedFileBytes = 2 * 1024 * 1024

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
        return GitStatusSnapshot(
            entries: GitStatusSnapshot.parseStatus(statusData),
            ignoredPaths: ignoredPaths(root: root)
        )
    }

    /// Ignored files, and ignored folders as one entry each.
    static func ignoredPaths(root: String) -> Set<String> {
        let data = run(
            ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"],
            in: root
        ) ?? Data()
        return GitStatusSnapshot.parseIgnored(data)
    }

    /// The Source Control list for the working tree at `root`, with line
    /// counts, or nil when git cannot read it.
    static func changes(root: String) -> GitChangeList? {
        guard let statusData = run(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"],
            in: root
        ) else {
            return nil
        }
        var list = GitChangeList.parse(status: statusData)
        for area in [GitChangeArea.unstaged, .staged] where list.changes.contains(where: { $0.area == area }) {
            let arguments = ["diff", "-z", "--numstat", "--no-renames", "--no-ext-diff", "--no-textconv"]
                + (area == .staged ? ["--cached"] : [])
            if let data = run(arguments, in: root) {
                list.applyLineCounts(GitChangeList.parseNumstat(data), in: area)
            }
        }
        var counted = 0
        for index in list.changes.indices where list.changes[index].area == .untracked {
            guard counted < maximumCountedUntrackedFiles else { break }
            counted += 1
            let url = URL(fileURLWithPath: root).appendingPathComponent(list.changes[index].path)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
                .flatMap({ $0.isRegularFile == true ? $0.fileSize : nil }),
                size <= maximumCountedFileBytes,
                let data = try? Data(contentsOf: url),
                let lines = GitChangeList.lineCount(of: data)
            else { continue }
            list.changes[index].linesAdded = lines
            list.changes[index].linesDeleted = 0
        }
        return list
    }

    /// The whole-file diff of `relativePath`: HEAD against the index when
    /// `staged`, else the index against the working tree, where an untracked
    /// file is all additions.
    static func diff(root: String, relativePath: String, staged: Bool) -> GitFileDiff {
        guard executableURL != nil else { return .unavailable }
        let options = [
            "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
            // Every line as context, so the view shows the whole file.
            "--unified=\(Int32.max)",
        ]
        // Pathspec magic would read `[id].tsx` as a pattern.
        let tracked = execute(
            ["--literal-pathspecs", "diff"] + (staged ? ["--cached"] : []) + options + ["--", relativePath],
            in: root,
            byteLimit: maximumDiffBytes
        )
        switch tracked {
        case .failed:
            return .unavailable
        case .tooLarge:
            return .tooLarge
        case .data(let data):
            if staged || !data.isEmpty {
                return GitFileDiff.parse(patch: data)
            }
        }
        // An untracked file has no index entry for `git diff` to compare.
        guard let listed = run(
            ["--literal-pathspecs", "ls-files", "-z", "--others", "--exclude-standard", "--", relativePath],
            in: root
        ), !listed.isEmpty else {
            return .noChanges
        }
        switch execute(
            ["diff", "--no-index"] + options + ["--", "/dev/null", relativePath],
            in: root,
            // `--no-index` exits with 1 when the files differ.
            acceptedStatuses: [0, 1],
            byteLimit: maximumDiffBytes
        ) {
        case .failed:
            return .unavailable
        case .tooLarge:
            return .tooLarge
        case .data(let data):
            return GitFileDiff.parse(patch: data)
        }
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
        if case .data(let data) = execute(arguments, in: directory) {
            return data
        }
        return nil
    }

    private enum Output {
        case data(Data)
        case failed
        case tooLarge
    }

    /// Runs git in `directory`. Output beyond `byteLimit` stops git rather
    /// than being buffered.
    private static func execute(
        _ arguments: [String],
        in directory: String,
        acceptedStatuses: Set<Int32> = [0],
        byteLimit: Int = .max
    ) -> Output {
        guard let executableURL else { return .failed }
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
            return .failed
        }
        let handle = output.fileHandleForReading
        var data = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            data.append(chunk)
            if data.count > byteLimit {
                process.terminate()
                try? handle.close()
                process.waitUntilExit()
                return .tooLarge
            }
        }
        process.waitUntilExit()
        return acceptedStatuses.contains(process.terminationStatus) ? .data(data) : .failed
    }
}
