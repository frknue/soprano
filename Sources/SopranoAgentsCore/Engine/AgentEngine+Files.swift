import Foundation

// The right panel's file explorer and viewer: a thread's working directory through
// `environment.files`. Listing and reading run off the main actor.

extension AgentEngine {
    /// The thread's working directory files (throws `EngineError.unknownThread`).
    public func workspaceFiles(_ threadID: String) async throws -> [String] {
        guard let thread = thread(threadID) else { throw EngineError.unknownThread(threadID) }
        return try await environment.files.listFiles(root: workingDirectory(for: thread))
    }

    /// Reads one file of the thread's working directory; rejects paths escaping it (`..`,
    /// absolute, symlink out of root) with `EngineError.message`.
    public func readWorkspaceFile(_ threadID: String, path: String) async throws -> WorkspaceFileContent {
        guard let thread = thread(threadID) else { throw EngineError.unknownThread(threadID) }
        let root = workingDirectory(for: thread)
        guard WorkspaceFilePath.resolve(root: root, relativePath: path) != nil else {
            throw EngineError.message("\(path) is outside the workspace.")
        }
        return try await environment.files.readFile(root: root, relativePath: path)
    }

    /// Absolute URL of a workspace-relative path, nil when it escapes the working directory or
    /// the thread is unknown. Pure path math, no I/O beyond symlink resolution.
    public func workspaceFileURL(_ threadID: String, path: String) -> URL? {
        guard let thread = thread(threadID) else { return nil }
        return WorkspaceFilePath.resolve(root: workingDirectory(for: thread), relativePath: path)
    }
}
