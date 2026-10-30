import AppKit

/// Which terminals each thread has and which one is showing. Pure bookkeeping: the drawer keeps
/// the live terminal views keyed by `TerminalSessionInfo.id` and asks this which to show, create
/// and tear down.
struct TerminalSessionInfo: Equatable, Sendable {
    var id: String
    /// "Terminal 1", "Terminal 2", … (numbers are not reused within a thread).
    var title: String
}

struct TerminalSessions {
    private struct ThreadTerminals {
        var sessions: [TerminalSessionInfo] = []
        var activeID: String?
        var nextNumber = 1
    }

    private var threads: [String: ThreadTerminals] = [:]
    private let makeID: () -> String

    init(makeID: @escaping () -> String = { UUID().uuidString }) {
        self.makeID = makeID
    }

    func sessions(for threadID: String) -> [TerminalSessionInfo] {
        threads[threadID]?.sessions ?? []
    }

    func activeSession(for threadID: String) -> TerminalSessionInfo? {
        guard let entry = threads[threadID] else { return nil }
        return entry.sessions.first { $0.id == entry.activeID } ?? entry.sessions.last
    }

    /// Thread ids that have at least one terminal.
    var threadIDs: Set<String> {
        Set(threads.filter { !$0.value.sessions.isEmpty }.keys)
    }

    /// Adds a terminal to the thread and makes it active.
    @discardableResult
    mutating func add(to threadID: String) -> TerminalSessionInfo {
        var entry = threads[threadID] ?? ThreadTerminals()
        let session = TerminalSessionInfo(id: makeID(), title: "Terminal \(entry.nextNumber)")
        entry.nextNumber += 1
        entry.sessions.append(session)
        entry.activeID = session.id
        threads[threadID] = entry
        return session
    }

    mutating func select(_ sessionID: String, in threadID: String) {
        guard threads[threadID]?.sessions.contains(where: { $0.id == sessionID }) == true else { return }
        threads[threadID]?.activeID = sessionID
    }

    /// Removes a terminal. The neighbour that took its place (or the one before it) becomes
    /// active. Returns whether it existed.
    @discardableResult
    mutating func close(_ sessionID: String, in threadID: String) -> Bool {
        guard var entry = threads[threadID], let index = entry.sessions.firstIndex(where: { $0.id == sessionID }) else {
            return false
        }
        entry.sessions.remove(at: index)
        if entry.activeID == sessionID {
            entry.activeID = entry.sessions.isEmpty ? nil : entry.sessions[min(index, entry.sessions.count - 1)].id
        }
        threads[threadID] = entry
        return true
    }

    /// Drops every thread not in `liveThreadIDs` (deleted threads). Returns the removed
    /// sessions so their processes can be ended.
    mutating func prune(keeping liveThreadIDs: Set<String>) -> [TerminalSessionInfo] {
        var removed: [TerminalSessionInfo] = []
        for (threadID, entry) in threads where !liveThreadIDs.contains(threadID) {
            removed += entry.sessions
            threads[threadID] = nil
        }
        return removed
    }

    /// Forgets everything (app quit). Returns every session.
    mutating func removeAll() -> [TerminalSessionInfo] {
        defer { threads = [:] }
        return threads.values.flatMap(\.sessions)
    }
}
