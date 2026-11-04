import Foundation

// The statistics board: the agent's recorded usage through `environment.usage`, read off the
// main actor.

extension AgentEngine {
    /// The usage history of `period` up to now. `sync` first ingests what the agent recorded
    /// since the last read (the board does on open and Refresh, not on every period switch); a
    /// failed sync still reads what was recorded before and reports itself in
    /// `UsageHistory.syncError`.
    public func usageHistory(_ period: UsagePeriod, sync: Bool) async throws -> UsageHistory {
        var syncError: String?
        if sync {
            do {
                try await environment.usage.sync()
            } catch {
                syncError = error.localizedDescription
            }
        }
        let now = environment.now()
        let calendar = Calendar.current
        let groups = try await environment.usage.groups(
            since: period.start(now: now, calendar: calendar),
            granularity: period.granularity
        )
        return UsageHistory(period: period, now: now, groups: groups, syncError: syncError, calendar: calendar)
    }

    /// Titles for usage folders (`UsageFolderName`) that belong to the app's projects: each
    /// project's root and each of its threads' working directories (worktrees) → the project's
    /// title; projectless threads' scratch folders → "No project".
    public func usageFolderTitles(
        home: String = NSHomeDirectory(),
        temporaryDirectory: String = NSTemporaryDirectory()
    ) -> [String: String] {
        func encode(_ path: String) -> String {
            UsageFolderName.encode(path, home: home, temporaryDirectory: temporaryDirectory)
        }
        var titles: [String: String] = [:]
        for thread in threads {
            let title = project(thread.projectID)?.title ?? "No project"
            titles[encode(workingDirectory(for: thread))] = title
        }
        for project in projects {
            titles[encode(project.path)] = project.title
        }
        return titles
    }
}
