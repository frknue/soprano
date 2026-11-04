import AppKit
import SopranoAgentsCore

/// Canned omp usage for the snapshot harness: about four months of working hours on the demo
/// projects (plus one folder no project claims) with Opus as the main model, Opus subagents, a
/// Sonnet advisor, GPT-6.1 Sol and an unpriced OpenRouter model. Deterministic for a given `now`;
/// never runs omp or reads its database.
struct FixtureUsageStatistics: UsageStatisticsService {
    let now: Date

    static let days = 120

    func sync() async throws {}

    func groups(since: Date?, granularity: UsageGranularity) async throws -> [UsageGroup] {
        let calendar = Calendar.current
        var merged: [String: UsageGroup] = [:]
        var order: [String] = []
        for record in Self.records(now: now, calendar: calendar) {
            if let since, record.start < since { continue }
            let start = granularity == .hour ? record.start : calendar.startOfDay(for: record.start)
            let key = "\(start.timeIntervalSince1970)|\(record.provider)|\(record.model)|\(record.agent)|\(record.folder)"
            if merged[key] == nil {
                order.append(key)
                merged[key] = UsageGroup(start: start, provider: record.provider, model: record.model, agent: record.agent, folder: record.folder, totals: UsageTotals())
            }
            merged[key]?.totals.add(record.totals)
        }
        return order.compactMap { merged[$0] }
    }

    private struct Model {
        let provider: String
        let model: String
        let agent: String
        /// Requests per busy hour at full intensity.
        let rate: Double
        /// USD per million input, output, cache-read and cache-write tokens; nil = unpriced.
        let prices: (input: Double, output: Double, cacheRead: Double, cacheWrite: Double)?
    }

    private static let models: [Model] = [
        Model(provider: "anthropic", model: "claude-opus-5-5", agent: "main", rate: 22, prices: (5, 25, 0.5, 6.25)),
        Model(provider: "anthropic", model: "claude-opus-5-5", agent: "subagent", rate: 16, prices: (5, 25, 0.5, 6.25)),
        Model(provider: "anthropic", model: "claude-sonnet-5-5", agent: "advisor", rate: 4, prices: (3, 15, 0.3, 3.75)),
        Model(provider: "openai-codex", model: "gpt-6.1-sol", agent: "main", rate: 7, prices: (1.25, 10, 0.125, 0)),
        Model(provider: "openrouter", model: "qwen/qwen3-coder", agent: "main", rate: 2, prices: nil),
    ]

    private static func folders() -> [String] {
        let home = NSHomeDirectory()
        let temporary = NSTemporaryDirectory()
        let projects = ["/Users/demo/code/app", "/Users/demo/code/soprano", "/Users/demo/code/site"]
        return projects.map { UsageFolderName.encode($0, home: home, temporaryDirectory: temporary) } + ["-Downloads-experiments"]
    }

    /// One record per busy hour and model, hours 9–22 local time over the last `days` days.
    private static func records(now: Date, calendar: Calendar) -> [UsageGroup] {
        let folders = folders()
        guard let currentHour = calendar.dateInterval(of: .hour, for: now)?.start else { return [] }
        var result: [UsageGroup] = []
        for hoursAgo in 0..<(days * 24) {
            guard let start = calendar.date(byAdding: .hour, value: -hoursAgo, to: currentHour) else { continue }
            let hour = calendar.component(.hour, from: start)
            guard (9...22).contains(hour) else { continue }
            var random = SeededRandom(seed: UInt64(start.timeIntervalSince1970 / 3600))
            guard random.next() > 0.3 else { continue }
            let weekend = calendar.isDateInWeekend(start)
            let recency = 0.35 + 0.65 * (1 - Double(hoursAgo) / Double(days * 24))
            let intensity = (0.25 + 0.75 * random.next()) * recency * (weekend ? 0.35 : 1)
            let folderPick = random.next()
            let folder = folderPick < 0.5 ? folders[0] : folderPick < 0.8 ? folders[1] : folderPick < 0.92 ? folders[2] : folders[3]
            for model in models {
                let requests = Int((model.rate * intensity * (0.5 + random.next())).rounded())
                guard requests > 0 else { continue }
                let input = requests * Int(300 + 1200 * random.next())
                let output = requests * Int(1500 + 2500 * random.next())
                let cacheRead = requests * Int(120_000 + 140_000 * random.next())
                let cacheWrite = requests * Int(4000 + 8000 * random.next())
                var totals = UsageTotals(
                    requests: requests,
                    failedRequests: random.next() < 0.06 ? 1 : 0,
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite
                )
                if let prices = model.prices {
                    totals.inputCost = Double(input) * prices.input / 1_000_000
                    totals.outputCost = Double(output) * prices.output / 1_000_000
                    totals.cacheReadCost = Double(cacheRead) * prices.cacheRead / 1_000_000
                    totals.cacheWriteCost = Double(cacheWrite) * prices.cacheWrite / 1_000_000
                    totals.cachedPromptCost = totals.inputCost + totals.cacheReadCost + totals.cacheWriteCost
                    totals.uncachedPromptCost = Double(input + cacheRead + cacheWrite) * prices.input / 1_000_000
                } else {
                    totals.unpricedRequests = requests
                }
                result.append(UsageGroup(start: start, provider: model.provider, model: model.model, agent: model.agent, folder: folder, totals: totals))
            }
        }
        return result
    }
}

/// SplitMix64 → [0, 1).
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
