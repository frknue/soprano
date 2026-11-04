import Foundation

// The right panel's file explorer and viewer: a workspace's working directory through
// `environment.files`. Listing and reading run off the main actor.

extension AgentEngine {
    /// The workspace's files (throws `EngineError.unknownThread` / `.unknownProject`).
    public func workspaceFiles(_ workspace: WorkspaceRef) async throws -> [String] {
        try await environment.files.listFiles(root: requireRoot(workspace))
    }

    /// Reads one file of the workspace; rejects paths escaping it (`..`, absolute, symlink out
    /// of root) with `EngineError.message`.
    public func readWorkspaceFile(_ workspace: WorkspaceRef, path: String) async throws -> WorkspaceFileContent {
        let root = try requireRoot(workspace)
        guard WorkspaceFilePath.resolve(root: root, relativePath: path) != nil else {
            throw EngineError.message("\(path) is outside the workspace.")
        }
        return try await environment.files.readFile(root: root, relativePath: path)
    }

    /// Absolute URL of a workspace-relative path, nil when it escapes the working directory or
    /// the workspace is unknown. Pure path math, no I/O beyond symlink resolution.
    public func workspaceFileURL(_ workspace: WorkspaceRef, path: String) -> URL? {
        guard let root = workingDirectory(of: workspace) else { return nil }
        return WorkspaceFilePath.resolve(root: root, relativePath: path)
    }

    private func requireRoot(_ workspace: WorkspaceRef) throws -> String {
        if let root = workingDirectory(of: workspace) { return root }
        switch workspace {
        case let .thread(id): throw EngineError.unknownThread(id)
        case let .draft(projectID): throw EngineError.unknownProject(projectID)
        }
    }
}
