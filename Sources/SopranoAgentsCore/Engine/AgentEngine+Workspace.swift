import Foundation

// Workspaces the UI attaches panels and terminals to: threads and project drafts.

extension AgentEngine {
    /// The working directory of `ref`: the thread's (`workingDirectory(for:)`) or the draft
    /// project's root; nil for an unknown thread or project.
    public func workingDirectory(of ref: WorkspaceRef) -> String? {
        switch ref {
        case let .thread(id): thread(id).map(workingDirectory(for:))
        case let .draft(projectID): project(projectID)?.path
        }
    }

    /// Keys (`WorkspaceRef.key`) of every live workspace: each thread and each project's draft.
    public var workspaceKeys: Set<String> {
        Set(threads.map(\.id)).union(projects.map { WorkspaceRef.draft(projectID: $0.id).key })
    }

    /// Top level of the repository `ref` works in (a linked worktree is its own); nil for an
    /// unknown thread or project, or a folder outside git.
    public func repositoryRoot(of ref: WorkspaceRef) async -> String? {
        guard let path = workingDirectory(of: ref) else { return nil }
        return await environment.git.repositoryRoot(path)
    }

    /// Where `ref` works: path, repository name and the path inside it, branch. nil for an
    /// unknown thread or project. Runs only cheap git reads (top level, `HEAD`) off the main actor.
    public func workspaceLocation(_ ref: WorkspaceRef) async -> WorkspaceLocation? {
        guard let path = workingDirectory(of: ref) else { return nil }
        var thread: AgentThread?
        if case let .thread(id) = ref { thread = self.thread(id) }
        if let thread, thread.projectID == nil, thread.worktreePath == nil {
            return WorkspaceLocation(path: path, kind: .scratch)
        }
        let kind: WorkspaceLocation.Kind = thread?.worktreePath == nil ? .checkout : .worktree
        let git = environment.git
        guard let root = await git.repositoryRoot(path) else {
            return WorkspaceLocation(path: path, kind: kind)
        }
        // A worktree folder is named after its branch; name it after the project's repository.
        var repository = root
        if kind == .worktree, let project = project(thread?.projectID) {
            repository = await git.repositoryRoot(project.path) ?? project.path
        }
        let branch = await git.checkedOutBranch(path)
        return WorkspaceLocation(
            path: path,
            kind: kind,
            repositoryName: URL(fileURLWithPath: repository).lastPathComponent,
            pathInRepository: Self.relativePath(of: path, inside: root),
            branch: branch
        )
    }

    /// `path` relative to `root` ("" when equal or outside), comparing symlink-resolved paths
    /// (git reports `/private/tmp` for `/tmp`).
    static func relativePath(of path: String, inside root: String) -> String {
        func components(_ path: String) -> [String] {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        }
        let inner = components(path)
        let outer = components(root)
        guard inner.count > outer.count, Array(inner.prefix(outer.count)) == outer else { return "" }
        return inner.dropFirst(outer.count).joined(separator: "/")
    }
}
