import AppKit

/// Which terminals each thread has, where each one lives (drawer or right-panel tab) and which one
/// is showing per placement. Pure bookkeeping: `ThreadTerminalStore` keeps the live terminal views
/// keyed by `TerminalSessionInfo.id` and asks this which to show, create and tear down.
struct TerminalSessionInfo: Equatable, Sendable {
    var id: String
    /// "Terminal 1", "Terminal 2", … (numbers are shared across placements and not reused within a thread).
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

    private struct ThreadTerminals {
        var sessions: [Entry] = []
        var activeIDs: [Placement: String] = [:]
        var nextNumber = 1
    }

    private var threads: [String: ThreadTerminals] = [:]
    private let makeID: () -> String

    init(makeID: @escaping () -> String = { UUID().uuidString }) {
        self.makeID = makeID
    }

    func sessions(for threadID: String, placement: Placement = .drawer) -> [TerminalSessionInfo] {
        threads[threadID]?.sessions.filter { $0.placement == placement }.map(\.info) ?? []
    }

    func activeSession(for threadID: String, placement: Placement = .drawer) -> TerminalSessionInfo? {
        let list = sessions(for: threadID, placement: placement)
        let activeID = threads[threadID]?.activeIDs[placement]
        return list.first { $0.id == activeID } ?? list.last
    }

    /// The thread and placement of a session, nil when unknown.
    func locate(_ sessionID: String) -> (threadID: String, info: TerminalSessionInfo, placement: Placement)? {
        for (threadID, entry) in threads {
            if let found = entry.sessions.first(where: { $0.info.id == sessionID }) {
                return (threadID, found.info, found.placement)
            }
        }
        return nil
    }

    /// Thread ids that have at least one terminal.
    var threadIDs: Set<String> {
        Set(threads.filter { !$0.value.sessions.isEmpty }.keys)
    }

    /// Adds a terminal to the thread in `placement` and makes it that placement's active one.
    @discardableResult
    mutating func add(to threadID: String, placement: Placement = .drawer) -> TerminalSessionInfo {
        var entry = threads[threadID] ?? ThreadTerminals()
        let session = TerminalSessionInfo(id: makeID(), title: "Terminal \(entry.nextNumber)")
        entry.nextNumber += 1
        entry.sessions.append(Entry(info: session, placement: placement))
        entry.activeIDs[placement] = session.id
        threads[threadID] = entry
        return session
    }

    mutating func select(_ sessionID: String, in threadID: String) {
        guard let found = threads[threadID]?.sessions.first(where: { $0.info.id == sessionID }) else { return }
        threads[threadID]?.activeIDs[found.placement] = sessionID
    }

    /// Removes a terminal. The neighbour (same placement) that took its place, or the one before
    /// it, becomes active. Returns whether it existed.
    @discardableResult
    mutating func close(_ sessionID: String, in threadID: String) -> Bool {
        guard var entry = threads[threadID], let index = entry.sessions.firstIndex(where: { $0.info.id == sessionID }) else {
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
        threads[threadID] = entry
        return true
    }

    /// Drops every thread not in `liveThreadIDs` (deleted threads). Returns the removed
    /// sessions with their thread so their processes can be ended.
    mutating func prune(keeping liveThreadIDs: Set<String>) -> [(threadID: String, info: TerminalSessionInfo)] {
        var removed: [(threadID: String, info: TerminalSessionInfo)] = []
        for (threadID, entry) in threads where !liveThreadIDs.contains(threadID) {
            removed += entry.sessions.map { (threadID, $0.info) }
            threads[threadID] = nil
        }
        return removed
    }

    /// Forgets everything (app quit). Returns every session.
    mutating func removeAll() -> [TerminalSessionInfo] {
        defer { threads = [:] }
        return threads.values.flatMap { $0.sessions.map(\.info) }
    }
}
