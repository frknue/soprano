import Foundation

/// The runs automations made and when each is due next: app state, kept in
/// Soprano's Application Support folder beside the accounts it manages, not
/// in `settings.json`, which only says what the automations are.
@MainActor
final class AutomationStore {
    /// When an automation runs next, and the schedule that time was computed
    /// for: a changed schedule, or one switched back on, counts from now.
    struct ScheduleState: Codable, Equatable, Sendable {
        var signature: String
        var nextRunAt: Date?
    }

    private struct Document: Codable {
        var schedules: [String: ScheduleState] = [:]
        var runs: [AutomationRun] = []
    }

    /// Finished runs kept per automation; unfinished ones are always kept.
    static let finishedRunLimit = 100

    let fileURL: URL?
    private(set) var schedules: [String: ScheduleState]
    /// Oldest first.
    private(set) var runs: [AutomationRun]

    private var observers: [String: () -> Void] = [:]

    /// `fileURL` nil keeps everything in memory, for tests.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        let document = fileURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? Self.decoder.decode(Document.self, from: $0) }
            ?? Document()
        schedules = document.schedules
        runs = document.runs
    }

    nonisolated static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        // Dev and installed builds have their own bundle ids, so their
        // automations never record into each other's history.
        return applicationSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Soprano", isDirectory: true)
            .appendingPathComponent("automations.json", isDirectory: false)
    }

    // MARK: - Reading

    func run(_ id: String) -> AutomationRun? {
        runs.last { $0.id == id }
    }

    /// Newest first.
    func runs(for automationId: String) -> [AutomationRun] {
        runs.filter { $0.automationId == automationId }.reversed()
    }

    func lastRun(for automationId: String) -> AutomationRun? {
        runs.last { $0.automationId == automationId }
    }

    var openRuns: [AutomationRun] {
        runs.filter { !$0.status.isFinal }
    }

    func nextRunNumber(for automationId: String) -> Int {
        (runs.lazy.filter { $0.automationId == automationId }.map(\.number).max() ?? 0) + 1
    }

    // MARK: - Writing

    func setSchedule(_ state: ScheduleState?, for automationId: String) {
        guard schedules[automationId] != state else { return }
        schedules[automationId] = state
        save()
    }

    func insert(_ run: AutomationRun) {
        runs.append(run)
        prune(automationId: run.automationId)
        save()
    }

    func update(_ id: String, _ change: (inout AutomationRun) -> Void) {
        guard let index = runs.lastIndex(where: { $0.id == id }) else { return }
        var run = runs[index]
        change(&run)
        guard run != runs[index] else { return }
        runs[index] = run
        save()
    }

    /// Forgets an automation's runs and schedule, as deleting it does.
    func removeAll(for automationId: String) {
        runs.removeAll { $0.automationId == automationId }
        schedules[automationId] = nil
        save()
    }

    private func prune(automationId: String) {
        let finished = runs.indices.filter {
            runs[$0].automationId == automationId && runs[$0].status.isFinal
        }
        let excess = finished.count - Self.finishedRunLimit
        guard excess > 0 else { return }
        let dropped = Set(finished.prefix(excess))
        runs = runs.indices.filter { !dropped.contains($0) }.map { runs[$0] }
    }

    private func save() {
        notifyObservers()
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(Document(schedules: schedules, runs: runs))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Soprano: could not save automations to \(fileURL.path): \(error)")
        }
    }

    // MARK: - Observers

    func addObserver(id: String, _ handler: @escaping () -> Void) {
        observers[id] = handler
    }

    func removeObserver(id: String) {
        observers[id] = nil
    }

    private func notifyObservers() {
        for handler in observers.values {
            handler()
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
