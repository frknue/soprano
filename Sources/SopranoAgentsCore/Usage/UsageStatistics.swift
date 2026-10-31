import Foundation

/// The span the statistics board covers, with fixed chart buckets in local time: 24h → the last
/// 24 hours in hourly bars (25: the first is the part of its hour inside the window), 7d / 30d /
/// 90d → calendar days ending today, All → weeks since the first request (months once that is
/// more than 26 weeks).
public enum UsagePeriod: String, CaseIterable, Sendable {
    case day
    case week
    case month
    case quarter
    case all

    public var title: String {
        switch self {
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        case .quarter: "90d"
        case .all: "All"
        }
    }

    /// How the history is summed when read: hourly for 24h, daily otherwise.
    public var granularity: UsageGranularity { self == .day ? .hour : .day }

    /// Where the period's requests start; nil for All (from the first recorded request).
    public func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .day:
            now.addingTimeInterval(-86400)
        case .week, .month, .quarter:
            calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: now))
        case .all:
            nil
        }
    }

    /// The chart buckets: their unit and starts, ascending, from the period's start (All: from
    /// `earliest`) through `now`.
    public func buckets(now: Date, earliest: Date?, calendar: Calendar) -> (unit: UsageBucketUnit, starts: [Date]) {
        switch self {
        case .day:
            let start = start(now: now, calendar: calendar).map { Self.hourStart($0, calendar) }
            return (.hour, Self.steps(from: start, through: now, by: .hour, calendar: calendar))
        case .week, .month, .quarter:
            return (.day, Self.steps(from: start(now: now, calendar: calendar), through: now, by: .day, calendar: calendar))
        case .all:
            let first = min(earliest ?? now, now)
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: first)?.start
            let weeks = Self.steps(from: weekStart, through: now, by: .weekOfYear, calendar: calendar)
            guard weeks.count > Self.allWeeksLimit else { return (.week, weeks) }
            return (.month, Self.steps(from: calendar.dateInterval(of: .month, for: first)?.start, through: now, by: .month, calendar: calendar))
        }
    }

    /// Weekly buckets for All up to this many, monthly beyond.
    static let allWeeksLimit = 26

    private var dayCount: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: 0
        }
    }

    private static func hourStart(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }

    private static func steps(from start: Date?, through end: Date, by component: Calendar.Component, calendar: Calendar) -> [Date] {
        guard var current = start else { return [] }
        var dates: [Date] = []
        while current <= end {
            dates.append(current)
            guard let next = calendar.date(byAdding: component, value: 1, to: current), next > current else { break }
            current = next
        }
        return dates
    }
}

/// How recorded requests are summed when read.
public enum UsageGranularity: Sendable {
    case hour
    case day
}

/// The span of one chart bar.
public enum UsageBucketUnit: Sendable {
    case hour
    case day
    case week
    case month
}

/// Which number a chart or breakdown shows.
public enum UsageMetric: String, CaseIterable, Sendable {
    /// Estimated API-equivalent cost in USD.
    case cost
    case tokens
}

/// The token kinds a request is billed by.
public enum UsagePart: CaseIterable, Sendable {
    case input
    case output
    case cacheRead
    case cacheWrite

    public var title: String {
        switch self {
        case .input: "Input"
        case .output: "Output"
        case .cacheRead: "Cache read"
        case .cacheWrite: "Cache write"
        }
    }
}

/// Summed requests, tokens and estimated cost (USD at the provider's API rates, as omp records
/// them; not a subscription bill).
public struct UsageTotals: Sendable, Hashable {
    public var requests: Int
    public var failedRequests: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var inputCost: Double
    public var outputCost: Double
    public var cacheReadCost: Double
    public var cacheWriteCost: Double
    /// Requests whose price is unknown (their zero cost is not free usage).
    public var unpricedRequests: Int
    /// What the prompts of requests that reported an uncached price cost with the cache, and what
    /// they would have cost without it.
    public var cachedPromptCost: Double
    public var uncachedPromptCost: Double

    public init(
        requests: Int = 0,
        failedRequests: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        inputCost: Double = 0,
        outputCost: Double = 0,
        cacheReadCost: Double = 0,
        cacheWriteCost: Double = 0,
        unpricedRequests: Int = 0,
        cachedPromptCost: Double = 0,
        uncachedPromptCost: Double = 0
    ) {
        self.requests = requests
        self.failedRequests = failedRequests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.inputCost = inputCost
        self.outputCost = outputCost
        self.cacheReadCost = cacheReadCost
        self.cacheWriteCost = cacheWriteCost
        self.unpricedRequests = unpricedRequests
        self.cachedPromptCost = cachedPromptCost
        self.uncachedPromptCost = uncachedPromptCost
    }

    public var tokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

    public var cost: Double { inputCost + outputCost + cacheReadCost + cacheWriteCost }

    /// What the prompt cache saved: the uncached price minus what the cached prompts cost.
    public var cacheSavings: Double { max(0, uncachedPromptCost - cachedPromptCost) }

    /// Share of prompt tokens (input, cache read and cache write) served from the cache; nil
    /// without prompt tokens.
    public var cacheHitRate: Double? {
        let prompt = inputTokens + cacheReadTokens + cacheWriteTokens
        return prompt > 0 ? Double(cacheReadTokens) / Double(prompt) : nil
    }

    public func value(_ metric: UsageMetric) -> Double {
        switch metric {
        case .cost: cost
        case .tokens: Double(tokens)
        }
    }

    public func value(_ part: UsagePart, _ metric: UsageMetric) -> Double {
        switch (part, metric) {
        case (.input, .cost): inputCost
        case (.output, .cost): outputCost
        case (.cacheRead, .cost): cacheReadCost
        case (.cacheWrite, .cost): cacheWriteCost
        case (.input, .tokens): Double(inputTokens)
        case (.output, .tokens): Double(outputTokens)
        case (.cacheRead, .tokens): Double(cacheReadTokens)
        case (.cacheWrite, .tokens): Double(cacheWriteTokens)
        }
    }

    public mutating func add(_ other: UsageTotals) {
        requests += other.requests
        failedRequests += other.failedRequests
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
        inputCost += other.inputCost
        outputCost += other.outputCost
        cacheReadCost += other.cacheReadCost
        cacheWriteCost += other.cacheWriteCost
        unpricedRequests += other.unpricedRequests
        cachedPromptCost += other.cachedPromptCost
        uncachedPromptCost += other.uncachedPromptCost
    }
}

/// Requests of one model, agent kind and session folder within one local hour or day.
public struct UsageGroup: Sendable, Hashable {
    /// Start of the local hour or day.
    public var start: Date
    public var provider: String
    public var model: String
    /// omp's agent kind: `main`, `subagent`, `advisor`, …
    public var agent: String
    /// omp's session folder for the working directory (`-git-app` for `~/git/app`).
    public var folder: String
    public var totals: UsageTotals

    public init(start: Date, provider: String, model: String, agent: String, folder: String, totals: UsageTotals) {
        self.start = start
        self.provider = provider
        self.model = model
        self.agent = agent
        self.folder = folder
        self.totals = totals
    }
}

/// Reads the agent's recorded usage history.
public protocol UsageStatisticsService: Sendable {
    /// Ingests what the agent recorded since the last sync.
    func sync() async throws

    /// Recorded requests since `since` (every one when nil), summed per local hour or day,
    /// model, agent kind and folder.
    func groups(since: Date?, granularity: UsageGranularity) async throws -> [UsageGroup]
}
