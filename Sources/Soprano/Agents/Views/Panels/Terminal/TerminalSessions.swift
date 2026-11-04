import AppKit

/// Which terminals each workspace (`WorkspaceRef.key`) has, where each one lives (drawer or
/// right-panel tab) and which one is showing per placement. Pure bookkeeping:
/// `ThreadTerminalStore` keeps the live terminal views keyed by `TerminalSessionInfo.id` and asks
/// this which to show, create and tear down.
struct TerminalSessionInfo: Equatable, Sendable {
    var id: String
    /// "Terminal 1", "Terminal 2", … (numbers are shared across placements and not reused within a workspace).
    var title: String
}

struct TerminalSessions {
    /// Where a terminal is shown: the chat column's bottom drawer or a right-panel tab.
    enum Placement: Hashable, Sendable {
        case drawer, panel
    }

    private struct Entry {
        var info: TerminalSessionInfo
        var placement: Placement
    }

    private struct WorkspaceTerminals {
        var sessions: [Entry] = []
        var activeIDs: [Placement: String] = [:]
        var nextNumber = 1
    }

    private var workspaces: [String: WorkspaceTerminals] = [:]
    private let makeID: () -> String

    init(makeID: @escaping () -> String = { UUID().uuidString }) {
        self.makeID = makeID
    }

    func sessions(for key: String, placement: Placement = .drawer) -> [TerminalSessionInfo] {
        workspaces[key]?.sessions.filter { $0.placement == placement }.map(\.info) ?? []
    }

    func activeSession(for key: String, placement: Placement = .drawer) -> TerminalSessionInfo? {
        let list = sessions(for: key, placement: placement)
        let activeID = workspaces[key]?.activeIDs[placement]
        return list.first { $0.id == activeID } ?? list.last
    }

    /// The workspace and placement of a session, nil when unknown.
    func locate(_ sessionID: String) -> (key: String, info: TerminalSessionInfo, placement: Placement)? {
        for (key, entry) in workspaces {
            if let found = entry.sessions.first(where: { $0.info.id == sessionID }) {
                return (key, found.info, found.placement)
            }
        }
        return nil
    }

    /// Workspace keys that have at least one terminal.
    var keys: Set<String> {
        Set(workspaces.filter { !$0.value.sessions.isEmpty }.keys)
    }

    /// Adds a terminal to the workspace in `placement` and makes it that placement's active one.
    @discardableResult
    mutating func add(to key: String, placement: Placement = .drawer) -> TerminalSessionInfo {
        var entry = workspaces[key] ?? WorkspaceTerminals()
        let session = TerminalSessionInfo(id: makeID(), title: "Terminal \(entry.nextNumber)")
        entry.nextNumber += 1
        entry.sessions.append(Entry(info: session, placement: placement))
        entry.activeIDs[placement] = session.id
        workspaces[key] = entry
        return session
    }

    mutating func select(_ sessionID: String, in key: String) {
        guard let found = workspaces[key]?.sessions.first(where: { $0.info.id == sessionID }) else { return }
        workspaces[key]?.activeIDs[found.placement] = sessionID
    }

    /// Removes a terminal. The neighbour (same placement) that took its place, or the one before
    /// it, becomes active. Returns whether it existed.
    @discardableResult
    mutating func close(_ sessionID: String, in key: String) -> Bool {
        guard var entry = workspaces[key], let index = entry.sessions.firstIndex(where: { $0.info.id == sessionID }) else {
            return false
        }
        let placement = entry.sessions[index].placement
        let before = entry.sessions.filter { $0.placement == placement }.map(\.info.id)
        let position = before.firstIndex(of: sessionID) ?? 0
        entry.sessions.remove(at: index)
        if entry.activeIDs[placement] == sessionID {
            let remaining = before.filter { $0 != sessionID }
            entry.activeIDs[placement] = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)]
        }
        workspaces[key] = entry
        return true
    }

    /// Hands every terminal of `source` (with numbering and active ones) to `destination`, which
    /// must have none. Returns whether anything moved.
    @discardableResult
    mutating func move(from source: String, to destination: String) -> Bool {
        guard workspaces[destination]?.sessions.isEmpty ?? true,
              let entry = workspaces.removeValue(forKey: source), !entry.sessions.isEmpty else { return false }
        workspaces[destination] = entry
        return true
    }

    /// Drops every workspace not in `liveKeys` (deleted threads and projects). Returns the
    /// removed sessions with their workspace so their processes can be ended.
    mutating func prune(keeping liveKeys: Set<String>) -> [(key: String, info: TerminalSessionInfo)] {
        var removed: [(key: String, info: TerminalSessionInfo)] = []
        for (key, entry) in workspaces where !liveKeys.contains(key) {
            removed += entry.sessions.map { (key, $0.info) }
            workspaces[key] = nil
        }
        return removed
    }

    /// Forgets everything (app quit). Returns every session.
    mutating func removeAll() -> [TerminalSessionInfo] {
        defer { workspaces = [:] }
        return workspaces.values.flatMap { $0.sessions.map(\.info) }
    }
}
