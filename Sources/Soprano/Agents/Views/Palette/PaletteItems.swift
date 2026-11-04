import Foundation
import SopranoAgentsCore

/// What choosing a palette row does.
enum PaletteChoice: Equatable {
    /// Runs a registered command.
    case command(String)
    /// Selects a thread.
    case thread(String)
    /// Starts a new thread (draft) in a project.
    case project(String)
    /// Adds the folder as a project, then starts a new thread in it.
    case folder(String)
    /// Picks any folder in a Finder panel and adds it as a project.
    case chooseFolder
    /// Opens the settings screen on a page.
    case settings(SettingsPage)
}

/// One palette row before it becomes Soprano's `CommandItem`.
struct PaletteRow: Equatable {
    var id: String
    var icon: String
    var label: String
    var description: String
    /// K1 keycaps of the bound shortcut (`["⌘E"]`), empty when unbound.
    var shortcut: [String] = []
    /// Other text the query may match (ids, branch, project); never highlighted.
    var searchText: String?
    var choice: PaletteChoice
}

/// A direct subfolder of a configured project directory.
struct ProjectFolder: Equatable {
    var name: String
    var path: String
}

enum ProjectFolders {
    /// The non-hidden direct subfolders of `roots` (standardized, each once), by name then
    /// path. Missing or unreadable roots list nothing.
    static func scan(_ roots: [String], fileManager: FileManager = .default) -> [ProjectFolder] {
        var byPath: [String: ProjectFolder] = [:]
        for root in roots {
            guard let children = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let url = child.standardizedFileURL
                byPath[url.path] = ProjectFolder(name: url.lastPathComponent, path: url.path)
            }
        }
        return byPath.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }
}

/// The palette's lists.
enum PaletteItems {
    /// The command palette: enabled palette commands with their live keycaps, then threads by
    /// last use, projects, settings pages and their rows.
    @MainActor
    static func root(
        commands: [AppCommand],
        context: CommandContext,
        keycaps: (String) -> [String]?,
        engine: AgentEngine,
        now: Date
    ) -> [PaletteRow] {
        var rows: [PaletteRow] = []
        for command in commands where command.inPalette && command.id != "palette.open" && command.isEnabled(context) {
            rows.append(PaletteRow(
                id: "command:\(command.id)",
                icon: command.icon,
                label: command.title,
                description: command.description,
                shortcut: keycaps(command.id) ?? [],
                searchText: command.id,
                choice: .command(command.id)
            ))
        }

        let projectsByID = Dictionary(engine.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for thread in engine.threads.filter({ $0.archivedAt == nil }).sorted(by: { lastUse($0) > lastUse($1) }) {
            let project = thread.projectID.flatMap { projectsByID[$0] }
            let context = [project?.title, thread.branch].compactMap { $0 }
            rows.append(PaletteRow(
                id: "thread:\(thread.id)",
                icon: "bubble.left",
                label: thread.title,
                description: (context + [DurationText.relative(thread.activityDate, now: now)]).joined(separator: " · "),
                searchText: context.joined(separator: " "),
                choice: .thread(thread.id)
            ))
        }

        rows += engine.projects.map(projectRow)

        for page in SettingsPage.allCases {
            rows.append(PaletteRow(
                id: "settings:\(page.rawValue)",
                icon: page.icon,
                label: page.title,
                description: "Settings",
                searchText: "settings",
                choice: .settings(page)
            ))
            for row in page.searchRows {
                rows.append(PaletteRow(
                    id: "settings:\(page.rawValue):\(row.title)",
                    icon: page.icon,
                    label: row.title,
                    description: "Settings · \(page.title)",
                    searchText: row.terms,
                    choice: .settings(page)
                ))
            }
        }
        return rows
    }

    /// Open Project…: the projects (A–Z), then the folders of the project directories that are
    /// no project yet, then "Choose Folder…".
    @MainActor
    static func projects(engine: AgentEngine, folders: [ProjectFolder]) -> [PaletteRow] {
        let projects = engine.projects.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let known = Set(projects.map(\.path))
        let candidates = folders.filter { !known.contains($0.path) }.map { folder in
            PaletteRow(
                id: "folder:\(folder.path)",
                icon: "folder",
                label: folder.name,
                description: abbreviated(folder.path),
                searchText: folder.path,
                choice: .folder(folder.path)
            )
        }
        let choose = PaletteRow(
            id: "chooseFolder",
            icon: Icon.folderPlus,
            label: "Choose Folder…",
            description: "Add any folder as a project",
            choice: .chooseFolder
        )
        return projects.map(projectRow) + candidates + [choose]
    }

    private static func projectRow(_ project: Project) -> PaletteRow {
        PaletteRow(
            id: "project:\(project.id)",
            icon: "folder.fill",
            label: project.title,
            description: abbreviated(project.path),
            searchText: project.path,
            choice: .project(project.id)
        )
    }

    static func abbreviated(_ path: String) -> String {
        NSString(string: path).abbreviatingWithTildeInPath
    }

    /// Used recently: written in or opened, whichever is later.
    static func lastUse(_ thread: AgentThread) -> Date {
        max(thread.activityDate, thread.lastVisitedAt ?? .distantPast)
    }
}
