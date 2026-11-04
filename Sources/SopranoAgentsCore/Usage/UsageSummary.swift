import Foundation

/// A model as the agent records it.
public struct UsageModelKey: Hashable, Sendable {
    public var provider: String
    public var model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// One line of a breakdown.
public struct UsageRow<Key: Hashable & Sendable>: Sendable {
    public var key: Key
    public var totals: UsageTotals
}

/// One chart bar: a local hour, day, week or month.
public struct UsageBucket: Sendable {
    public var start: Date
    public var totals: UsageTotals
}

/// The usage history of one period as read, with its chart buckets.
public struct UsageHistory: Sendable {
    public let period: UsagePeriod
    public let now: Date
    public let groups: [UsageGroup]
    /// Bucket starts, ascending; the last bucket runs through `now`.
    public let bucketStarts: [Date]
    public let bucketUnit: UsageBucketUnit
    /// Why the sync before this read failed; the groups are what was recorded before it.
    public let syncError: String?

    public init(period: UsagePeriod, now: Date, groups: [UsageGroup], syncError: String? = nil, calendar: Calendar = .current) {
        self.period = period
        self.now = now
        self.groups = groups
        self.syncError = syncError
        (bucketUnit, bucketStarts) = period.buckets(now: now, earliest: groups.lazy.map(\.start).min(), calendar: calendar)
    }

    /// Totals, chart buckets and breakdowns, limited to `model` when set. The model breakdown
    /// always lists every model, so another one can be picked.
    public func summary(model filter: UsageModelKey? = nil) -> UsageSummary {
        var totals = UsageTotals()
        var buckets = bucketStarts.map { UsageBucket(start: $0, totals: UsageTotals()) }
        var models: [UsageModelKey: UsageTotals] = [:]
        var folders: [String: UsageTotals] = [:]
        var agents: [String: UsageTotals] = [:]
        for group in groups {
            let key = UsageModelKey(provider: group.provider, model: group.model)
            models[key, default: UsageTotals()].add(group.totals)
            if let filter, filter != key { continue }
            totals.add(group.totals)
            folders[group.folder, default: UsageTotals()].add(group.totals)
            agents[group.agent, default: UsageTotals()].add(group.totals)
            if let index = bucketIndex(of: group.start) {
                buckets[index].totals.add(group.totals)
            }
        }
        return UsageSummary(
            totals: totals,
            buckets: buckets,
            models: Self.ranked(models) { "\($0.model) \($0.provider)" },
            folders: Self.ranked(folders) { $0 },
            agents: Self.ranked(agents) { $0 }
        )
    }

    /// The last bucket starting at or before `date`; nil before the first.
    func bucketIndex(of date: Date) -> Int? {
        var low = 0
        var high = bucketStarts.count
        while low < high {
            let mid = (low + high) / 2
            if bucketStarts[mid] <= date { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// Highest cost first, then most tokens, then by name.
    private static func ranked<Key>(_ totals: [Key: UsageTotals], name: (Key) -> String) -> [UsageRow<Key>] {
        totals.map { UsageRow(key: $0.key, totals: $0.value) }.sorted { lhs, rhs in
            if lhs.totals.cost != rhs.totals.cost { return lhs.totals.cost > rhs.totals.cost }
            if lhs.totals.tokens != rhs.totals.tokens { return lhs.totals.tokens > rhs.totals.tokens }
            return name(lhs.key) < name(rhs.key)
        }
    }
}

/// What the statistics board shows for one period and model filter.
public struct UsageSummary: Sendable {
    public var totals: UsageTotals
    public var buckets: [UsageBucket]
    /// Every model of the period, unfiltered.
    public var models: [UsageRow<UsageModelKey>]
    /// omp session folders (see `UsageFolderName`).
    public var folders: [UsageRow<String>]
    /// omp agent kinds (`main`, `subagent`, `advisor`, …).
    public var agents: [UsageRow<String>]
}

/// omp's session folder names: where it files a working directory's sessions, which is how its
/// usage history names a project.
public enum UsageFolderName {
    /// The stats folder for `path`. omp files a working directory's sessions under its
    /// canonical path (`realpath`, so `/tmp/x` is `/private/tmp/x`): under the temporary
    /// directory `-tmp-<relative>`, under home `-<relative>` (home itself `-`), elsewhere
    /// `--<absolute>--`, with `/`, `\` and `:` as `-`. Its stats then store that name with a
    /// leading `--` and every later `--` as `/` (`--opt-work--` → `/opt-work/`).
    public static func encode(_ path: String, home: String, temporaryDirectory: String) -> String {
        statsFolder(sessionDirectory(path, home: home, temporaryDirectory: temporaryDirectory))
    }

    static func sessionDirectory(_ path: String, home: String, temporaryDirectory: String) -> String {
        let path = canonical(path)
        if let relative = relative(path, to: canonical(temporaryDirectory)) {
            return relative.isEmpty ? "-tmp" : "-tmp-" + dashed(relative)
        }
        if let relative = relative(path, to: canonical(home)) {
            return "-" + dashed(relative)
        }
        return "--" + dashed(String(path.drop { $0 == "/" })) + "--"
    }

    /// omp-stats' `extractFolderFromPath`: `^--` → `/`, then every `--` → `/`.
    static func statsFolder(_ directory: String) -> String {
        var name = directory
        if name.hasPrefix("--") { name = "/" + name.dropFirst(2) }
        return name.replacingOccurrences(of: "--", with: "/")
    }

    /// A readable title for a folder no project claims: without its leading and trailing
    /// dashes and slashes (`-git-app` → `git-app`, `/private-tmp/` → `private-tmp`), `~` for
    /// home. The dashes of the path are ambiguous, so they stay.
    public static func fallbackTitle(_ folder: String) -> String {
        let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
        return trimmed.isEmpty ? "~" : trimmed
    }

    /// Node's `realpathSync` (symlinks resolved, `/tmp` → `/private/tmp`), else the
    /// standardized path for one that doesn't exist.
    private static func canonical(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var resolved = standardized
        if let real = realpath(standardized, nil) {
            resolved = String(cString: real)
            free(real)
        }
        while resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }

    /// `path` relative to `root` ("" for the root itself); nil outside it.
    private static func relative(_ path: String, to root: String) -> String? {
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func dashed(_ text: String) -> String {
        String(text.map { $0 == "/" || $0 == "\\" || $0 == ":" ? "-" : $0 })
    }
}
