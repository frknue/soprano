import Foundation
import SopranoAgentsCore

/// What choosing a palette entry does.
enum PaletteEntryKind: Equatable {
    /// Runs a registered command.
    case command(String)
    /// Opens a nested list.
    case submenu(PaletteSubmenu)
    /// Selects a thread.
    case thread(String)
    /// Starts a new thread (draft) in a project.
    case project(String)
    /// Opens the settings screen on a page.
    case settings(SettingsPage)
}

/// Nested palette lists.
enum PaletteSubmenu: Equatable {
    /// "New thread in..." → the projects.
    case newThreadIn

    var placeholder: String { "Search projects..." }
}

/// One row of the palette.
struct PaletteEntry: Equatable {
    var id: String
    var kind: PaletteEntryKind
    var title: String
    /// Second line (thread project · branch, project path, settings page).
    var subtitle: String?
    var icon: String
    /// Keycaps of the bound shortcut (`["⌘B"]`, `["⌃A", "P"]`), empty when unbound.
    var keycaps: [String] = []
    /// Right-aligned meta (a thread's relative time).
    var trailing: String?
    /// Other text the query may match (ids, branch, project); never highlighted.
    var searchTerms: [String] = []
    /// Matched character offsets in `title` for the current query.
    var highlights: [Int] = []

    var isSubmenu: Bool {
        if case .submenu = kind { return true }
        return false
    }
}

struct PaletteGroup: Equatable {
    var title: String
    var entries: [PaletteEntry]
}

/// Everything the palette can list, built once when it opens.
struct PaletteSource: Equatable {
    /// Enabled palette commands (and the "New thread in..." submenu), in registry order.
    var actions: [PaletteEntry]
    /// Non-archived threads, most recently used first.
    var threads: [PaletteEntry]
    var projects: [PaletteEntry]
    /// Settings pages and their rows.
    var settings: [PaletteEntry]
}

/// Palette results over this app's sources: empty query → Actions +
/// Recent Threads; a query → ranked Actions, Threads, Projects, Settings; `>` → actions only;
/// the "New thread in..." submenu lists projects.
enum PaletteSearch {
    static let recentThreadLimit = 12

    static func groups(query rawQuery: String, submenu: PaletteSubmenu?, source: PaletteSource) -> [PaletteGroup] {
        if submenu == .newThreadIn {
            let query = rawQuery.trimmingCharacters(in: .whitespaces)
            let projects = query.isEmpty ? source.projects : rank(source.projects, query: query)
            return projects.isEmpty ? [] : [PaletteGroup(title: "Projects", entries: projects)]
        }
        if rawQuery.hasPrefix(">") {
            let query = rawQuery.dropFirst().trimmingCharacters(in: .whitespaces)
            let actions = query.isEmpty ? source.actions : rank(source.actions, query: query)
            return actions.isEmpty ? [] : [PaletteGroup(title: "Actions", entries: actions)]
        }
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            return [
                PaletteGroup(title: "Actions", entries: source.actions),
                PaletteGroup(title: "Recent Threads", entries: Array(source.threads.prefix(recentThreadLimit))),
            ].filter { !$0.entries.isEmpty }
        }
        return [
            PaletteGroup(title: "Actions", entries: rank(source.actions, query: query)),
            PaletteGroup(title: "Threads", entries: rank(source.threads, query: query)),
            PaletteGroup(title: "Projects", entries: rank(source.projects, query: query)),
            PaletteGroup(title: "Settings", entries: rank(source.settings, query: query)),
        ].filter { !$0.entries.isEmpty }
    }

    /// Entries matching `query`, best first (ties keep their order), with title highlights.
    /// Titles match fuzzily; the subtitle and search terms (ids, branch, keywords) only by
    /// substring, so a title match beats them and ids don't produce scattered noise.
    static func rank(_ entries: [PaletteEntry], query: String) -> [PaletteEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var scored: [(entry: PaletteEntry, score: Int, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            var best: Int?
            var highlighted = entry
            highlighted.highlights = []
            if let match = FuzzyMatch.match(query, in: entry.title) {
                best = match.score + 1000
                highlighted.highlights = match.positions
            }
            for text in [entry.subtitle].compactMap({ $0 }) + entry.searchTerms {
                guard !needle.isEmpty, let range = text.lowercased().range(of: needle) else { continue }
                let offset = text.lowercased().distance(from: text.lowercased().startIndex, to: range.lowerBound)
                best = max(best ?? .min, 500 - min(offset, 400))
            }
            if let best { scored.append((highlighted, best, index)) }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.entry)
    }
}

extension PaletteSource {
    /// The palette's lists for the current window: enabled palette commands with their live
    /// keycaps, threads by last use, projects, settings pages.
    @MainActor
    static func make(
        commands: [AppCommand],
        context: CommandContext,
        keycaps: (String) -> [String]?,
        engine: AgentEngine,
        now: Date
    ) -> PaletteSource {
        var actions: [PaletteEntry] = []
        if !engine.projects.isEmpty {
            actions.append(PaletteEntry(
                id: "submenu:newThreadIn",
                kind: .submenu(.newThreadIn),
                title: "New thread in...",
                icon: Icon.squarePen,
                searchTerms: ["new thread project"]
            ))
        }
        for command in commands where command.inPalette && command.id != "palette.open" && command.isEnabled(context) {
            actions.append(PaletteEntry(
                id: "command:\(command.id)",
                kind: .command(command.id),
                title: command.title,
                icon: command.icon,
                keycaps: keycaps(command.id) ?? [],
                searchTerms: [command.id]
            ))
        }

        let projectsByID = Dictionary(engine.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let threads = engine.threads
            .filter { $0.archivedAt == nil }
            .sorted { lastUse($0) > lastUse($1) }
            .map { thread -> PaletteEntry in
                let project = thread.projectID.flatMap { projectsByID[$0] }
                let subtitle = [project?.title, thread.branch].compactMap { $0 }.joined(separator: " · ")
                return PaletteEntry(
                    id: "thread:\(thread.id)",
                    kind: .thread(thread.id),
                    title: thread.title,
                    subtitle: subtitle.isEmpty ? nil : subtitle,
                    icon: "bubble.left",
                    trailing: DurationText.relative(thread.activityDate, now: now),
                    searchTerms: [thread.branch, project?.title].compactMap { $0 }
                )
            }

        let projects = engine.projects.map { project in
            PaletteEntry(
                id: "project:\(project.id)",
                kind: .project(project.id),
                title: project.title,
                subtitle: NSString(string: project.path).abbreviatingWithTildeInPath,
                icon: "folder",
                searchTerms: [project.path]
            )
        }

        var settings: [PaletteEntry] = []
        for page in SettingsPage.allCases {
            settings.append(PaletteEntry(
                id: "settings:\(page.rawValue)",
                kind: .settings(page),
                title: page.title,
                subtitle: "Settings",
                icon: page.icon,
                searchTerms: ["settings"]
            ))
            for row in page.searchRows {
                settings.append(PaletteEntry(
                    id: "settings:\(page.rawValue):\(row.title)",
                    kind: .settings(page),
                    title: row.title,
                    subtitle: "Settings · \(page.title)",
                    icon: page.icon,
                    searchTerms: [row.terms]
                ))
            }
        }
        return PaletteSource(actions: actions, threads: threads, projects: projects, settings: settings)
    }

    /// Used recently: written in or opened, whichever is later.
    static func lastUse(_ thread: AgentThread) -> Date {
        max(thread.activityDate, thread.lastVisitedAt ?? .distantPast)
    }
}
