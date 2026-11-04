import Foundation

/// `WorkspaceFileService` over the file system, listing through git (`GitRunner`) when the root
/// is inside a work tree and walking the directory otherwise. Every call runs off the main actor.
public struct LiveWorkspaceFileService: WorkspaceFileService {
    /// nil when no git executable exists; listing then always walks the directory.
    let runner: GitRunner?

    public init() {
        self.init(runner: GitRunner.resolveExecutable().map { GitRunner(executable: $0) })
    }

    init(runner: GitRunner?) {
        self.runner = runner
    }

    // MARK: Listing

    public func listFiles(root: String) async throws -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineError.message("The workspace folder \(root) doesn't exist.")
        }
        if let runner {
            // 128: not a work tree (or git refused the directory); fall back to the walk.
            let result = try await runner.run(
                ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                in: rootURL, isRead: true, acceptedExitCodes: [0, 128]
            )
            if result.exitCode == 0 {
                return Self.existingFiles(Self.nulSeparated(result.stdout), root: root)
            }
        }
        try Task.checkCancellation()
        return Self.walk(root: root)
    }

    /// Unique entries of `ls-files -z` output (unmerged entries repeat once per stage).
    static func nulSeparated(_ data: Data) -> Set<String> {
        Set(data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }

    /// `paths` that exist under `root` as regular files or symlinks (deleted tracked files,
    /// submodule and nested-repository directories drop out), sorted.
    static func existingFiles(_ paths: Set<String>, root: String) -> [String] {
        paths.filter { path in
            var info = stat()
            guard lstat(root + "/" + path, &info) == 0 else { return false }
            let type = info.st_mode & S_IFMT
            return type == S_IFREG || type == S_IFLNK
        }
        .sorted()
    }

    /// Regular files under `root`, skipping `WorkspaceFileLimits.skippedDirectories`, at most
    /// `maximumWalkedFiles`, sorted. Symlinked directories are not entered.
    static func walk(root: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var files: [String] = []
        while let path = enumerator.nextObject() as? String {
            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                if WorkspaceFileLimits.skippedDirectories.contains((path as NSString).lastPathComponent) {
                    enumerator.skipDescendants()
                }
            } else if type == .typeRegular {
                files.append(path)
                if files.count >= WorkspaceFileLimits.maximumWalkedFiles { break }
            }
        }
        return files.sorted()
    }

    // MARK: Reading

    public func readFile(root: String, relativePath: String) async throws -> WorkspaceFileContent {
        guard let url = WorkspaceFilePath.resolve(root: root, relativePath: relativePath) else {
            throw EngineError.message("\(relativePath) is outside the workspace.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw EngineError.message("\(relativePath) doesn't exist.")
        }
        guard !isDirectory.boolValue else {
            throw EngineError.message("\(relativePath) is a folder.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let fileExtension = (relativePath as NSString).pathExtension.lowercased()

        if WorkspaceFileLimits.imageExtensions.contains(fileExtension) {
            guard byteCount <= WorkspaceFileLimits.maximumImageBytes else { return .tooLarge(byteCount: byteCount) }
            return .image(try Data(contentsOf: url))
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let probe = try handle.read(upToCount: WorkspaceFileLimits.binaryProbeBytes) ?? Data()
        if probe.contains(0) { return .binary(byteCount: byteCount) }
        guard byteCount <= WorkspaceFileLimits.maximumTextBytes else { return .tooLarge(byteCount: byteCount) }
        let data = probe + (try handle.readToEnd() ?? Data())
        guard let text = String(data: data, encoding: .utf8) else { return .binary(byteCount: data.count) }
        return .text(text)
    }
}
