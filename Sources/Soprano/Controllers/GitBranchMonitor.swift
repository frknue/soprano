import Foundation

/// Resolves and watches git branch names for pane working directories.
/// Main-thread-only like the other managers; watcher events are delivered
/// on the main queue. Foundation-only so it can be compiled standalone.
final class GitBranchMonitor: @unchecked Sendable {
    /// Fired whenever a watched HEAD changes on disk.
    var onChange: (() -> Void)?

    /// cwd -> resolved HEAD file path (nil = resolved as "not inside a repo").
    private var headPathByCwd: [String: String?] = [:]
    /// HEAD path -> cached branch name.
    private var branchByHeadPath: [String: String] = [:]
    /// HEAD path -> active file watcher.
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]

    deinit {
        for watcher in watchers.values {
            watcher.cancel()
        }
    }

    // MARK: - Public API

    /// Current branch for a working directory; nil when not in a git repo.
    func branch(for cwd: String) -> String? {
        let headPath: String?
        if let cached = headPathByCwd[cwd] {
            headPath = cached
        } else {
            headPath = Self.resolveHeadPath(startingAt: cwd)
            headPathByCwd[cwd] = headPath
        }
        guard let headPath else { return nil }
        if let cached = branchByHeadPath[headPath] {
            return cached
        }
        let branch = Self.parseHead(at: headPath)
        branchByHeadPath[headPath] = branch
        return branch
    }

    /// Reconcile watchers with the current set of pane working directories.
    func setWatchedPaths(_ paths: [String]) {
        var newHeadPathByCwd: [String: String?] = [:]
        var neededHeadPaths = Set<String>()
        for cwd in Set(paths) {
            let headPath: String?
            if let cached = headPathByCwd[cwd] {
                headPath = cached
            } else {
                headPath = Self.resolveHeadPath(startingAt: cwd)
            }
            newHeadPathByCwd[cwd] = headPath
            if let headPath {
                neededHeadPaths.insert(headPath)
            }
        }
        headPathByCwd = newHeadPathByCwd

        for (headPath, watcher) in watchers where !neededHeadPaths.contains(headPath) {
            watcher.cancel()
            watchers.removeValue(forKey: headPath)
            branchByHeadPath.removeValue(forKey: headPath)
        }
        for headPath in neededHeadPaths where watchers[headPath] == nil {
            addWatcher(for: headPath)
            if watchers[headPath] == nil {
                // Watcher couldn't be established (unreadable HEAD, exhausted
                // fds): drop the cache so each rebuild re-reads instead of
                // serving a stale branch forever.
                branchByHeadPath.removeValue(forKey: headPath)
            }
        }
    }

    // MARK: - Watching

    private func addWatcher(for headPath: String) {
        let fd = open(headPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.headChanged(headPath)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        watchers[headPath] = source
    }

    private func headChanged(_ headPath: String) {
        // git updates HEAD via atomic rename, which orphans the watched fd —
        // drop the watcher and re-arm on the new inode.
        watchers[headPath]?.cancel()
        watchers.removeValue(forKey: headPath)
        branchByHeadPath.removeValue(forKey: headPath)
        if FileManager.default.fileExists(atPath: headPath) {
            addWatcher(for: headPath)
        }
        onChange?()
    }

    // MARK: - Resolution & Parsing

    /// Walk up from `path` to the repo's HEAD file. Handles `.git`
    /// directories and `.git` files containing a `gitdir:` pointer
    /// (worktrees and submodules).
    static func resolveHeadPath(startingAt path: String) -> String? {
        var dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let fm = FileManager.default
        while true {
            let gitURL = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return gitURL.appendingPathComponent("HEAD").path
                }
                guard let contents = try? String(contentsOf: gitURL, encoding: .utf8) else {
                    return nil
                }
                let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("gitdir:") else { return nil }
                let target = line.dropFirst("gitdir:".count)
                    .trimmingCharacters(in: .whitespaces)
                let gitDirURL = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target)
                    : dir.appendingPathComponent(target).standardizedFileURL
                return gitDirURL.appendingPathComponent("HEAD").path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                return nil
            }
            dir = parent
        }
    }

    /// "ref: refs/heads/main" -> "main"; detached HEAD -> 7-char sha prefix.
    static func parseHead(at headPath: String) -> String? {
        guard let contents = try? String(contentsOfFile: headPath, encoding: .utf8) else {
            return nil
        }
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") {
            let name = String(line.dropFirst("ref: refs/heads/".count))
            return name.isEmpty ? nil : name
        }
        if line.hasPrefix("ref: ") {
            return line.split(separator: "/").last.map(String.init)
        }
        guard line.count >= 7 else { return nil }
        return String(line.prefix(7))
    }
}
