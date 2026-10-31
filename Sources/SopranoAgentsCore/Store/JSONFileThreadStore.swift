import Foundation
import os

/// Persists projects in `<dir>/projects.json` and each thread in `<dir>/threads/<id>.json`.
///
/// Writes are atomic and run on one serial background queue. Rapid saves of the same thread
/// (streaming deltas) coalesce: the latest value is written once `coalesceInterval` after the
/// first unsaved change. `flush()` writes everything pending before it returns.
public final class JSONFileThreadStore: ThreadStore, @unchecked Sendable {
    public let directory: URL
    let coalesceInterval: TimeInterval

    private enum PendingThread {
        case save(AgentThread)
        case delete
    }

    private let queue = DispatchQueue(label: "com.soprano.agents.store", qos: .utility)
    private let lock = NSLock()
    /// Latest unwritten state per thread id.
    private var pendingThreads: [String: PendingThread] = [:]
    /// Projects as last saved, in creation order; nil until read from disk.
    private var projects: [Project]?
    private var projectsDirty = false
    /// An existing projects.json could be neither read nor set aside: writing would destroy it,
    /// so project changes stay in memory for this session.
    private var projectsWritesBlocked = false

    private static let log = Logger(subsystem: "com.soprano.agents", category: "store")

    public convenience init(directory: URL) {
        self.init(directory: directory, coalesceInterval: 0.3)
    }

    init(directory: URL, coalesceInterval: TimeInterval) {
        self.directory = directory
        self.coalesceInterval = coalesceInterval
    }

    private var projectsURL: URL { directory.appendingPathComponent("projects.json") }
    private var threadsDirectory: URL { directory.appendingPathComponent("threads", isDirectory: true) }

    private func threadURL(_ id: String) -> URL {
        threadsDirectory.appendingPathComponent("\(id).json")
    }

    // MARK: Loading

    /// Reads everything on disk. Unreadable thread files are skipped (and logged); turns that were
    /// running when the app last quit come back interrupted.
    public func load() throws -> StoreSnapshot {
        flush()
        let projects = lock.withLock { loadedProjects() }
        var threads: [AgentThread] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: threadsDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                threads.append(Self.recovered(try decoder.decode(AgentThread.self, from: data)))
            } catch {
                Self.log.error("Skipping unreadable thread file \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        threads.sort { $0.createdAt < $1.createdAt }
        return StoreSnapshot(projects: projects, threads: threads)
    }

    /// A thread as it was persisted mid-turn: the running turn (and its live items) become
    /// interrupted; a yielded turn ends with its yielded outcome at its yield.
    static func recovered(_ thread: AgentThread) -> AgentThread {
        var thread = thread
        thread.isGeneratingTitle = false
        for index in thread.turns.indices where thread.turns[index].status == .running {
            var turn = thread.turns[index]
            let yielded = turn.isYielded
            turn.status = yielded ? turn.yieldedStatus : .interrupted
            turn.completedAt = turn.completedAt ?? turn.yieldedAt ?? turn.items.compactMap { $0.completedAt ?? $0.startedAt }.max() ?? turn.startedAt
            turn.yieldedAt = nil
            turn.stopRequestedAt = nil
            for item in turn.items.indices where turn.items[item].status.isActive {
                turn.items[item].status = yielded ? .completed : .interrupted
            }
            // The provider that asked is gone: answering now would reach nobody.
            for item in turn.items.indices {
                switch turn.items[item].kind {
                case var .approval(request) where request.decision == nil:
                    request.decision = .cancel
                    turn.items[item].kind = .approval(request)
                    turn.items[item].status = .declined
                case var .userInput(request) where request.answers == nil && !request.dismissed:
                    request.dismissed = true
                    turn.items[item].kind = .userInput(request)
                default:
                    break
                }
            }
            thread.turns[index] = turn
        }
        return thread
    }

    /// Call with `lock` held.
    private func loadedProjects() -> [Project] {
        if let projects { return projects }
        projects = readProjects()
        return projects ?? []
    }

    /// Call with `lock` held. A missing file is an empty list. An existing file that doesn't decode
    /// is moved aside under a unique name; one that can't be read or moved blocks project writes.
    private func readProjects() -> [Project] {
        guard FileManager.default.fileExists(atPath: projectsURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: projectsURL)
        } catch {
            projectsWritesBlocked = true
            Self.log.error("Cannot read projects.json; project changes will not be saved: \(String(describing: error), privacy: .public)")
            return []
        }
        do {
            return try JSONDecoder().decode([Project].self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = directory.appendingPathComponent("projects.json.unreadable-\(stamp)-\(UUID().uuidString.prefix(8))")
            do {
                try FileManager.default.moveItem(at: projectsURL, to: aside)
                Self.log.error("Moved unreadable projects.json to \(aside.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            } catch let moveError {
                projectsWritesBlocked = true
                Self.log.error("Cannot set aside unreadable projects.json; project changes will not be saved: \(String(describing: moveError), privacy: .public)")
            }
            return []
        }
    }

    // MARK: Projects

    public func save(project: Project) {
        lock.withLock {
            var list = loadedProjects()
            if let index = list.firstIndex(where: { $0.id == project.id }) {
                list[index] = project
            } else {
                list.append(project)
            }
            projects = list
            projectsDirty = true
        }
        queue.async { self.writeProjectsIfDirty() }
    }

    public func deleteProject(id: String) {
        lock.withLock {
            var list = loadedProjects()
            list.removeAll { $0.id == id }
            projects = list
            projectsDirty = true
        }
        queue.async { self.writeProjectsIfDirty() }
    }

    /// Runs on `queue`.
    private func writeProjectsIfDirty() {
        let snapshot: [Project]? = lock.withLock {
            guard projectsDirty, !projectsWritesBlocked else { return nil }
            projectsDirty = false
            return projects
        }
        guard let snapshot else { return }
        write(snapshot, to: projectsURL)
    }

    // MARK: Threads

    public func save(thread: AgentThread) {
        let schedule: Bool = lock.withLock {
            let alreadyPending = pendingThreads[thread.id] != nil
            pendingThreads[thread.id] = .save(thread)
            return !alreadyPending
        }
        guard schedule else { return }
        let id = thread.id
        queue.asyncAfter(deadline: .now() + coalesceInterval) { self.writePendingThread(id) }
    }

    public func deleteThread(id: String) {
        lock.withLock { pendingThreads[id] = .delete }
        queue.async { self.writePendingThread(id) }
    }

    /// Runs on `queue`.
    private func writePendingThread(_ id: String) {
        guard let pending = lock.withLock({ pendingThreads.removeValue(forKey: id) }) else { return }
        apply(pending, id: id)
    }

    private func apply(_ pending: PendingThread, id: String) {
        switch pending {
        case let .save(thread):
            write(thread, to: threadURL(id))
        case .delete:
            let url = threadURL(id)
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    Self.log.error("Could not delete thread file \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Writes every pending change before returning.
    public func flush() {
        queue.sync {
            writeProjectsIfDirty()
            let pending = lock.withLock {
                let all = pendingThreads
                pendingThreads.removeAll()
                return all
            }
            for (id, change) in pending {
                apply(change, id: id)
            }
        }
    }

    private func write(_ value: some Encodable, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("Could not write \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
