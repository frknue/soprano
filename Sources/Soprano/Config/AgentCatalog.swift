import Foundation

/// Process-wide registry of agent profiles: the built-ins from `DefaultAgents`
/// overlaid with whatever `settings.json` declares.
///
/// Every lookup in the app goes through here rather than through
/// `DefaultAgents` directly, so a user-defined agent behaves exactly like a
/// built-in one — pane headers, the sidebar launcher menu, notifications, and
/// workspace restore all resolve it the same way.
///
/// Storage is lock-protected rather than main-actor isolated because callers
/// span both worlds: `AgentManager` is `@unchecked Sendable` and resolves
/// profiles off the actor, while the views read it on the main thread.
final class AgentCatalog: @unchecked Sendable {
    static let shared = AgentCatalog()

    private let lock = NSLock()
    private var profiles: [AgentProfile]

    private init() {
        profiles = DefaultAgents.all
    }

    var all: [AgentProfile] {
        lock.lock()
        defer { lock.unlock() }
        return profiles
    }

    func profile(for id: String) -> AgentProfile? {
        lock.lock()
        defer { lock.unlock() }
        return profiles.first { $0.id == id }
    }

    func replaceAll(with profiles: [AgentProfile]) {
        lock.lock()
        defer { lock.unlock() }
        self.profiles = profiles
    }

    // MARK: - Convenience

    /// Mirrors `DefaultAgents.all` so call sites read the merged catalog by
    /// changing only the type name.
    static var all: [AgentProfile] { shared.all }

    static func profile(for id: String) -> AgentProfile? { shared.profile(for: id) }

    static func replaceAll(with profiles: [AgentProfile]) { shared.replaceAll(with: profiles) }
}
